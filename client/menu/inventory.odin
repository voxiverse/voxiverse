package menu

import "core:fmt"
import "core:strings"
import "core:time"

import "client:engine"
import "client:ui"
import "common:game"

// The inventory section (`e`): the character and their things over the game (it runs on),
// in two panes: the equipment beside the player (the paper doll: head, chest, legs and feet
// down the left; the hand, the offhand and two trinkets down the right) with the
// character's numbers under it, and the bag, a grid with Sort and a search under it; the
// hotbar below both. A chest the server opened takes the doll's pane (its slots, and Take
// all); the Creative tab (items.catalog) puts the catalog of every item over both.
//
// Click picks a stack up, puts it down, merges or swaps it; dragging a stack from one slot
// to another moves it; right-click takes half or puts one down; shift-click moves it
// between the hotbar and the rest (on, or off, the equipment; into, or out of, a chest);
// a number key over a slot swaps it with that hotbar slot; Q over a slot drops one
// (Ctrl+Q: all); a click outside drops what the cursor holds. The hand's slot is the
// hotbar's selected one. Players with items.catalog also have a Creative tab: every item,
// with a search, to take a stack of; and a middle click on a slot takes a full stack of
// its item. Hovering a stack shows its tooltip (item.odin), compared with what is worn.
//
// Mouse tweaks (after the mod of that name), each a sequence of the same
// requests the plain clicks make: shift-drag quick-moves every slot passed;
// a right-drag puts one into each slot passed; a left-drag with a stack on
// the cursor shares it evenly over the slots passed (a click on one slot
// is a plain click); a double-click gathers every stack of the cursor's
// item onto the cursor; the wheel over a slot moves one at a time between
// the hotbar and the rest (up: out of the slot, down: into it).

INVENTORY_COLUMNS :: 5 // the bag's, and a chest's
PREVIEW_COLUMNS :: 3 // the player's preview, as wide as this many slots
CHARACTER_ROWS :: 5 // the character's numbers under the doll
CHARACTER_ROW :: 22
CATALOG_COLUMNS :: 13 // (as wide as both panes)
SORT_WIDTH :: 80
DOUBLE_CLICK_SECONDS :: 0.3

// chest_sync: a chest the server opened shows its overlay (the inventory
// with the chest beside it); one that closed (walked away from, broken)
// takes it down.
chest_sync :: proc(app: ^engine.App) {
	s := app.session
	if s == nil || s.state != .Playing {return}
	open := section_open(app, .Inventory)
	if s.inventory.chest_open && !open {
		player_menu_show(app, .Inventory)
		app.inventory_view.tab = .Chest
	} else if !s.inventory.chest_open && open && app.inventory_view.tab == .Chest {
		player_menu_close(app)
	}
}

// inventory_enter: the section shown, fresh.
inventory_enter :: proc(app: ^engine.App) {
	app.inventory_view = {
		drag_from  = -1,
		click_slot = -1,
		cursor     = -1,
	}
	clear(&app.inventory_search)
}

// inventory_open shows the player menu at the inventory.
inventory_open :: proc(app: ^engine.App) {player_menu_show(app, .Inventory)}

// inventory_leave: the section is left (closed, or another shown): the
// cursor's stack goes back in (the server drops what does not fit) and an
// open chest closes.
inventory_leave :: proc(app: ^engine.App) {
	if s := app.session;
	   s != nil && (!game.stack_empty(s.inventory.cursor) || s.inventory.chest_open) {
		engine.session_inventory_do(s, {.Close, game.CURSOR_SLOT, 0})
	}
}

// Inventory_Layout: where everything is (UI units). The title row (the tabs), the two
// panes, the hotbar under the bag.
Inventory_Layout :: struct {
	panel:    ui.Rect,
	title:    ui.Rect, // the title, or the tabs
	left:     ui.Rect, // the equipment's pane (Inventory), the chest's (Chest)
	right:    ui.Rect, // the bag's pane (not on Creative)
	slots:    [game.ALL_SLOTS]ui.Rect, // the inventory's, the equipment's, then the chest's (empty: not shown on this tab)
	hand:     ui.Rect, // the hand's slot on the doll: the hotbar's selected one (Inventory)
	preview:  ui.Rect, // the player (Inventory only: a chest hides it)
	stats:    ui.Rect, // the character's numbers (Inventory)
	sort:     ui.Rect, // the Sort button (Inventory, Chest)
	search:   ui.Rect, // the search: above the catalog (Creative), under the bag (the others)
	take_all: ui.Rect, // a chest's Take all
	catalog:  ui.Rect, // Creative only
}

@(rodata)
DOLL_LEFT := [4]game.Equip_Slot{.Head, .Chest, .Legs, .Feet}
@(rodata)
DOLL_RIGHT := [3]game.Equip_Slot{.Offhand, .Trinket_1, .Trinket_2} // (under the hand)

inventory_layout :: proc(ctx: ^ui.Context, tab: engine.Inventory_Tab) -> (l: Inventory_Layout) {
	t := &ctx.theme
	gap := t.spacing
	step := INVENTORY_SLOT + gap
	content: ui.Rect
	l.panel, l.title, content = player_menu_panel(ctx)
	// The hotbar along the bottom, under the bag.
	hotbar_row := ui.cut_bottom(&content, INVENTORY_SLOT.y)
	ui.cut_bottom(&content, 2 * gap)
	half := (content.w - 2 * gap) / 2
	l.left = ui.cut_left(&content, half)
	ui.cut_left(&content, 2 * gap)
	l.right = content
	grid_w := INVENTORY_COLUMNS * step.x - gap
	inner :: proc(t: ^ui.Theme, r: ui.Rect) -> ui.Rect {
		c := ui.rect_shrink(r, t.padding / 2)
		ui.cut_top(&c, PANE_HEADING)
		return c
	}
	bag := inner(t, l.right)
	grid_x := bag.x + (bag.w - grid_w) / 2
	for i in 0 ..< game.HOTBAR_SLOTS { 	// (in the same place on every tab)
		l.slots[i] = {grid_x + f32(i) * step.x, hotbar_row.y, INVENTORY_SLOT.x, INVENTORY_SLOT.y}
	}
	if tab == .Creative {
		all := ui.Rect{l.left.x, l.left.y, l.right.x + l.right.w - l.left.x, l.left.h}
		l.left, l.right = {}, {}
		l.search = ui.cut_top(&all, t.row_height)
		ui.cut_top(&all, gap)
		rows := int((all.h + gap) / step.y)
		catalog_w := CATALOG_COLUMNS * step.x - gap
		l.catalog = {all.x + (all.w - catalog_w) / 2, all.y, catalog_w, f32(rows) * step.y - gap}
		return
	}
	// The bag: its grid, and Sort with the search under it.
	for i in game.HOTBAR_SLOTS ..< game.INVENTORY_SLOTS {
		row, col := (i - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS, i % INVENTORY_COLUMNS
		l.slots[i] = {
			grid_x + f32(col) * step.x,
			bag.y + f32(row) * step.y,
			INVENTORY_SLOT.x,
			INVENTORY_SLOT.y,
		}
	}
	rows := (game.INVENTORY_SLOTS - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS
	under := ui.Rect{grid_x, bag.y + f32(rows) * step.y, grid_w, t.row_height}
	l.sort = ui.cut_left(&under, SORT_WIDTH)
	ui.cut_left(&under, gap)
	l.search = under
	left := inner(t, l.left)
	switch tab {
	case .Inventory:
		// The doll: the armour down the left, the player, the hand and the rest down the right.
		doll_w := 2 * step.x + PREVIEW_COLUMNS * step.x
		x := left.x + (left.w - (doll_w - gap)) / 2
		for e, i in DOLL_LEFT {
			l.slots[game.EQUIP_BASE + int(e)] = {
				x,
				left.y + f32(i) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
		l.preview = {x + step.x, left.y, PREVIEW_COLUMNS * step.x - gap, 4 * step.y - gap}
		right_x := x + step.x + PREVIEW_COLUMNS * step.x
		l.hand = {right_x, left.y, INVENTORY_SLOT.x, INVENTORY_SLOT.y}
		for e, i in DOLL_RIGHT {
			l.slots[game.EQUIP_BASE + int(e)] = {
				right_x,
				left.y + f32(i + 1) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
		top := left.y + 4 * step.y
		l.stats = {left.x, top, left.w, left.y + left.h - top}
	case .Chest:
		for i in 0 ..< game.CHEST_SLOTS {
			row, col := i / INVENTORY_COLUMNS, i % INVENTORY_COLUMNS
			l.slots[game.CHEST_BASE + i] = {
				left.x + (left.w - grid_w) / 2 + f32(col) * step.x,
				left.y + f32(row) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
		chest_rows := (game.CHEST_SLOTS + INVENTORY_COLUMNS - 1) / INVENTORY_COLUMNS
		l.take_all = {
			left.x + (left.w - grid_w) / 2,
			left.y + f32(chest_rows) * step.y,
			grid_w,
			t.row_height,
		}
	case .Creative:
	}
	return
}

@(rodata)
EQUIP_TEXT := [game.Equip_Slot]engine.Text {
	.Head      = .Equip_Head,
	.Chest     = .Equip_Chest,
	.Legs      = .Equip_Legs,
	.Feet      = .Equip_Feet,
	.Offhand   = .Equip_Offhand,
	.Trinket_1 = .Equip_Trinket,
	.Trinket_2 = .Equip_Trinket,
}

// inventory_ui: the overlay (top: it takes the keys).
inventory_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	inv := &s.inventory
	reg := s.reg
	catalog := engine.session_ability(s, .Catalog)
	v := &app.inventory_view
	if inv.chest_open {v.tab = .Chest} else if v.tab == .Chest || !catalog {v.tab = .Inventory}
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	pad := app.actions.device == .Pad
	if pad && top && !ui.osk_is_open(ctx) {ctx.focused = 0} 	// (the cursor is the focus: A is not a click on a tab)
	l := inventory_layout(ctx, v.tab)
	ui.panel(ctx, l.panel)
	if v.tab == .Chest {
		ui.title(ctx, engine.tr(.Inventory_Chest), l.title, .Left)
	} else {
		strip := l.title
		if catalog {
			// Pockets or the catalog of every item (the section's own switch).
			b := ui.cut_right(&strip, SECTION_TAB_WIDTH)
			if ui.button(
				ctx,
				engine.tr(.Inventory_Pockets) if v.tab == .Creative else engine.tr(.Inventory_Catalog),
				b,
			) {
				v.tab = .Inventory if v.tab == .Creative else .Creative
				l = inventory_layout(ctx, v.tab)
			}
		}
		if top &&
		   catalog &&
		   engine.action_pressed(&app.actions, .Catalog) &&
		   !ui.osk_is_open(ctx) &&
		   v.tab != .Chest {
			v.tab = .Inventory if v.tab == .Creative else .Creative
			l = inventory_layout(ctx, v.tab)
			v.cursor = -1
		}
		if to, picked := section_tabs(app, ctx, strip); picked {
			player_menu_show(app, to)
			return
		}
	}
	switch v.tab {
	case .Inventory:
		pane(ctx, l.left, engine.tr(.Inventory_Equipment))
		pane(ctx, l.right, engine.tr(.Inventory_Bag))
	case .Chest:
		pane(ctx, l.left, engine.tr(.Inventory_Chest))
		pane(ctx, l.right, engine.tr(.Inventory_Bag))
	case .Creative:
	}
	mouse := ctx.input.mouse
	hovered := -1
	items: []game.Item
	if v.tab == .Creative {items = matching_items(reg, string(app.inventory_search[:]))}
	at: ui.Rect // the pad's cursor
	if pad {
		at = inventory_pad(app, ctx, l, items, top)
		if v.cursor < game.ALL_SLOTS {hovered = v.cursor}
	}
	slot_draw :: proc(app: ^engine.App, ctx: ^ui.Context, r: ui.Rect, i: int, lit, dim: bool) {
		s := app.session
		st := game.slot_at(&s.inventory, i)^
		stack_slot(ctx, s.reg, &app.item_icons, r, st, lit)
		if dim &&
		   len(app.inventory_search) > 0 &&
		   !stack_matches(s.reg, st, string(app.inventory_search[:])) {
			ui.fill_rect(ctx, r, ctx.theme.backdrop) // (the search dims what it does not find)
		}
	}
	for r, i in l.slots {
		if r.w == 0 {continue}
		if !pad && ui.rect_contains(r, mouse) {hovered = i}
		slot_draw(app, ctx, r, i, i == hovered, v.tab != .Creative)
		if i >= game.EQUIP_BASE && i < game.CHEST_BASE && game.stack_empty(game.slot_at(inv, i)^) {
			ui.draw_text(
				ctx,
				r,
				engine.tr(EQUIP_TEXT[game.Equip_Slot(i - game.EQUIP_BASE)]),
				ctx.theme.font_size * 0.6,
				ctx.theme.text_muted,
				.Center,
			)
		}
	}
	if v.tab == .Inventory {
		// The hand: the hotbar's selected slot, as the doll holds it.
		if !pad && ui.rect_contains(l.hand, mouse) {hovered = inv.selected}
		slot_draw(
			app,
			ctx,
			l.hand,
			inv.selected,
			hovered == inv.selected && ui.rect_contains(l.hand, mouse),
			false,
		)
		if game.stack_empty(inv.slots[inv.selected]) {
			ui.draw_text(
				ctx,
				l.hand,
				engine.tr(.Equip_Main_Hand),
				ctx.theme.font_size * 0.6,
				ctx.theme.text_muted,
				.Center,
			)
		}
		player_preview(app, ctx, l.preview, {at.x + at.w / 2, at.y + at.h / 2} if pad else mouse)
		character_stats(app, ctx, l.stats)
	}
	do_ :: proc(s: ^engine.Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		engine.session_inventory_do(s, {kind, slot, arg})
	}
	if v.tab != .Creative {
		if ui.button(ctx, engine.tr(.Inventory_Sort), l.sort) {do_(s, .Sort, 0)}
		ui.text_input(ctx, "inventory search", &app.inventory_search, l.search, "search")
	}
	if v.tab == .Chest {
		take := ui.button(
			ctx,
			engine.tr(.Inventory_Take_All),
			l.take_all,
			disabled = chest_empty(inv),
		)
		if take ||
		   (top && pad && engine.action_pressed(&app.actions, .Catalog)) {chest_take_all(s)}
	}
	if top {
		inventory_mouse(app, ctx, l.panel, hovered, catalog)
		if hovered >= 0 && !ctx.edit.active {
			for act, n in engine.HOTBAR_ACTIONS {
				if engine.key_action_pressed(&app.actions, act) {do_(s, .Swap_Hotbar, hovered, n)}
			}
			all := app.input.held & {.Left_Control, .Right_Control} != {}
			if hovered != v.drop_slot {v.drop_repeat, v.drop_slot = {}, hovered}
			went_down := engine.key_action_pressed(&app.actions, .Drop)
			if engine.drop_repeat(
				   &v.drop_repeat,
				   went_down,
				   engine.key_action_down(&app.actions, .Drop) && !all,
				   engine.seconds_now(),
			   ) ||
			   (went_down && all) {
				do_(s, .Drop, hovered, 1 if all else 0)
			}
		}
	}
	if v.tab == .Creative {catalog_ui(app, ctx, l, top, items, pad, at)}
	// What is hovered, and what the cursor holds (the pad's: up and right of its slot).
	if hovered >= 0 &&
	   !game.stack_empty(game.slot_at(inv, hovered)^) &&
	   game.stack_empty(inv.cursor) {
		slot_tooltip(ctx, reg, inv, hovered, at if pad else nil)
	}
	if !game.stack_empty(inv.cursor) {
		held := ui.Rect {
			mouse.x - INVENTORY_SLOT.x / 2,
			mouse.y - INVENTORY_SLOT.y / 2,
			INVENTORY_SLOT.x,
			INVENTORY_SLOT.y,
		}
		if pad {held = {at.x + at.w / 2, at.y - at.h / 2, at.w, at.h}}
		prev_layer := ui.begin_layer(ctx, .Tooltip)
		stack_slot(ctx, reg, &app.item_icons, held, inv.cursor, true)
		ui.end_layer(ctx, prev_layer)
	}
}

// chest_empty: the open chest holds nothing.
@(private = "file")
chest_empty :: proc(inv: ^game.Inventory) -> bool {
	for st in inv.chest {if !game.stack_empty(st) {return false}}
	return true
}

// chest_take_all: every stack of the open chest into the inventory, as far as it fits: a
// quick move of each (what does not fit stays in the chest).
chest_take_all :: proc(s: ^engine.Session) {
	for st, i in s.inventory.chest {
		if game.stack_empty(st) {continue}
		engine.session_inventory_do(s, {.Quick_Move, game.CHEST_BASE + i, 0})
	}
}

// character_stats: the character's numbers under the doll, as what they wear makes them
// (game.derive_mods, the same the movement reads): health, speed, jump, air jumps.
@(private = "file")
character_stats :: proc(app: ^engine.App, ctx: ^ui.Context, r: ui.Rect) {
	s := app.session
	t := &ctx.theme
	mods := game.derive_mods(s.reg, &s.inventory)
	Row :: struct {
		name:  engine.Text,
		value: string,
	}
	health := engine.tr(
		.Character_Health_Value,
		number_text(s.health),
		number_text(mods.max_health),
	)
	if !engine.session_ability(s, .Health) {health = engine.tr(.Character_None)}
	rows := [CHARACTER_ROWS]Row {
		{.Character_Health, health},
		{
			.Character_Speed,
			engine.tr(
				.Character_Speed_Value,
				fmt.tprintf("%.1f", s.rules.walk_speed * mods.speed),
			),
		},
		{
			.Character_Jump,
			engine.tr(.Character_Jump_Value, fmt.tprintf("%.2f", s.rules.jump_height * mods.jump)),
		},
		{.Character_Air_Jumps, fmt.tprint(mods.air_jumps)},
		{
			.Character_Grapple,
			engine.tr(.Character_Jump_Value, number_text(mods.grapple.range)) if mods.grapple.range > 0 else engine.tr(.Character_None),
		},
	}
	area := ui.rect_shrink(r, t.padding / 2)
	for row in rows {
		line := ui.cut_top(&area, CHARACTER_ROW)
		ui.draw_text(ctx, line, engine.tr(row.name), t.font_size, t.text_muted)
		ui.draw_text(ctx, line, row.value, t.font_size, t.text, .Right)
	}
}

// catalog_rows: how many rows the catalog has and shows (the scroll is kept
// within them).
@(private = "file")
catalog_rows :: proc(
	ctx: ^ui.Context,
	v: ^engine.Inventory_View,
	r: ui.Rect,
	count: int,
) -> (
	rows, visible: int,
) {
	gap := ctx.theme.spacing
	rows = (count + CATALOG_COLUMNS - 1) / CATALOG_COLUMNS
	visible = int((r.h + gap) / (INVENTORY_SLOT.y + gap))
	v.scroll = clamp(v.scroll, 0, f32(max(rows - visible, 0)))
	return
}

// catalog_cell: the rect of the i-th cell shown (row by row from the top).
@(private = "file")
catalog_cell :: proc(r: ui.Rect, gap: f32, i: int) -> ui.Rect {
	row, col := i / CATALOG_COLUMNS, i % CATALOG_COLUMNS
	return {
		r.x + f32(col) * (INVENTORY_SLOT.x + gap),
		r.y + f32(row) * (INVENTORY_SLOT.y + gap),
		INVENTORY_SLOT.x,
		INVENTORY_SLOT.y,
	}
}

// catalog_ui: every item that matches the search; a click puts a full stack
// of it on the cursor (with the pad, the cursor's cell is the lit one).
@(private = "file")
catalog_ui :: proc(
	app: ^engine.App,
	ctx: ^ui.Context,
	l: Inventory_Layout,
	top: bool,
	items: []game.Item,
	pad: bool,
	at: ui.Rect,
) {
	r := l.catalog
	s := app.session
	t := &ctx.theme
	v := &app.inventory_view
	was_open := ui.osk_is_open(ctx)
	ui.text_input(ctx, "inventory search", &app.inventory_search, l.search, "search items")
	if pad && top && !was_open && v.cursor >= engine.CURSOR_CATALOG_BASE && .Tertiary in ctx.nav {
		// (opened after the field is drawn: Y is not the keyboard's first key)
		ui.osk_open(ctx, ui.get_id(ctx, "inventory search"))
	}
	gap := t.spacing
	_, visible := catalog_rows(ctx, v, r, len(items))
	if ui.rect_contains(r, ctx.input.mouse) {v.scroll -= ctx.input.wheel.y}
	catalog_rows(ctx, v, r, len(items))
	first := int(v.scroll) * CATALOG_COLUMNS
	hovered := game.NO_ITEM
	ui.push_clip_rect(ctx, r)
	defer {
		ui.pop_clip_rect(ctx)
		if hovered != game.NO_ITEM && game.stack_empty(s.inventory.cursor) {
			item_tooltip(ctx, app.session.reg, {hovered, 1, 0, 0}, beside = at if pad else nil)
		}
	}
	for k in first ..< len(items) {
		i := k - first
		if i / CATALOG_COLUMNS >= visible {break}
		slot := catalog_cell(r, gap, i)
		over :=
			v.cursor == engine.CURSOR_CATALOG_BASE + k if pad else ui.rect_contains(slot, ctx.input.mouse)
		stack_slot(ctx, app.session.reg, &app.item_icons, slot, {items[k], 1, 0, 0}, over)
		if over {hovered = items[k]}
		if !pad && top && over && .Left in ctx.input.mouse_pressed {
			engine.session_inventory_do(s, {.Take, game.CURSOR_SLOT, int(items[k])})
		}
	}
}

// inventory_pad: the pad's cursor over the slots and the catalog's cells:
// kept somewhere that exists (it starts on the hand's hotbar slot), moved by
// directions (past the catalog's top or bottom row it scrolls a row), and A, X
// and Y as a left click, a right click and a quick move on a slot; on a cell A
// takes a stack and Y opens the keyboard on the search. Returns the cursor's rect.
@(private = "file")
inventory_pad :: proc(
	app: ^engine.App,
	ctx: ^ui.Context,
	l: Inventory_Layout,
	items: []game.Item,
	top: bool,
) -> ui.Rect {
	s := app.session
	v := &app.inventory_view
	gap := ctx.theme.spacing
	creative := v.tab == .Creative
	rows, visible: int
	if creative {rows, visible = catalog_rows(ctx, v, l.catalog, len(items))}

	// Keep it on something that is shown.
	valid := false
	if v.cursor >= engine.CURSOR_CATALOG_BASE {
		if creative && len(items) > 0 {
			cell := min(v.cursor - engine.CURSOR_CATALOG_BASE, len(items) - 1)
			v.cursor = engine.CURSOR_CATALOG_BASE + cell
			row := cell / CATALOG_COLUMNS
			if row < int(v.scroll) {
				v.scroll = f32(row)
			} else if row >= int(v.scroll) + visible {
				v.scroll = f32(row - visible + 1)
			}
			valid = true
		}
	} else if v.cursor >= 0 && v.cursor < game.ALL_SLOTS {
		valid = l.slots[v.cursor].w != 0
	}
	if !valid {v.cursor = clamp(s.inventory.selected, 0, game.HOTBAR_SLOTS - 1)}

	cursor_rect :: proc(l: Inventory_Layout, gap: f32, v: ^engine.Inventory_View) -> ui.Rect {
		if v.cursor >= engine.CURSOR_CATALOG_BASE {
			cell := v.cursor - engine.CURSOR_CATALOG_BASE - int(v.scroll) * CATALOG_COLUMNS
			return catalog_cell(l.catalog, gap, cell)
		}
		return l.slots[v.cursor]
	}

	if top && !ui.osk_is_open(ctx) && !ctx.edit.active {
		ui.consume_nav(ctx, ui.DIRECTIONS)
		do_ :: proc(s: ^engine.Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
			engine.session_inventory_do(s, {kind, slot, arg})
		}
		for dir in ui.Nav.Up ..= ui.Nav.Right {
			if dir not_in ctx.nav {continue}
			if v.cursor >= engine.CURSOR_CATALOG_BASE && (dir == .Up || dir == .Down) {
				cell := v.cursor - engine.CURSOR_CATALOG_BASE
				row, first_row := cell / CATALOG_COLUMNS, int(v.scroll)
				if dir == .Down && row == first_row + visible - 1 && first_row + visible < rows {
					v.scroll += 1
					v.cursor =
						engine.CURSOR_CATALOG_BASE + min(cell + CATALOG_COLUMNS, len(items) - 1)
					continue
				}
				if dir == .Up && row == first_row && first_row > 0 {
					v.scroll -= 1
					v.cursor -= CATALOG_COLUMNS
					continue
				}
			}
			rects := make([dynamic]ui.Rect, context.temp_allocator)
			ids := make([dynamic]int, context.temp_allocator)
			for r, i in l.slots {
				if r.w != 0 {append(&rects, r); append(&ids, i)}
			}
			if creative {
				first := int(v.scroll) * CATALOG_COLUMNS
				shown := min(visible * CATALOG_COLUMNS, len(items) - first)
				for i in 0 ..< shown {
					append(&rects, catalog_cell(l.catalog, gap, i))
					append(&ids, engine.CURSOR_CATALOG_BASE + first + i)
				}
			}
			if to := ui.nav_pick(cursor_rect(l, gap, v), rects[:], dir); to >= 0 {
				v.cursor = ids[to]
			}
		}
		switch {
		case v.cursor >= engine.CURSOR_CATALOG_BASE:
			if .Confirm in ctx.nav {
				do_(s, .Take, game.CURSOR_SLOT, int(items[v.cursor - engine.CURSOR_CATALOG_BASE]))
			}
		case .Confirm in ctx.nav:
			do_(s, .Click, v.cursor)
		case .Secondary in ctx.nav:
			do_(s, .Click_Right, v.cursor)
		case .Tertiary in ctx.nav:
			do_(s, .Quick_Move, v.cursor)
		}
	}
	return cursor_rect(l, gap, v)
}

// slot_takes: a slot a spread or a one-each drag may put into: empty, or
// holding the cursor's item.
@(private = "file")
slot_takes :: proc(reg: ^game.Registry, inv: ^game.Inventory, slot: int) -> bool {
	st := game.slot_at(inv, slot)^
	return(
		game.slot_accepts(reg, slot, inv.cursor) &&
		(game.stack_empty(st) || st.item == inv.cursor.item) \
	)
}

// inventory_mouse: the mouse over the slots (hovered: -1 for none): clicks
// and drags, the wheel, a middle click.
@(private = "file")
inventory_mouse :: proc(
	app: ^engine.App,
	ctx: ^ui.Context,
	panel: ui.Rect,
	hovered: int,
	catalog: bool,
) {
	s := app.session
	v := &app.inventory_view
	inv := &s.inventory
	mouse := ctx.input.mouse
	pressed, released, down :=
		ctx.input.mouse_pressed, ctx.input.mouse_released, ctx.input.mouse_down
	shift := .Shift in ctx.input.modifiers
	do_ :: proc(s: ^engine.Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		engine.session_inventory_do(s, {kind, slot, arg})
	}
	begin :: proc(v: ^engine.Inventory_View, mode: engine.Drag_Mode, slot: int) {
		v.mode, v.first, v.visited = mode, slot, {}
		v.visited[slot] = true
	}
	entered := hovered >= 0 && v.mode != .None && !v.visited[hovered]
	if entered {v.visited[hovered] = true}

	// Presses.
	switch {
	case hovered >= 0 && .Left in pressed && shift:
		do_(s, .Quick_Move, hovered)
		begin(v, .Quick, hovered)
	case hovered >= 0 && .Left in pressed:
		again :=
			hovered == v.click_slot &&
			time.duration_seconds(time.tick_since(v.click_time)) < DOUBLE_CLICK_SECONDS
		v.click_slot, v.click_time = hovered, time.tick_now()
		switch {
		case again && !game.stack_empty(inv.cursor):
			do_(s, .Gather, game.CURSOR_SLOT)
			v.click_slot = -1
		case game.stack_empty(inv.cursor):
			do_(s, .Click, hovered)
			v.drag_from = hovered // a drag may begin here
		case:
			begin(v, .Spread, hovered) // a click on release, or a share
		}
	case hovered >= 0 && .Right in pressed:
		if !game.stack_empty(inv.cursor) {begin(v, .One_Each, hovered)}
		do_(s, .Click_Right, hovered)
	case hovered >= 0 && .Middle in pressed:
		if catalog &&
		   game.stack_empty(inv.cursor) &&
		   !game.stack_empty(game.slot_at(inv, hovered)^) {
			do_(s, .Take, game.CURSOR_SLOT, int(game.slot_at(inv, hovered).item))
		}
	case hovered < 0 && (.Left in pressed || .Right in pressed) && !ui.rect_contains(panel, mouse):
		do_(s, .Drop, game.CURSOR_SLOT, 1 if .Left in pressed else 0)
	}

	// Drags passing over slots.
	switch v.mode {
	case .None, .Spread:
	case .Quick:
		if entered && .Left in down {do_(s, .Quick_Move, hovered)}
	case .One_Each:
		if entered &&
		   .Right in down &&
		   slot_takes(s.reg, inv, hovered) {do_(s, .Click_Right, hovered)}
	}

	// Releases.
	if .Left in released {
		switch {
		case v.mode == .Spread:
			spread_stack(s, v)
		case v.drag_from >= 0:
			// Dropped on another slot: it goes there.
			if hovered >= 0 && hovered != v.drag_from {do_(s, .Click, hovered)}
		}
		v.drag_from = -1
	}
	if (v.mode == .Spread || v.mode == .Quick) && .Left not_in down {v.mode = .None}
	if v.mode == .One_Each && .Right not_in down {v.mode = .None}

	// The wheel over a slot: one item out of it (up) or into it (down).
	if hovered >= 0 && ctx.input.wheel.y != 0 && v.mode == .None {
		n := max(1, int(abs(ctx.input.wheel.y)))
		for _ in 0 ..< n {do_(s, .Move_One, hovered, 0 if ctx.input.wheel.y > 0 else 1)}
	}
}

// spread_stack: the drag that began with a stack on the cursor ends: over
// one slot it is a click there; over several, the stack is shared evenly
// among those that take it (the rest stays on the cursor).
@(private = "file")
spread_stack :: proc(s: ^engine.Session, v: ^engine.Inventory_View) {
	inv := &s.inventory
	slots := make([dynamic]int, context.temp_allocator)
	visited := 0
	for i in 0 ..< game.ALL_SLOTS {
		if !v.visited[i] {continue}
		visited += 1
		if slot_takes(s.reg, inv, i) {append(&slots, i)}
	}
	if visited <= 1 {
		engine.session_inventory_do(s, {.Click, v.first, 0})
		return
	}
	if len(slots) == 0 {return}
	left := inv.cursor.count
	share := max(1, left / len(slots))
	for i in slots {
		put := min(share, left)
		if put <= 0 {break}
		engine.session_inventory_do(s, {.Put, i, put})
		left = inv.cursor.count
	}
}

// matching_items: the items whose names contain query (any case; every item
// when it is empty).
// stack_matches: the stack's item has query in its name (an empty slot never matches).
stack_matches :: proc(reg: ^game.Registry, stack: game.Stack, query: string) -> bool {
	if game.stack_empty(stack) {return false}
	name := strings.to_lower(item_title(reg, stack.item), context.temp_allocator)
	return strings.contains(name, strings.to_lower(query, context.temp_allocator))
}

matching_items :: proc(reg: ^game.Registry, query: string) -> []game.Item {
	all := game.every_item(reg)
	if len(query) == 0 {return all}
	q := strings.to_lower(query, context.temp_allocator)
	found := make([dynamic]game.Item, context.temp_allocator)
	for item in all {
		name := strings.to_lower(item_title(reg, item), context.temp_allocator)
		if strings.contains(name, q) {append(&found, item)}
	}
	return found[:]
}

// player_preview shows the player (drawn to a texture by the renderer,
// app.preview) turned toward look: the mouse, or the pad's cursor.
@(private = "file")
player_preview :: proc(app: ^engine.App, ctx: ^ui.Context, r: ui.Rect, look: ui.Vec2) {
	t := &ctx.theme
	ui.fill_rect(ctx, r, t.preview_fill)
	ui.stroke_rect(ctx, r, 1, t.faint_border)
	// Where it is from the middle of the player's chest: turn and look that
	// way, within limits.
	dx := (look.x - (r.x + r.w / 2)) / (r.w * 2)
	dy := ((r.y + r.h * 0.3) - look.y) / (r.h * 2)
	app.preview.active = true
	v := &app.inventory_view
	mouse := ctx.input.mouse
	if .Left in ctx.input.mouse_pressed && ui.rect_contains(r, mouse) {
		v.spinning, v.spin_x = true, mouse.x
	}
	if .Left not_in ctx.input.mouse_down {v.spinning = false}
	if v.spinning {
		v.spin += (mouse.x - v.spin_x) / r.w * 4 // (dragging across it turns it round once or so)
		v.spin_x = mouse.x
	}
	app.preview.target_yaw = clamp(dx * 1.6, -0.9, 0.9) + v.spin
	app.preview.target_pitch = clamp(dy * 1.4, -0.6, 0.6)
	ui.draw_image(ctx, r, engine.PREVIEW_IMAGE)
}
