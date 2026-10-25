package client

import "core:fmt"
import "core:strings"
import "core:time"

import "../game"
import "../ui"

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
	ui.fill_rect(ctx, r, {0, 0, 0, 230}) // (blending is linear: lighter than it reads)
	ui.stroke_rect(ctx, r, 2 if selected else 1, t.text if selected else {255, 255, 255, 60})
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
			{0, 0, 0, 255},
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
			{0, 0, 0, 255},
			.Right,
		)
		ui.draw_text(ctx, corner, count, small, t.text, .Right)
	}
}

// tooltip: name in a box by the mouse.
tooltip :: proc(ctx: ^ui.Context, name: string) {
	t := &ctx.theme
	mouse := ctx.input.mouse
	w := ui.measure_text(ctx, name, t.font_size) + 2 * t.padding
	tip := ui.Rect{mouse.x + 12, mouse.y + 12, w, t.row_height}
	ui.fill_rect(ctx, tip, {0, 0, 0, 230})
	ui.draw_text(ctx, ui.rect_shrink(tip, t.padding), name, t.font_size, t.text)
}

// The inventory overlay (`e`): the inventory over the game (it runs on).
// Click picks a stack up, puts it down, merges or swaps it; dragging a
// stack from one slot to another moves it; right-click takes half or puts
// one down; shift-click moves it between the hotbar and the rest; a number
// key over a slot swaps it with that hotbar slot; Q over a slot drops one
// (Ctrl+Q: all); a click outside drops what the cursor holds. Players with
// items.catalog also see every item, to take a stack of, and a middle click
// on a slot takes a full stack of its item.
//
// Mouse tweaks (after the mod of that name), each a sequence of the same
// requests the plain clicks make: shift-drag quick-moves every slot passed;
// a right-drag puts one into each slot passed; a left-drag with a stack on
// the cursor shares it evenly over the slots passed (a click on one slot
// is a plain click); a double-click gathers every stack of the cursor's
// item onto the cursor; the wheel over a slot moves one at a time between
// the hotbar and the rest (up: out of the slot, down: into it).

INVENTORY_COLUMNS :: 5
CATALOG_COLUMNS :: 6
DOUBLE_CLICK_SECONDS :: 0.3

Drag_Mode :: enum u8 {
	None,
	Quick, // shift + left: quick-move each slot entered
	Spread, // left with a stack on the cursor: share it over the slots entered
	One_Each, // right with a stack on the cursor: one into each slot entered
}

Inventory_View :: struct {
	drag_from:  int, // the slot a drag began on (-1: none)
	scroll:     f32, // catalog rows scrolled
	mode:       Drag_Mode,
	visited:    [game.INVENTORY_SLOTS]bool, // the slots the drag has passed
	first:      int, // where the drag began
	click_slot: int, // the last left press (-1: none), for double-clicks
	click_time: time.Tick,
}

// inventory_keys: the inventory key over the game opens the inventory, and closes it.
inventory_keys :: proc(app: ^App) {
	s := app.session
	if s == nil ||
	   s.state != .Playing ||
	   app.settings.keys.inventory not_in app.input.pressed {return}
	if overlay_is_open(&app.overlays, .Inventory) {
		top, _ := overlay_top(&app.overlays)
		if top == .Inventory {inventory_close(app)}
	} else if game_controls(app) {
		inventory_open(app)
	}
}

// inventory_open shows the overlay, fresh.
inventory_open :: proc(app: ^App) {
	overlay_open(&app.overlays, .Inventory)
	app.inventory_view = {
		drag_from  = -1,
		click_slot = -1,
	}
}

// inventory_close: the cursor's stack back in (the server drops what does
// not fit).
inventory_close :: proc(app: ^App) {
	overlay_close(&app.overlays, .Inventory)
	if s := app.session; s != nil && !game.stack_empty(s.inventory.cursor) {
		session_inventory_do(s, {.Close, game.CURSOR_SLOT, 0})
	}
}

// inventory_layout: where each slot is (UI units): the rest above, the
// hotbar below, and the catalog to the right.
@(private)
Inventory_Layout :: struct {
	panel:   ui.Rect,
	slots:   [game.INVENTORY_SLOTS]ui.Rect,
	catalog: ui.Rect, // empty: no catalog
}

@(private)
inventory_layout :: proc(ctx: ^ui.Context, catalog: bool) -> (l: Inventory_Layout) {
	t := &ctx.theme
	gap := t.spacing
	grid_w := INVENTORY_COLUMNS * (INVENTORY_SLOT.x + gap) - gap
	rest_rows := (game.INVENTORY_SLOTS - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS
	rows_h := f32(rest_rows + 1) * (INVENTORY_SLOT.y + gap) + 2 * gap // the rest, a gap, the hotbar
	catalog_w := CATALOG_COLUMNS * (INVENTORY_SLOT.x + gap) if catalog else 0
	w := grid_w + catalog_w + 2 * t.padding
	h := rows_h + t.row_height + 2 * t.padding
	l.panel = ui.rect_center(ctx.screen, w, h)
	inner := ui.rect_shrink(l.panel, t.padding)
	ui.cut_top(&inner, t.row_height)
	if catalog {l.catalog = ui.cut_right(&inner, catalog_w - gap)}
	for i in 0 ..< game.INVENTORY_SLOTS {
		row, col := (i - game.HOTBAR_SLOTS) / INVENTORY_COLUMNS, i % INVENTORY_COLUMNS
		y := inner.y + f32(row) * (INVENTORY_SLOT.y + gap)
		if i <
		   game.HOTBAR_SLOTS {y = inner.y + f32(rest_rows) * (INVENTORY_SLOT.y + gap) + 2 * gap}
		l.slots[i] = {
			inner.x + f32(col) * (INVENTORY_SLOT.x + gap),
			y,
			INVENTORY_SLOT.x,
			INVENTORY_SLOT.y,
		}
	}
	return
}

// inventory_ui: the overlay (top: it takes the keys).
inventory_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	t := &ctx.theme
	inv := &s.inventory
	catalog := session_allowed(s, "items.catalog")
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	l := inventory_layout(ctx, catalog)
	ui.panel(ctx, l.panel)
	title := ui.rect_shrink(l.panel, t.padding)
	ui.title(ctx, "Inventory", {title.x, title.y, title.w, t.row_height}, .Left)
	mouse := ctx.input.mouse
	hovered := -1
	for r, i in l.slots {
		if ui.rect_contains(r, mouse) {hovered = i}
		stack_slot(ctx, &app.item_icons, r, inv.slots[i], i == hovered)
	}
	do_ :: proc(s: ^Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		session_inventory_do(s, {kind, slot, arg})
	}
	if top {
		inventory_mouse(app, ctx, l.panel, hovered, catalog)
		if hovered >= 0 {
			for k, n in hotbar_keys(app.settings.keys) {
				if k in app.input.pressed {do_(s, .Swap_Hotbar, hovered, n)}
			}
			if app.settings.keys.drop in app.input.pressed {
				all := app.input.held & {.Left_Control, .Right_Control} != {}
				do_(s, .Drop, hovered, 1 if all else 0)
			}
		}
	}
	if catalog {catalog_ui(app, ctx, l.catalog, top)}
	// What is hovered, and what the cursor holds.
	if hovered >= 0 && !game.stack_empty(inv.slots[hovered]) && game.stack_empty(inv.cursor) {
		tooltip(ctx, item_title(inv.slots[hovered].item))
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

// catalog_ui: every item; a click puts a full stack of it on the cursor.
@(private = "file")
catalog_ui :: proc(app: ^App, ctx: ^ui.Context, r: ui.Rect, top: bool) {
	s := app.session
	t := &ctx.theme
	v := &app.inventory_view
	items := game.every_item()
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
			tooltip(ctx, item_title(hovered))
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
	st := inv.slots[slot]
	return game.stack_empty(st) || st.item == inv.cursor.item
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
		if catalog && game.stack_empty(inv.cursor) && !game.stack_empty(inv.slots[hovered]) {
			do_(s, .Take, game.CURSOR_SLOT, int(inv.slots[hovered].item))
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
	for i in 0 ..< game.INVENTORY_SLOTS {
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
