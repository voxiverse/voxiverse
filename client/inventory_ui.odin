package client

import "core:fmt"
import "core:strings"
import "core:time"

import "../common/game"
import "ui"

// Slots as the UI draws them: the hotbar's and the inventory overlay's.

SLOT_SIZE :: ui.Vec2{48, 48} // the hotbar's
INVENTORY_SLOT :: ui.Vec2{44, 44} // the overlay's

// item_title: an item's name as players read it ("rocket launcher").
item_title :: proc(item: game.Item) -> string {
	name, _ := strings.replace_all(game.item_name(item), "_", " ", context.temp_allocator)
	return name
}

// stack_slot draws a slot holding stack: its icon (its name, if it has
// none), its count (more than one), its number key (key > 0), framed when
// selected.
stack_slot :: proc(
	ctx: ^ui.Context,
	icons: ^Item_Icons,
	r: ui.Rect,
	stack: game.Stack,
	selected: bool,
	key := 0,
) {
	t := &ctx.theme
	ui.fill_rect(ctx, r, t.slot_fill) // (blending is linear: lighter than it reads)
	ui.stroke_rect(ctx, r, 2 if selected else 1, t.text if selected else t.faint_border)
	inner := ui.rect_shrink(r, 4)
	small := t.font_size * 0.75
	if game.stack_empty(stack) {
		if key > 0 {
			ui.draw_text(
				ctx,
				{inner.x, inner.y, inner.w, small},
				fmt.tprint(key),
				small,
				t.text_muted,
			)
		}
		return
	}
	if icon, ok := icons[stack.item]; ok {
		side := min(inner.w, inner.h)
		ui.draw_icon(ctx, ui.rect_center(inner, side, side), icon)
	} else {
		ui.push_clip_rect(ctx, inner)
		title := item_title(stack.item)
		align := ui.Align.Center if ui.measure_text(ctx, title, small) <= inner.w else .Left
		ui.draw_text(ctx, inner, title, small, t.text, align)
		ui.pop_clip_rect(ctx)
	}
	if key > 0 {
		ui.draw_text(
			ctx,
			{inner.x + 1, inner.y + 1, inner.w, small},
			fmt.tprint(key),
			small,
			t.text_shadow,
		)
		ui.draw_text(ctx, {inner.x, inner.y, inner.w, small}, fmt.tprint(key), small, t.text_muted)
	}
	if stack.count > 1 {
		corner := ui.Rect{inner.x, inner.y + inner.h - small, inner.w, small}
		count := fmt.tprint(stack.count)
		ui.draw_text(
			ctx,
			{corner.x + 1, corner.y + 1, corner.w, corner.h},
			count,
			small,
			t.text_shadow,
			.Right,
		)
		ui.draw_text(ctx, corner, count, small, t.text, .Right)
	}
}

// item_tooltip: name in a box by the mouse.
item_tooltip :: proc(ctx: ^ui.Context, name: string) {
	t := &ctx.theme
	mouse := ctx.input.mouse
	w := ui.measure_text(ctx, name, t.font_size) + 2 * t.padding
	tip := ui.Rect{mouse.x + 12, mouse.y + 12, w, t.row_height}
	ui.fill_rect(ctx, tip, t.slot_fill)
	ui.draw_text(ctx, ui.rect_shrink(tip, t.padding), name, t.font_size, t.text)
}

// The inventory overlay (`e`): the inventory over the game (it runs on).
// Click picks a stack up, puts it down, merges or swaps it; dragging a
// stack from one slot to another moves it; right-click takes half or puts
// one down; shift-click moves it between the hotbar and the rest; a number
// key over a slot swaps it with that hotbar slot; Q over a slot drops one
// (Ctrl+Q: all); a click outside drops what the cursor holds. Players with
// items.catalog also have a Creative tab: every item, with a search, to take
// a stack of; and a middle click on a slot takes a full stack of its item.
//
// Mouse tweaks (after the mod of that name), each a sequence of the same
// requests the plain clicks make: shift-drag quick-moves every slot passed;
// a right-drag puts one into each slot passed; a left-drag with a stack on
// the cursor shares it evenly over the slots passed (a click on one slot
// is a plain click); a double-click gathers every stack of the cursor's
// item onto the cursor; the wheel over a slot moves one at a time between
// the hotbar and the rest (up: out of the slot, down: into it).

INVENTORY_COLUMNS :: 5
CATALOG_COLUMNS :: 9 // (as wide as the Inventory tab: equipment, preview, grid)
PREVIEW_COLUMNS :: 3 // the player's preview, as wide as this many slots
DOUBLE_CLICK_SECONDS :: 0.3

Drag_Mode :: enum u8 {
	None,
	Quick, // shift + left: quick-move each slot entered
	Spread, // left with a stack on the cursor: share it over the slots entered
	One_Each, // right with a stack on the cursor: one into each slot entered
}

// Inventory_Tab: the overlay's two halves. Creative (the catalog of every
// item, with a search; only with items.catalog) shows the hotbar under it,
// so a stack goes from the catalog straight into a hotbar slot.
Inventory_Tab :: enum u8 {
	Inventory,
	Creative,
	Chest, // looking into a chest (not chosen: the server opened it)
}

Inventory_View :: struct {
	tab:         Inventory_Tab,
	drop_repeat: Drop_Repeat, // the drop key held over a slot
	drop_slot:   int, // the slot it was held over
	drag_from:   int, // the slot a drag began on (-1: none)
	scroll:      f32, // catalog rows scrolled
	mode:        Drag_Mode,
	visited:     [game.ALL_SLOTS]bool, // the slots the drag has passed
	first:       int, // where the drag began
	click_slot:  int, // the last left press (-1: none), for double-clicks
	click_time:  time.Tick,
	fresh:       bool, // opened this frame: its own key press is not a tab step
}

// inventory_keys: the inventory key over the game opens the inventory (it
// closes with Escape; Q and E step its tabs).
inventory_keys :: proc(app: ^App) {
	s := app.session
	if s == nil ||
	   s.state != .Playing ||
	   !action_pressed(&app.actions, .Inventory) ||
	   overlay_is_open(&app.overlays, .Inventory) {return}
	if game_controls(app) {inventory_open(app)}
}

// chest_sync: a chest the server opened shows its overlay (the inventory
// with the chest beside it); one that closed (walked away from, broken)
// takes it down.
chest_sync :: proc(app: ^App) {
	s := app.session
	if s == nil || s.state != .Playing {return}
	open := overlay_is_open(&app.overlays, .Inventory)
	if s.inventory.chest_open && !open {
		inventory_open(app)
		app.inventory_view.tab = .Chest
	} else if !s.inventory.chest_open && open && app.inventory_view.tab == .Chest {
		inventory_close(app)
	}
}

// inventory_open shows the overlay, fresh.
inventory_open :: proc(app: ^App) {
	overlay_open(&app.overlays, .Inventory)
	app.inventory_view = {
		drag_from  = -1,
		click_slot = -1,
		fresh      = true,
	}
	clear(&app.inventory_search)
}

// inventory_close: the cursor's stack back in (the server drops what does
// not fit).
inventory_close :: proc(app: ^App) {
	overlay_close(&app.overlays, .Inventory)
	if s := app.session;
	   s != nil && (!game.stack_empty(s.inventory.cursor) || s.inventory.chest_open) {
		session_inventory_do(s, {.Close, game.CURSOR_SLOT, 0})
	}
}

// inventory_layout: where everything is (UI units). A title row (with the
// tabs), then the tab's content: the rest of the inventory as a grid, or a
// search above the catalog; the hotbar below both.
@(private)
Inventory_Layout :: struct {
	panel:   ui.Rect,
	title:   ui.Rect, // the title, or the tabs
	slots:   [game.ALL_SLOTS]ui.Rect, // the inventory's, the equipment's, then the chest's (empty: not shown on this tab)
	preview: ui.Rect, // the player (Inventory only)
	search:  ui.Rect, // Creative only
	catalog: ui.Rect, // Creative only
}

@(private)
inventory_layout :: proc(ctx: ^ui.Context, tab: Inventory_Tab) -> (l: Inventory_Layout) {
	t := &ctx.theme
	gap := t.spacing
	step := INVENTORY_SLOT + gap
	rest_rows := (game.INVENTORY_SLOTS - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS
	content_h := f32(rest_rows) * step.y + t.row_height + gap // (the same on both tabs)
	columns := 2 * INVENTORY_COLUMNS + 1 if tab == .Chest else CATALOG_COLUMNS // (the chest and the inventory side by side)
	w := f32(columns) * step.x - gap + 2 * t.padding
	h := t.row_height + 2 * gap + content_h + 2 * gap + step.y - gap + 2 * t.padding
	l.panel = ui.rect_center(ctx.screen, w, h)
	inner := ui.rect_shrink(l.panel, t.padding)
	l.title = ui.cut_top(&inner, t.row_height)
	ui.cut_top(&inner, 2 * gap)
	content := ui.cut_top(&inner, content_h + 2 * gap)
	hotbar_x := inner.x + (inner.w - (game.HOTBAR_SLOTS * step.x - gap)) / 2
	for i in 0 ..< game.HOTBAR_SLOTS {
		l.slots[i] = {hotbar_x + f32(i) * step.x, inner.y, INVENTORY_SLOT.x, INVENTORY_SLOT.y}
	}
	switch tab {
	case .Inventory:
		// Equipment down the left, the player beside it, the grid right.
		for e in 0 ..< game.EQUIP_SLOTS {
			l.slots[game.EQUIP_BASE + e] = {
				content.x,
				content.y + f32(e) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
		l.preview = {
			content.x + step.x,
			content.y,
			PREVIEW_COLUMNS * step.x - gap,
			f32(rest_rows) * step.y - gap,
		}
		grid_x := content.x + content.w - (INVENTORY_COLUMNS * step.x - gap)
		for i in game.HOTBAR_SLOTS ..< game.INVENTORY_SLOTS {
			row, col := (i - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS, i % INVENTORY_COLUMNS
			l.slots[i] = {
				grid_x + f32(col) * step.x,
				content.y + f32(row) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
	case .Chest:
		for i in 0 ..< game.CHEST_SLOTS {
			row, col := i / INVENTORY_COLUMNS, i % INVENTORY_COLUMNS
			l.slots[game.CHEST_BASE + i] = {
				content.x + f32(col) * step.x,
				content.y + f32(row) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
		grid_x := content.x + content.w - (INVENTORY_COLUMNS * step.x - gap)
		for i in game.HOTBAR_SLOTS ..< game.INVENTORY_SLOTS {
			row, col := (i - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS, i % INVENTORY_COLUMNS
			l.slots[i] = {
				grid_x + f32(col) * step.x,
				content.y + f32(row) * step.y,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			}
		}
	case .Creative:
		l.search = ui.cut_top(&content, t.row_height)
		ui.cut_top(&content, gap)
		l.catalog = {content.x, content.y, content.w, f32(rest_rows) * step.y - gap}
	}
	return
}

// inventory_ui: the overlay (top: it takes the keys).
inventory_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	inv := &s.inventory
	catalog := session_allowed(s, "items.catalog")
	v := &app.inventory_view
	if inv.chest_open {v.tab = .Chest} else if v.tab == .Chest || !catalog {v.tab = .Inventory}
	fresh := v.fresh
	v.fresh = false
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	l := inventory_layout(ctx, v.tab)
	ui.panel(ctx, l.panel)
	if v.tab == .Chest {
		ui.title(ctx, "Chest", l.title, .Left)
	} else {
		active := Ring_Tab.Inventory if v.tab == .Inventory else .Creative
		if to, picked := ring_tabs(app, ctx, l.title, active); picked {
			ring_go(app, to)
			if to == .Statistics {return}
			l = inventory_layout(ctx, v.tab)
		}
	}
	mouse := ctx.input.mouse
	hovered := -1
	for r, i in l.slots {
		if r.w == 0 {continue}
		if ui.rect_contains(r, mouse) {hovered = i}
		stack_slot(ctx, &app.item_icons, r, game.slot_at(inv, i)^, i == hovered)
		if i >= game.EQUIP_BASE && i < game.CHEST_BASE && game.stack_empty(game.slot_at(inv, i)^) {
			small := ctx.theme.font_size * 0.6
			ui.draw_text(
				ctx,
				r,
				EQUIP_LABELS[game.Equip_Slot(i - game.EQUIP_BASE)],
				small,
				ctx.theme.text_muted,
				.Center,
			)
		}
	}
	if v.tab == .Inventory {player_preview(app, ctx, l.preview)}
	do_ :: proc(s: ^Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		session_inventory_do(s, {kind, slot, arg})
	}
	if top {
		// Q and E step the tabs; over a slot, the drop key still drops.
		if step := menu_tab_step(app, hovered >= 0); v.tab != .Chest && !fresh && step != 0 {
			if ring_go(app, ring_step(app, active_ring(v.tab), step)) == .Statistics {return}
		}
		inventory_mouse(app, ctx, l.panel, hovered, catalog)
		if hovered >= 0 && !ctx.edit.active {
			for act, n in HOTBAR_ACTIONS {
				if key_action_pressed(&app.actions, act) {do_(s, .Swap_Hotbar, hovered, n)}
			}
			all := app.input.held & {.Left_Control, .Right_Control} != {}
			if hovered != v.drop_slot {v.drop_repeat, v.drop_slot = {}, hovered}
			went_down := key_action_pressed(&app.actions, .Drop)
			if drop_repeat(
				   &v.drop_repeat,
				   went_down,
				   key_action_down(&app.actions, .Drop) && !all,
				   seconds_now(),
			   ) ||
			   (went_down && all) {
				do_(s, .Drop, hovered, 1 if all else 0)
			}
		}
	}
	if v.tab == .Creative {catalog_ui(app, ctx, l, top)}
	// What is hovered, and what the cursor holds.
	if hovered >= 0 &&
	   !game.stack_empty(game.slot_at(inv, hovered)^) &&
	   game.stack_empty(inv.cursor) {
		item_tooltip(ctx, item_title(game.slot_at(inv, hovered).item))
	}
	if !game.stack_empty(inv.cursor) {
		stack_slot(
			ctx,
			&app.item_icons,
			{
				mouse.x - INVENTORY_SLOT.x / 2,
				mouse.y - INVENTORY_SLOT.y / 2,
				INVENTORY_SLOT.x,
				INVENTORY_SLOT.y,
			},
			inv.cursor,
			true,
		)
	}
}

// Ring_Tab: the tabs Q and E step through, shared by the inventory and the
// statistics overlays (the chest is not in the ring).
Ring_Tab :: enum u8 {
	Inventory,
	Creative, // only with items.catalog
	Statistics,
}

@(private = "file")
active_ring :: proc(tab: Inventory_Tab) -> Ring_Tab {
	return .Creative if tab == .Creative else .Inventory
}

@(private = "file")
ring_has :: proc(app: ^App, tab: Ring_Tab) -> bool {
	return(
		tab != .Creative ||
		(app.session != nil && session_allowed(app.session, "items.catalog")) \
	)
}

// ring_step: the tab step places away from from (around, past missing ones).
ring_step :: proc(app: ^App, from: Ring_Tab, step: int) -> Ring_Tab {
	n := len(Ring_Tab)
	to := from
	for _ in 0 ..< n {
		to = Ring_Tab((int(to) + step + n) % n)
		if ring_has(app, to) {break}
	}
	return to
}

// ring_go shows a tab: the inventory's own are a switch within it; the
// statistics are their own overlay, the other closed.
ring_go :: proc(app: ^App, to: Ring_Tab) -> Ring_Tab {
	inventory_open_now := overlay_is_open(&app.overlays, .Inventory)
	switch to {
	case .Inventory, .Creative:
		if !inventory_open_now {
			overlay_close(&app.overlays, .Stats)
			inventory_open(app)
		}
		app.inventory_view.tab = .Inventory if to == .Inventory else .Creative
	case .Statistics:
		if inventory_open_now {inventory_close(app)}
		if !overlay_is_open(&app.overlays, .Stats) {stats_open(app)}
	}
	return to
}

// ring_tabs: the tab row in a title row, the open one lit, and the keys that
// step it at the right end; the one chosen with the mouse, if any.
ring_tabs :: proc(
	app: ^App,
	ctx: ^ui.Context,
	r: ui.Rect,
	active: Ring_Tab,
) -> (
	chosen: Ring_Tab,
	picked: bool,
) {
	t := &ctx.theme
	row := r
	hint := fmt.tprintf("%s / %s", action_label(app, .Tab_Prev), action_label(app, .Tab_Next))
	ui.draw_text(ctx, row, hint, t.font_size, t.text_muted, .Right)
	for tab in Ring_Tab {
		if !ring_has(app, tab) {continue}
		b := ui.cut_left(&row, 140)
		ui.cut_left(&row, t.spacing)
		name := fmt.tprint(tab)
		if tab == active {
			ui.fill_rect(ctx, b, t.hover)
			ui.stroke_rect(ctx, b, t.border_width, t.border)
			ui.draw_text(ctx, b, name, t.font_size, t.hover_text, .Center)
		} else if ui.button(ctx, name, b) {
			chosen, picked = tab, true
		}
	}
	return
}

// catalog_ui: every item that matches the search; a click puts a full stack
// of it on the cursor.
@(private = "file")
catalog_ui :: proc(app: ^App, ctx: ^ui.Context, l: Inventory_Layout, top: bool) {
	r := l.catalog
	s := app.session
	t := &ctx.theme
	v := &app.inventory_view
	ui.text_input(ctx, "inventory search", &app.inventory_search, l.search, "search items")
	items := matching_items(string(app.inventory_search[:]))
	gap := t.spacing
	rows := (len(items) + CATALOG_COLUMNS - 1) / CATALOG_COLUMNS
	visible := int((r.h + gap) / (INVENTORY_SLOT.y + gap))
	if ui.rect_contains(r, ctx.input.mouse) {v.scroll -= ctx.input.wheel.y}
	v.scroll = clamp(v.scroll, 0, f32(max(rows - visible, 0)))
	first := int(v.scroll) * CATALOG_COLUMNS
	hovered := game.NO_ITEM
	ui.push_clip_rect(ctx, r)
	defer {
		ui.pop_clip_rect(ctx)
		if hovered != game.NO_ITEM && game.stack_empty(s.inventory.cursor) {
			item_tooltip(ctx, item_title(hovered))
		}
	}
	for k in first ..< len(items) {
		i := k - first
		row, col := i / CATALOG_COLUMNS, i % CATALOG_COLUMNS
		if row >= visible {break}
		slot := ui.Rect {
			r.x + f32(col) * (INVENTORY_SLOT.x + gap),
			r.y + f32(row) * (INVENTORY_SLOT.y + gap),
			INVENTORY_SLOT.x,
			INVENTORY_SLOT.y,
		}
		over := ui.rect_contains(slot, ctx.input.mouse)
		stack_slot(ctx, &app.item_icons, slot, {items[k], 1}, over)
		if over {hovered = items[k]}
		if top && over && .Left in ctx.input.mouse_pressed {
			session_inventory_do(s, {.Take, game.CURSOR_SLOT, int(items[k])})
		}
	}
}

// slot_takes: a slot a spread or a one-each drag may put into: empty, or
// holding the cursor's item.
@(private = "file")
slot_takes :: proc(inv: ^game.Inventory, slot: int) -> bool {
	st := game.slot_at(inv, slot)^
	return(
		game.slot_accepts(slot, inv.cursor) &&
		(game.stack_empty(st) || st.item == inv.cursor.item) \
	)
}

// inventory_mouse: the mouse over the slots (hovered: -1 for none): clicks
// and drags, the wheel, a middle click.
@(private = "file")
inventory_mouse :: proc(app: ^App, ctx: ^ui.Context, panel: ui.Rect, hovered: int, catalog: bool) {
	s := app.session
	v := &app.inventory_view
	inv := &s.inventory
	mouse := ctx.input.mouse
	pressed, released, down :=
		ctx.input.mouse_pressed, ctx.input.mouse_released, ctx.input.mouse_down
	shift := .Shift in ctx.input.modifiers
	do_ :: proc(s: ^Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		session_inventory_do(s, {kind, slot, arg})
	}
	begin :: proc(v: ^Inventory_View, mode: Drag_Mode, slot: int) {
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
		if entered && .Right in down && slot_takes(inv, hovered) {do_(s, .Click_Right, hovered)}
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
spread_stack :: proc(s: ^Session, v: ^Inventory_View) {
	inv := &s.inventory
	slots := make([dynamic]int, context.temp_allocator)
	visited := 0
	for i in 0 ..< game.ALL_SLOTS {
		if !v.visited[i] {continue}
		visited += 1
		if slot_takes(inv, i) {append(&slots, i)}
	}
	if visited <= 1 {
		session_inventory_do(s, {.Click, v.first, 0})
		return
	}
	if len(slots) == 0 {return}
	left := inv.cursor.count
	share := max(1, left / len(slots))
	for i in slots {
		put := min(share, left)
		if put <= 0 {break}
		session_inventory_do(s, {.Put, i, put})
		left = inv.cursor.count
	}
}

// matching_items: the items whose names contain query (any case; every item
// when it is empty).
matching_items :: proc(query: string) -> []game.Item {
	all := game.every_item()
	if len(query) == 0 {return all}
	q := strings.to_lower(query, context.temp_allocator)
	found := make([dynamic]game.Item, context.temp_allocator)
	for item in all {
		name := strings.to_lower(item_title(item), context.temp_allocator)
		if strings.contains(name, q) {append(&found, item)}
	}
	return found[:]
}

@(private = "file", rodata)
EQUIP_LABELS := [game.Equip_Slot]string {
	.Head    = "Head",
	.Chest   = "Chest",
	.Legs    = "Legs",
	.Feet    = "Feet",
	.Offhand = "Offhand",
}

// PREVIEW_IMAGE: the ui image the player's preview is (the renderer maps it).
PREVIEW_IMAGE :: ui.Image(1)

// player_preview shows the player (drawn to a texture by the renderer,
// app.preview) turned toward the mouse.
@(private = "file")
player_preview :: proc(app: ^App, ctx: ^ui.Context, r: ui.Rect) {
	t := &ctx.theme
	ui.fill_rect(ctx, r, t.preview_fill)
	ui.stroke_rect(ctx, r, 1, t.faint_border)
	// Where the mouse is from the middle of the player's chest: turn and look
	// that way, within limits.
	mouse := ctx.input.mouse
	dx := (mouse.x - (r.x + r.w / 2)) / (r.w * 2)
	dy := ((r.y + r.h * 0.3) - mouse.y) / (r.h * 2)
	app.preview.active = true
	app.preview.target_yaw = clamp(dx * 1.6, -0.9, 0.9)
	app.preview.target_pitch = clamp(dy * 1.4, -0.6, 0.6)
	ui.draw_image(ctx, r, PREVIEW_IMAGE)
}
