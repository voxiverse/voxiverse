package ui

import "core:testing"

// The list's arithmetic: what is in view, what a page is, where the thumb is.
@(test)
test_list_view_arithmetic :: proc(t: ^testing.T) {
	testing.expect_value(t, list_visible(300, 60), 5)
	testing.expect_value(t, list_visible(299, 60), 4) // (a row cut short is not whole)
	testing.expect_value(t, list_visible(10, 60), 1)

	// The view never runs past the last page, nor before the first row.
	testing.expect_value(t, list_clamp_first(-3, 20, 5), 0)
	testing.expect_value(t, list_clamp_first(18, 20, 5), 15)
	testing.expect_value(t, list_clamp_first(4, 3, 5), 0) // (all of them fit)

	// The selected row is kept in view, the view moving as little as it can.
	testing.expect_value(t, list_keep_in_view(2, 4, 5), 2) // above: it leads
	testing.expect_value(t, list_keep_in_view(12, 4, 5), 8) // below: it ends the view
	testing.expect_value(t, list_keep_in_view(6, 4, 5), 4) // in view: stays
	testing.expect_value(t, list_keep_in_view(-1, 4, 5), 4) // none selected

	// Page Up and Down move by the rows in view; Home and End to the ends.
	testing.expect_value(t, list_jump(3, 20, 5, {.Page_Down}), 8)
	testing.expect_value(t, list_jump(18, 20, 5, {.Page_Down}), 19)
	testing.expect_value(t, list_jump(3, 20, 5, {.Page_Up}), 0)
	testing.expect_value(t, list_jump(-1, 20, 5, {.Page_Down}), 5)
	testing.expect_value(t, list_jump(7, 20, 5, {.Home}), 0)
	testing.expect_value(t, list_jump(7, 20, 5, {.End}), 19)
	testing.expect_value(t, list_jump(-1, 0, 5, {.End}), -1) // (nothing to pick)

	// The row under a point.
	rows := Rect{100, 100, 300, 300}
	testing.expect_value(t, list_row_at(rows, 0, 20, 60, {150, 110}), 0)
	testing.expect_value(t, list_row_at(rows, 4, 20, 60, {150, 230}), 6)
	testing.expect_value(t, list_row_at(rows, 0, 3, 60, {150, 350}), -1) // past the last row
	testing.expect_value(t, list_row_at(rows, 0, 20, 60, {50, 110}), -1) // beside the list

	// The thumb: as tall as the share in view, at the top, the bottom, and back again.
	track := Rect{400, 100, 12, 300}
	top := list_thumb(track, 20, 5, 0)
	testing.expect_value(t, top.h, 75)
	testing.expect_value(t, top.y, 100)
	bottom := list_thumb(track, 20, 5, 15)
	testing.expect_value(t, bottom.y + bottom.h, 400)
	testing.expect_value(t, list_thumb(track, 1000, 5, 0).h, SCROLLBAR_THUMB_MIN)
	for first in 0 ..= 15 {
		thumb := list_thumb(track, 20, 5, first)
		testing.expect_value(t, list_first_at(track, 20, 5, thumb.y), first)
	}
	testing.expect_value(t, list_first_at(track, 20, 5, -50), 0)
	testing.expect_value(t, list_first_at(track, 20, 5, 900), 15)
}

// A list of 50 rows, 5 in view, in frames: the keyboard keeps the selection in view and
// leaves at the ends, the wheel scrolls, a click selects, the thumb drags, and Confirm
// activates.
@(test)
test_list_in_use :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	state := Scroll_List {
		selected = -1,
	}
	AREA :: Rect{100, 100, 300, 300}
	frame :: proc(ctx: ^Context, in_: Input, state: ^Scroll_List) -> (activated, clicked: int) {
		activated, clicked = -1, -1
		begin_frame(ctx, in_, SCREEN, 1)
		view := list_begin(ctx, "rows", AREA, 50, 60, state)
		for i in view.first ..< view.last {
			if _, it := list_row(ctx, &view, i); it.clicked {clicked = i}
		}
		if list_end(ctx, &view) {activated = state.selected}
		button(ctx, "after", {100, 420, 100, 30})
		end_frame(ctx)
		return
	}
	frame(ctx, nav({}), &state)
	testing.expect_value(t, focused_label(ctx), "rows")
	for _ in 0 ..< 7 {frame(ctx, nav({.Down}), &state)}
	testing.expect_value(t, state.selected, 6)
	testing.expect_value(t, state.first, 2) // (row 6 ends the view)
	frame(ctx, keys({.End}), &state)
	testing.expect_value(t, state.selected, 49)
	testing.expect_value(t, state.first, 45)
	frame(ctx, keys({.Page_Up}), &state)
	testing.expect_value(t, state.selected, 44)
	testing.expect_value(t, state.first, 44)
	frame(ctx, keys({.Home}), &state)
	testing.expect_value(t, state.selected, 0)
	testing.expect_value(t, state.first, 0)
	activated, _ := frame(ctx, nav({.Confirm}), &state)
	testing.expect_value(t, activated, 0)
	frame(ctx, keys({.End}), &state)
	frame(ctx, nav({.Down}), &state) // the last row: Down leaves the list
	testing.expect_value(t, focused_label(ctx), "after")

	// The wheel scrolls under the pointer; the selection stays where it was.
	frame(ctx, {mouse = {200, 200}, wheel = {0, 50}}, &state)
	testing.expect_value(t, state.first, 0)
	frame(ctx, {mouse = {200, 200}, wheel = {0, -3}}, &state)
	testing.expect_value(t, state.first, 3)
	testing.expect_value(t, state.selected, 49)

	// A click on a row selects it (row 3 leads the view: the second row shown is 4).
	p := Vec2{200, 100 + 60 + 30}
	frame(ctx, at(p), &state)
	frame(ctx, press(p), &state)
	_, clicked := frame(ctx, release(p), &state)
	testing.expect_value(t, clicked, 4)
	testing.expect_value(t, state.selected, 4)
	testing.expect_value(t, focused_label(ctx), "rows")

	// The thumb, taken and dragged to the bottom of the track, shows the last page; a
	// click on the track above it turns a page back.
	track := Rect{AREA.x + AREA.w - SCROLLBAR_WIDTH, AREA.y, SCROLLBAR_WIDTH, AREA.h}
	thumb := list_thumb(track, 50, 5, state.first)
	grip := Vec2{track.x + 6, thumb.y + 4}
	frame(ctx, at(grip), &state)
	frame(ctx, press(grip), &state)
	frame(ctx, hold({grip.x + 40, 1000}), &state) // (off the bar: still dragging)
	testing.expect_value(t, state.first, 45)
	frame(ctx, release({grip.x + 40, 1000}), &state)
	above := Vec2{track.x + 6, track.y + 10}
	frame(ctx, at(above), &state)
	frame(ctx, press(above), &state)
	frame(ctx, release(above), &state)
	testing.expect_value(t, state.first, 40)
	testing.expect_value(t, state.selected, 4) // (scrolling picks nothing)
}

// A list whose rows all fit has no scrollbar: the rows have the whole width.
@(test)
test_list_short_has_no_scrollbar :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	state: Scroll_List
	begin_frame(ctx, {}, SCREEN, 1)
	view := list_begin(ctx, "rows", {100, 100, 300, 300}, 3, 60, &state)
	testing.expect_value(t, view.rows.w, 300)
	testing.expect_value(t, view.last, 3)
	list_end(ctx, &view)
	end_frame(ctx)
}
