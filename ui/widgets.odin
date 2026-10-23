package ui

import "core:fmt"
import "core:unicode/utf8"

// Widgets. Each takes its rect (usually ui.next(ctx)) and goes through
// interact(), so hover, clicks, focus and layers behave the same for all.

label :: proc(
	ctx: ^Context,
	text: string,
	r: Rect,
	align := Align.Left,
	color: Maybe(Color) = nil,
) {
	draw_text(ctx, r, text, ctx.theme.font_size, color.? or_else ctx.theme.text, align)
}

title :: proc(ctx: ^Context, text: string, r: Rect, align := Align.Center) {
	draw_text(ctx, r, text, ctx.theme.title_size, ctx.theme.text, align)
}

// panel draws a framed background.
panel :: proc(ctx: ^Context, r: Rect) {
	fill_rect(ctx, r, ctx.theme.background)
	stroke_rect(ctx, r, ctx.theme.border_width, ctx.theme.border)
}

// backdrop dims everything below the current layer (use on .Modal).
backdrop :: proc(ctx: ^Context) {
	fill_rect(ctx, ctx.screen, ctx.theme.backdrop)
}

button :: proc(ctx: ^Context, text: string, r: Rect, disabled := false) -> bool {
	t := &ctx.theme
	shown := display_label(text)
	if disabled {
		stroke_rect(ctx, r, t.border_width, with_alpha(t.border, t.disabled_alpha))
		draw_text(ctx, r, shown, t.font_size, with_alpha(t.text, t.disabled_alpha), .Center)
		return false
	}
	it := interact(ctx, get_id(ctx, text), r)
	fill, ink := t.background, t.text
	if it.pressed {
		fill, ink = t.pressed, t.hover_text
	} else if it.hovered || (it.focused && ctx.focus_visible) {
		fill, ink = t.hover, t.hover_text
	}
	fill_rect(ctx, r, fill)
	stroke_rect(ctx, r, t.border_width, t.border)
	draw_text(ctx, r, shown, t.font_size, ink, .Center)
	focus_ring(ctx, r, it)
	return it.clicked
}

// checkbox toggles value; returns true when it changed.
checkbox :: proc(ctx: ^Context, text: string, value: ^bool, r: Rect) -> bool {
	t := &ctx.theme
	it := interact(ctx, get_id(ctx, text), r)
	if it.clicked {value^ = !value^}
	box_size := r.h - 2 * t.padding
	row := r
	box := cut_left(&row, box_size + 2 * t.padding)
	box = rect_center(box, box_size, box_size)
	if it.hovered {fill_rect(ctx, r, with_alpha(t.hover, 40))}
	stroke_rect(ctx, box, t.border_width, t.border)
	if value^ {fill_rect(ctx, rect_shrink(box, 4), t.text)}
	draw_text(ctx, row, display_label(text), t.font_size, t.text)
	focus_ring(ctx, r, it)
	return it.clicked
}

// slider edits value within [lo, hi]: drag with the mouse, or Left/Right
// (step `step`) when focused. Returns true when it changed.
slider :: proc(
	ctx: ^Context,
	text: string,
	value: ^f32,
	lo, hi: f32,
	r: Rect,
	step: f32 = 0,
	format := "%.2f",
) -> bool {
	t := &ctx.theme
	id := get_id(ctx, text)
	it := interact(ctx, id, r)
	old := value^
	row := r
	label_rect := cut_left(&row, r.w * 0.4)
	value_rect := cut_right(&row, 70)
	track := rect_shrink(row, t.padding)
	if it.pressed && track.w > 0 {
		frac := clamp((ctx.input.mouse.x - track.x) / track.w, 0, 1)
		value^ = lo + frac * (hi - lo)
	}
	if it.focused {
		s := step if step > 0 else (hi - lo) / 20
		if .Left in ctx.input.keys_pressed {value^ -= s}
		if .Right in ctx.input.keys_pressed {value^ += s}
	}
	value^ = clamp(value^, lo, hi)

	if it.hovered {fill_rect(ctx, r, with_alpha(t.hover, 40))}
	draw_text(ctx, label_rect, display_label(text), t.font_size, t.text)
	stroke_rect(ctx, track, t.border_width, t.border)
	frac := (value^ - lo) / (hi - lo) if hi > lo else 0
	fill_rect(ctx, {track.x, track.y, track.w * frac, track.h}, t.text)
	draw_text(ctx, value_rect, fmt.tprintf(format, value^), t.font_size, t.text, .Right)
	focus_ring(ctx, r, it)
	return value^ != old
}

// Text_Edit is the editing state of the focused text field (one at a time).
Text_Edit :: struct {
	id:     Id,
	active: bool,
	cursor: int, // byte offsets into the text
	anchor: int, // selection is [min(cursor, anchor), max(...))
}

// text_input edits a caller-owned single-line buffer. Returns true when
// Enter is pressed in it.
text_input :: proc(
	ctx: ^Context,
	id_label: string,
	text: ^[dynamic]u8,
	r: Rect,
	placeholder := "",
) -> (
	submitted: bool,
) {
	t := &ctx.theme
	id := get_id(ctx, id_label)
	it := interact(ctx, id, r)
	e := &ctx.edit
	if it.focused {
		if e.id != id {
			// Gained focus: cursor to the end.
			e^ = {
				id     = id,
				cursor = len(text),
				anchor = len(text),
			}
		}
		e.active = true
		submitted = edit_text(ctx, e, text)
	} else if e.id == id {
		e.active = false
	}

	fill_rect(ctx, r, t.background)
	stroke_rect(ctx, r, t.border_width, t.border if it.focused || it.hovered else t.text_muted)
	inner := rect_shrink(r, t.padding)
	push_clip_rect(ctx, inner)
	defer pop_clip_rect(ctx)

	content := string(text[:])
	if len(content) == 0 && !it.focused {
		draw_text(ctx, inner, placeholder, t.font_size, t.text_muted)
		return
	}
	// Keep the cursor in view by scrolling the text left.
	cursor_x :=
		measure_text(ctx, content[:min(e.cursor, len(content))], t.font_size) if it.focused else 0
	shift := max(cursor_x - inner.w + 2, 0)
	if it.focused && e.cursor != e.anchor {
		a, b := min(e.cursor, e.anchor), max(e.cursor, e.anchor)
		x0 := measure_text(ctx, content[:a], t.font_size)
		x1 := measure_text(ctx, content[:b], t.font_size)
		fill_rect(ctx, {inner.x + x0 - shift, inner.y, x1 - x0, inner.h}, t.selection)
	}
	draw_text(
		ctx,
		{inner.x - shift, inner.y, inner.w + shift, inner.h},
		content,
		t.font_size,
		t.text,
	)
	if it.focused {
		fill_rect(ctx, {inner.x + cursor_x - shift, inner.y + 2, 1.5, inner.h - 4}, t.text)
	}
	return
}

// edit_text applies this frame's typing and editing keys to text.
@(private)
edit_text :: proc(ctx: ^Context, e: ^Text_Edit, text: ^[dynamic]u8) -> (submitted: bool) {
	in_ := &ctx.input
	keys := in_.keys_pressed
	shift, ctrl := .Shift in in_.modifiers, .Ctrl in in_.modifiers
	e.cursor = clamp(e.cursor, 0, len(text))
	e.anchor = clamp(e.anchor, 0, len(text))

	delete_selection :: proc(e: ^Text_Edit, text: ^[dynamic]u8) -> bool {
		if e.cursor == e.anchor {return false}
		a, b := min(e.cursor, e.anchor), max(e.cursor, e.anchor)
		remove_range(text, a, b)
		e.cursor, e.anchor = a, a
		return true
	}
	move :: proc(e: ^Text_Edit, to: int, extend: bool) {
		e.cursor = to
		if !extend {e.anchor = to}
	}

	if ctrl && .A in keys {
		e.anchor, e.cursor = 0, len(text)
	}
	if .Left in keys {
		if !shift &&
		   e.cursor !=
			   e.anchor {move(e, min(e.cursor, e.anchor), false)} else {move(e, prev_rune_start(text[:], e.cursor), shift)}
	}
	if .Right in keys {
		if !shift &&
		   e.cursor !=
			   e.anchor {move(e, max(e.cursor, e.anchor), false)} else {move(e, next_rune_start(text[:], e.cursor), shift)}
	}
	if .Home in keys {move(e, 0, shift)}
	if .End in keys {move(e, len(text), shift)}
	if .Backspace in keys {
		if !delete_selection(e, text) && e.cursor > 0 {
			start := prev_rune_start(text[:], e.cursor)
			remove_range(text, start, e.cursor)
			e.cursor, e.anchor = start, start
		}
	}
	if .Delete in keys {
		if !delete_selection(e, text) && e.cursor < len(text) {
			remove_range(text, e.cursor, next_rune_start(text[:], e.cursor))
		}
	}
	for r in in_.text {
		delete_selection(e, text)
		bytes, n := utf8.encode_rune(r)
		inject_at(text, e.cursor, ..bytes[:n])
		e.cursor += n
		e.anchor = e.cursor
	}
	return .Enter in keys
}

@(private)
prev_rune_start :: proc(s: []u8, i: int) -> int {
	j := i - 1
	for j > 0 && s[j] & 0xC0 == 0x80 {j -= 1}
	return max(j, 0)
}

@(private)
next_rune_start :: proc(s: []u8, i: int) -> int {
	if i >= len(s) {return len(s)}
	j := i + 1
	for j < len(s) && s[j] & 0xC0 == 0x80 {j += 1}
	return j
}

// focus_ring outlines the keyboard-focused widget (only while the keyboard
// is in use).
@(private)
focus_ring :: proc(ctx: ^Context, r: Rect, it: Interaction) {
	if it.focused && ctx.focus_visible {
		stroke_rect(ctx, {r.x - 3, r.y - 3, r.w + 6, r.h + 6}, 1, ctx.theme.focus_ring)
	}
}

with_alpha :: proc(c: Color, a: u8) -> Color {
	return {c.r, c.g, c.b, a}
}
