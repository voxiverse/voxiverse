package ui

// Layout by cutting rectangles. A layout is a container rect; next() cuts
// the next widget's rect off its top (vertical) or left (horizontal), with
// spacing. The cut_* helpers do the same on any rect.
//
//	ui.layout_begin(ctx, ui.rect_center(ctx.screen, 320, 300))
//	if ui.button(ctx, "Play", ui.next(ctx)) { ... }
//	if ui.button(ctx, "Quit", ui.next(ctx)) { ... }
//	ui.layout_end(ctx)

Direction :: enum u8 {
	Vertical,
	Horizontal,
}

Layout :: struct {
	rect:      Rect, // what is left
	direction: Direction,
	spacing:   f32,
}

layout_begin :: proc(
	ctx: ^Context,
	r: Rect,
	direction := Direction.Vertical,
	spacing: Maybe(f32) = nil,
) {
	assert(ctx.layout_depth < MAX_LAYOUT_DEPTH, "ui: layout stack overflow")
	ctx.layouts[ctx.layout_depth] = Layout{r, direction, spacing.? or_else ctx.theme.spacing}
	ctx.layout_depth += 1
}

layout_end :: proc(ctx: ^Context) {
	assert(ctx.layout_depth > 0, "ui: layout_end without layout_begin")
	ctx.layout_depth -= 1
}

begin_column :: proc(ctx: ^Context, r: Rect, spacing: Maybe(f32) = nil) {
	layout_begin(ctx, r, .Vertical, spacing)
}

end_column :: proc(ctx: ^Context) {
	layout_end(ctx)
}

begin_row :: proc(ctx: ^Context, r: Rect, spacing: Maybe(f32) = nil) {
	layout_begin(ctx, r, .Horizontal, spacing)
}

end_row :: proc(ctx: ^Context) {
	layout_end(ctx)
}

// Anchor: where a child rect or point is positioned relative to a parent rect.
Anchor :: enum u8 {
	Top_Left,
	Top_Center,
	Top_Right,
	Center_Left,
	Center,
	Center_Right,
	Bottom_Left,
	Bottom_Center,
	Bottom_Right,
}

// anchor_rect returns a rect of `size` positioned relative to `parent` according
// to `anchor`, shifted by `offset`.
anchor_rect :: proc(parent: Rect, anchor: Anchor, size: Vec2, offset: Vec2 = {0, 0}) -> Rect {
	p := anchor_point(parent, anchor, offset)
	x := p.x
	y := p.y
	switch anchor {
	case .Top_Left:
	case .Top_Center:
		x -= size.x / 2
	case .Top_Right:
		x -= size.x
	case .Center_Left:
		y -= size.y / 2
	case .Center:
		x -= size.x / 2
		y -= size.y / 2
	case .Center_Right:
		x -= size.x
		y -= size.y / 2
	case .Bottom_Left:
		y -= size.y
	case .Bottom_Center:
		x -= size.x / 2
		y -= size.y
	case .Bottom_Right:
		x -= size.x
		y -= size.y
	}
	return Rect{x, y, size.x, size.y}
}

// anchor_point returns the coordinate point on `parent` for `anchor`, shifted by `offset`.
anchor_point :: proc(parent: Rect, anchor: Anchor, offset: Vec2 = {0, 0}) -> Vec2 {
	x, y: f32
	switch anchor {
	case .Top_Left:
		x, y = parent.x, parent.y
	case .Top_Center:
		x, y = parent.x + parent.w / 2, parent.y
	case .Top_Right:
		x, y = parent.x + parent.w, parent.y
	case .Center_Left:
		x, y = parent.x, parent.y + parent.h / 2
	case .Center:
		x, y = parent.x + parent.w / 2, parent.y + parent.h / 2
	case .Center_Right:
		x, y = parent.x + parent.w, parent.y + parent.h / 2
	case .Bottom_Left:
		x, y = parent.x, parent.y + parent.h
	case .Bottom_Center:
		x, y = parent.x + parent.w / 2, parent.y + parent.h
	case .Bottom_Right:
		x, y = parent.x + parent.w, parent.y + parent.h
	}
	return Vec2{x + offset.x, y + offset.y}
}

// next cuts the next rect from the current layout: `size` along its
// direction (row height by default), the full extent across it.
next :: proc(ctx: ^Context, size: f32 = 0) -> Rect {
	assert(ctx.layout_depth > 0, "ui: next() needs layout_begin")
	l := &ctx.layouts[ctx.layout_depth - 1]
	amount := size if size > 0 else ctx.theme.row_height
	r: Rect
	switch l.direction {
	case .Vertical:
		r = cut_top(&l.rect, amount)
		cut_top(&l.rect, l.spacing)
	case .Horizontal:
		r = cut_left(&l.rect, amount)
		cut_left(&l.rect, l.spacing)
	}
	return r
}

cut_top :: proc(r: ^Rect, amount: f32) -> Rect {
	a := min(amount, r.h)
	out := Rect{r.x, r.y, r.w, a}
	r.y += a
	r.h -= a
	return out
}

cut_bottom :: proc(r: ^Rect, amount: f32) -> Rect {
	a := min(amount, r.h)
	r.h -= a
	return {r.x, r.y + r.h, r.w, a}
}

cut_left :: proc(r: ^Rect, amount: f32) -> Rect {
	a := min(amount, r.w)
	out := Rect{r.x, r.y, a, r.h}
	r.x += a
	r.w -= a
	return out
}

cut_right :: proc(r: ^Rect, amount: f32) -> Rect {
	a := min(amount, r.w)
	r.w -= a
	return {r.x + r.w, r.y, a, r.h}
}
