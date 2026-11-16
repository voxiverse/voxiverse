package ui

// A scrolling list: rows of one height in a clipped area, each drawn by the caller. The
// list is one focusable widget: Up and Down move the selection (and leave the list past
// its first and last row), Page Up, Page Down, Home and End jump, and the selected row is
// kept in view; Confirm activates it. The wheel and the pad's right stick scroll; when the
// rows do not all fit, a scrollbar on the right shows where the view is, its thumb drags
// and a click on its track turns a page. A click on a row selects it.
//
//	view := ui.list_begin(ctx, "games", area, len(games), ROW, &state)
//	for i in view.first ..< view.last {
//		r, it := ui.list_row(ctx, &view, i, games[i].name)
//		... draw row i in r (it.clicked: it was clicked this frame)
//	}
//	if ui.list_end(ctx, &view) {open(state.selected)}

SCROLLBAR_WIDTH :: 12
SCROLLBAR_THUMB_MIN :: 24 // the thumb's least height, however long the list

// Scroll_List: a list's place, kept by its caller between frames.
Scroll_List :: struct {
	selected: int, // the row picked (-1: none)
	first:    int, // the first row in view
	grab:     f32, // where the thumb was taken, from its top (while it is dragged)
}

// List_View: one frame of a list, from list_begin to list_end.
List_View :: struct {
	state:     ^Scroll_List,
	id:        Id,
	rows:      Rect, // where the rows are drawn (the area less the scrollbar)
	row_h:     f32,
	count:     int,
	first:     int, // the rows in view, first ..< last: those to draw
	last:      int,
	activated: bool, // Confirm on the focused list
}

// list_visible: how many rows of row_h a height shows whole (at least one).
list_visible :: proc(height, row_h: f32) -> int {
	return max(int(height / max(row_h, 1)), 1)
}

// list_clamp_first: first within the rows that can lead the view (the last page full).
list_clamp_first :: proc(first, count, visible: int) -> int {
	return clamp(first, 0, max(count - visible, 0))
}

// list_keep_in_view: the first row in view once selected is in it (moving as little as
// it can); first as it was with nothing selected.
list_keep_in_view :: proc(selected, first, visible: int) -> int {
	if selected < 0 {return first}
	if selected < first {return selected}
	if selected >= first + visible {return selected - visible + 1}
	return first
}

// list_jump: the selection after Page Up, Page Down, Home or End (a page is the rows
// in view); as it was without them.
list_jump :: proc(selected, count, visible: int, keys: bit_set[Key]) -> int {
	if count == 0 {return selected}
	s := selected
	if .Page_Up in keys {s = max(s, 0) - visible}
	if .Page_Down in keys {s = max(s, 0) + visible}
	if .Home in keys {s = 0}
	if .End in keys {s = count - 1}
	return clamp(s, 0, count - 1)
}

// list_row_at: the row under p (-1: none) in rows, first in view, of row_h.
list_row_at :: proc(rows: Rect, first, count: int, row_h: f32, p: Vec2) -> int {
	if !rect_contains(rows, p) {return -1}
	i := first + int((p.y - rows.y) / max(row_h, 1))
	return i if i < count else -1
}

// list_thumb: the scrollbar's thumb in track, its height the share of the rows in view,
// its place where the view is.
list_thumb :: proc(track: Rect, count, visible, first: int) -> Rect {
	if count <= visible {return track}
	h := max(track.h * f32(visible) / f32(count), min(SCROLLBAR_THUMB_MIN, track.h))
	travel := track.h - h
	most := count - visible
	return {
		track.x,
		track.y + travel * f32(list_clamp_first(first, count, visible)) / f32(most),
		track.w,
		h,
	}
}

// list_first_at: the first row in view with the thumb's top at y (the inverse of
// list_thumb, to the nearest row).
list_first_at :: proc(track: Rect, count, visible: int, y: f32) -> int {
	most := count - visible
	if most <= 0 {return 0}
	travel := track.h - list_thumb(track, count, visible, 0).h
	if travel <= 0 {return 0}
	share := clamp((y - track.y) / travel, 0, 1)
	return int(share * f32(most) + 0.5)
}

// list_begin starts a list of count rows of row_h in area (its fill and frame drawn,
// its rows clipped to it); draw the rows view.first ..< view.last with list_row, then
// call list_end.
list_begin :: proc(
	ctx: ^Context,
	text: string,
	area: Rect,
	count: int,
	row_h: f32,
	state: ^Scroll_List,
	loc := #caller_location,
) -> (
	view: List_View,
) {
	t := &ctx.theme
	fill_rect(ctx, area, t.list_fill)
	stroke_rect(ctx, area, 1, t.list_border)
	view.state, view.row_h, view.count = state, row_h, count
	view.rows = area
	visible := list_visible(area.h, row_h)
	scrolls := count > visible
	track: Rect
	if scrolls {track = cut_right(&view.rows, SCROLLBAR_WIDTH)}
	if state.selected >= count {state.selected = count - 1}

	view.id = get_id(ctx, text)
	it := interact(ctx, view.id, area, label = display_label(text), loc = loc)
	view.activated = it.focused && ctx.activate_focus && state.selected >= 0
	live := ctx.layer >= inert_below(ctx)
	if live && rect_contains(area, ctx.input.mouse) && ctx.input.wheel.y != 0 {
		state.first -= int(ctx.input.wheel.y)
	}
	if it.focused {
		moved := false
		if .Up in ctx.nav && state.selected > 0 {
			state.selected -= 1
			moved = true
			consume_nav(ctx, {.Up})
		}
		if .Down in ctx.nav && state.selected < count - 1 {
			state.selected += 1
			moved = true
			consume_nav(ctx, {.Down})
		}
		jumps := ctx.input.keys_pressed & {.Page_Up, .Page_Down, .Home, .End}
		if jumps != {} && !ctx.edit.active {
			state.selected = list_jump(state.selected, count, visible, jumps)
			moved = true
		}
		ctx.nav_accum += ctx.input.nav_scroll
		rows := int(ctx.nav_accum)
		state.first += rows
		ctx.nav_accum -= f32(rows)
		if moved {state.first = list_keep_in_view(state.selected, state.first, visible)}
	}

	if scrolls {
		push_id(ctx, text)
		thumb := list_thumb(track, count, visible, state.first)
		bar := interact(ctx, get_id(ctx, "track"), track, focusable = false)
		if bar.clicked {
			page := visible if ctx.input.mouse.y > thumb.y + thumb.h else -visible
			state.first += page
		}
		thumb_id := get_id(ctx, "thumb")
		grip := interact(ctx, thumb_id, thumb, focusable = false)
		if ctx.active == thumb_id && .Left in ctx.input.mouse_pressed {
			state.grab = ctx.input.mouse.y - thumb.y
		}
		if grip.pressed {
			state.first = list_first_at(track, count, visible, ctx.input.mouse.y - state.grab)
		}
		pop_id(ctx)
		state.first = list_clamp_first(state.first, count, visible)
		thumb = list_thumb(track, count, visible, state.first)
		stroke_rect(ctx, track, 1, t.list_border)
		lit := grip.hovered || grip.pressed
		fill_rect(ctx, rect_shrink(thumb, 2), t.hover if lit else t.faint_border)
		stroke_rect(ctx, rect_shrink(thumb, 2), 1, t.border)
	}
	state.first = list_clamp_first(state.first, count, visible)
	view.first = state.first
	view.last = min(count, state.first + visible + 1) // (and the one cut at the bottom)
	push_clip_rect(ctx, view.rows)
	return
}

// list_row: row i's rect, drawn hovered or selected as the list shows them; a click on it
// selects it (and gives the list the focus). label is what tests find it by.
list_row :: proc(
	ctx: ^Context,
	view: ^List_View,
	i: int,
	label := "",
	loc := #caller_location,
) -> (
	r: Rect,
	it: Interaction,
) {
	t := &ctx.theme
	r = {view.rows.x, view.rows.y + f32(i - view.first) * view.row_h, view.rows.w, view.row_h}
	push_id_int(ctx, i)
	it = interact(ctx, get_id(ctx, "row"), r, focusable = false, label = label, loc = loc)
	pop_id(ctx)
	if it.clicked {
		view.state.selected = i
		ctx.focused = view.id
	}
	if it.hovered {fill_rect(ctx, r, t.row_selected)}
	if view.state.selected == i {
		fill_rect(ctx, r, t.row_hover)
		stroke_rect(ctx, rect_shrink(r, 1), 1, t.text)
	}
	return
}

// list_end closes the list: the focus ring round the selected row (keyboard and pad);
// true when Confirm activated the selected row.
list_end :: proc(ctx: ^Context, view: ^List_View) -> (activated: bool) {
	pop_clip_rect(ctx)
	s := view.state.selected
	if ctx.focused == view.id && ctx.focus_visible && s >= view.first && s < view.last {
		row := Rect {
			view.rows.x,
			view.rows.y + f32(s - view.first) * view.row_h,
			view.rows.w,
			view.row_h,
		}
		stroke_rect(ctx, rect_intersect(rect_shrink(row, 2), view.rows), 1, ctx.theme.focus_ring)
	}
	return view.activated
}
