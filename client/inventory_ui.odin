package client

import "core:fmt"
import "core:strings"

import "../game"
import "../platform"
import "../ui"

// Slots as the UI draws them: the hotbar's and the inventory overlay's.

SLOT_SIZE :: ui.Vec2{120, 48} // the hotbar's
INVENTORY_SLOT :: ui.Vec2{88, 44} // the overlay's

// HOTBAR_KEYS: the number keys, one per hotbar slot.
HOTBAR_KEYS :: [game.HOTBAR_SLOTS]platform.Key{.Num_1, .Num_2, .Num_3, .Num_4, .Num_5}

// item_title: an item's name as players read it ("rocket launcher").
item_title :: proc(item: game.Item) -> string {
	name, _ := strings.replace_all(game.item_name(item), "_", " ", context.temp_allocator)
	return name
}

// stack_slot draws a slot holding stack: its name, its count (more than
// one), its number key (key > 0), framed when selected.
stack_slot :: proc(ctx: ^ui.Context, r: ui.Rect, stack: game.Stack, selected: bool, key := 0) {
	t := &ctx.theme
	ui.fill_rect(ctx, r, {0, 0, 0, 230}) // (blending is linear: lighter than it reads)
	ui.stroke_rect(ctx, r, 2 if selected else 1, t.text if selected else {255, 255, 255, 60})
	inner := ui.rect_shrink(r, 4)
	small := t.font_size * 0.75
	if key > 0 {
		ui.draw_text(ctx, {inner.x, inner.y, inner.w, small}, fmt.tprint(key), small, t.text_muted)
	}
	if game.stack_empty(stack) {return}
	ui.push_clip_rect(ctx, inner)
	title := item_title(stack.item)
	align := ui.Align.Center if ui.measure_text(ctx, title, small) <= inner.w else .Left
	ui.draw_text(ctx, inner, title, small, t.text, align)
	ui.pop_clip_rect(ctx)
	if stack.count > 1 {
		ui.draw_text(
			ctx,
			{inner.x, inner.y + inner.h - small, inner.w, small},
			fmt.tprint(stack.count),
			small,
			t.text,
			.Right,
		)
	}
}

// The inventory overlay (`e`): the inventory over the game (it runs on).
// Click picks a stack up, puts it down, merges or swaps it; dragging a
// stack from one slot to another moves it; right-click takes half or puts
// one down; shift-click moves it between the hotbar and the rest; a number
// key over a slot swaps it with that hotbar slot; Q over a slot drops one
// (Ctrl+Q: all); a click outside drops what the cursor holds. Players with
// items.catalog also see every item, to take a stack of.

INVENTORY_COLUMNS :: 5
CATALOG_COLUMNS :: 5

Inventory_View :: struct {
	drag_from: int, // the slot a drag began on (-1: none)
	scroll:    f32, // catalog rows scrolled
}

// inventory_keys: `e` over the game opens the inventory, and closes it.
inventory_keys :: proc(app: ^App) {
	s := app.session
	if s == nil || s.state != .Playing || .E not_in app.input.pressed {return}
	if overlay_is_open(&app.overlays, .Inventory) {
		top, _ := overlay_top(&app.overlays)
		if top == .Inventory {inventory_close(app)}
	} else if game_controls(app) {
		overlay_open(&app.overlays, .Inventory)
		app.inventory_view = {
			drag_from = -1,
		}
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
	v := &app.inventory_view
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
	pressed, released := ctx.input.mouse_pressed, ctx.input.mouse_released
	shift := .Shift in ctx.input.modifiers
	hovered := -1
	for r, i in l.slots {
		if ui.rect_contains(r, mouse) {hovered = i}
		stack_slot(ctx, r, inv.slots[i], i == hovered)
	}
	do_ :: proc(s: ^Session, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
		session_inventory_do(s, {kind, slot, arg})
	}
	if top {
		switch {
		case hovered >= 0 && .Left in pressed && shift:
			do_(s, .Quick_Move, hovered)
		case hovered >= 0 && .Left in pressed:
			had := !game.stack_empty(inv.cursor)
			do_(s, .Click, hovered)
			v.drag_from = -1 if had else hovered // a drag may begin here
		case hovered >= 0 && .Right in pressed:
			do_(s, .Click_Right, hovered)
		case .Left in released && v.drag_from >= 0:
			// Dropped on another slot: it goes there.
			if hovered >= 0 && hovered != v.drag_from {do_(s, .Click, hovered)}
			v.drag_from = -1
		case hovered < 0 &&
		     (.Left in pressed || .Right in pressed) &&
		     !ui.rect_contains(l.panel, mouse):
			do_(s, .Drop, game.CURSOR_SLOT, 1 if .Left in pressed else 0)
		}
		if hovered >= 0 {
			for k, n in HOTBAR_KEYS {if k in app.input.pressed {do_(s, .Swap_Hotbar, hovered, n)}}
			if .Q in app.input.pressed {
				all := app.input.held & {.Left_Control, .Right_Control} != {}
				do_(s, .Drop, hovered, 1 if all else 0)
			}
		}
	}
	if catalog {catalog_ui(app, ctx, l.catalog, top)}
	// What is hovered, and what the cursor holds.
	if hovered >= 0 && !game.stack_empty(inv.slots[hovered]) && game.stack_empty(inv.cursor) {
		name := item_title(inv.slots[hovered].item)
		w := ui.measure_text(ctx, name, t.font_size) + 2 * t.padding
		tip := ui.Rect{mouse.x + 12, mouse.y + 12, w, t.row_height}
		ui.fill_rect(ctx, tip, {0, 0, 0, 230})
		ui.draw_text(ctx, ui.rect_shrink(tip, t.padding), name, t.font_size, t.text)
	}
	if !game.stack_empty(inv.cursor) {
		stack_slot(
			ctx,
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
	ui.push_clip_rect(ctx, r)
	defer ui.pop_clip_rect(ctx)
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
		stack_slot(ctx, slot, {items[k], 1}, over)
		if top && over && .Left in ctx.input.mouse_pressed {
			session_inventory_do(s, {.Take, game.CURSOR_SLOT, int(items[k])})
		}
	}
}
