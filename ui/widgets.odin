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

button :: proc(
	ctx: ^Context,
	text: string,
	r: Rect,
	disabled := false,
	loc := #caller_location,
) -> bool {
	t := &ctx.theme
	shown := display_label(text)
	if disabled {
		stroke_rect(ctx, r, t.border_width, with_alpha(t.border, t.disabled_alpha))
		draw_text(ctx, r, shown, t.font_size, with_alpha(t.text, t.disabled_alpha), .Center)
		return false
	}
	it := interact(ctx, get_id(ctx, text), r, loc = loc)
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
checkbox :: proc(
	ctx: ^Context,
	text: string,
	value: ^bool,
	r: Rect,
	loc := #caller_location,
) -> bool {
	t := &ctx.theme
	it := interact(ctx, get_id(ctx, text), r, loc = loc)
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
	loc := #caller_location,
) -> bool {
	t := &ctx.theme
	id := get_id(ctx, text)
	it := interact(ctx, id, r, loc = loc)
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
	loc := #caller_location,
) -> (
	submitted: bool,
) {
	t := &ctx.theme
	id := get_id(ctx, id_label)
	it := interact(ctx, id, r, loc = loc)
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

// edit_text applies this frame's typing and editing keys to text: the
// usual arrows, Home/End, Backspace/Delete, and the readline (Emacs) keys
// shells and Claude Code use:
//
//	Ctrl+A / Ctrl+E          start / end of the line
//	Ctrl+B / Ctrl+F          back / forward a character
//	Alt+B / Alt+F, Ctrl+←/→  back / forward a word
//	Ctrl+W                   kill back to the previous space
//	Alt+Backspace, Ctrl+Backspace   kill the word before the cursor
//	Alt+D, Ctrl+Delete       kill the word after it
//	Ctrl+U / Ctrl+K          kill to the start / end of the line
//	Ctrl+Y                   yank (insert) the last text killed
//	Ctrl+D, Ctrl+H           delete forward / backward a character
//
// Shift with a movement extends the selection. Text typed with Alt (not
// AltGr, which is Ctrl+Alt) is a shortcut, not text.
@(private)
edit_text :: proc(ctx: ^Context, e: ^Text_Edit, text: ^[dynamic]u8) -> (submitted: bool) {
	in_ := &ctx.input
	keys := in_.keys_pressed
	shift, ctrl, alt := .Shift in in_.modifiers, .Ctrl in in_.modifiers, .Alt in in_.modifiers
	ctrl_only, alt_only := ctrl && !alt, alt && !ctrl
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
	// kill removes [a, b) into the kill buffer.
	kill :: proc(ctx: ^Context, e: ^Text_Edit, text: ^[dynamic]u8, a, b: int) {
		if a >= b {return}
		ctx.kill_len = copy(ctx.kill[:], text[a:b])
		remove_range(text, a, b)
		e.cursor, e.anchor = a, a
	}
	left := .Left in keys || ctrl_only && .B in keys
	right := .Right in keys || ctrl_only && .F in keys
	word_left := ctrl_only && .Left in keys || alt_only && .B in keys
	word_right := ctrl_only && .Right in keys || alt_only && .F in keys

	switch {
	case word_left:
		move(e, word_start(text[:], e.cursor), shift)
	case word_right:
		move(e, word_end(text[:], e.cursor), shift)
	case left:
		if !shift && e.cursor != e.anchor {
			move(e, min(e.cursor, e.anchor), false)
		} else {
			move(e, prev_rune_start(text[:], e.cursor), shift)
		}
	case right:
		if !shift && e.cursor != e.anchor {
			move(e, max(e.cursor, e.anchor), false)
		} else {
			move(e, next_rune_start(text[:], e.cursor), shift)
		}
	}
	if .Home in keys || ctrl_only && .A in keys {move(e, 0, shift)}
	if .End in keys || ctrl_only && .E in keys {move(e, len(text), shift)}

	switch {
	case ctrl_only && .W in keys:
		if !delete_selection(e, text) {
			start := e.cursor
			for start > 0 && text[start - 1] == ' ' {start -= 1}
			for start > 0 && text[start - 1] != ' ' {start -= 1}
			kill(ctx, e, text, start, e.cursor)
		}
	case .Backspace in keys && (ctrl || alt):
		if !delete_selection(e, text) {kill(ctx, e, text, word_start(text[:], e.cursor), e.cursor)}
	case alt_only && .D in keys, ctrl_only && .Delete in keys:
		if !delete_selection(e, text) {kill(ctx, e, text, e.cursor, word_end(text[:], e.cursor))}
	case ctrl_only && .U in keys:
		kill(ctx, e, text, 0, e.cursor)
	case ctrl_only && .K in keys:
		kill(ctx, e, text, e.cursor, len(text))
	case ctrl_only && .Y in keys:
		delete_selection(e, text)
		inject_at(text, e.cursor, ..ctx.kill[:ctx.kill_len])
		e.cursor += ctx.kill_len
		e.anchor = e.cursor
	case .Backspace in keys, ctrl_only && .H in keys:
		if !delete_selection(e, text) && e.cursor > 0 {
			start := prev_rune_start(text[:], e.cursor)
			remove_range(text, start, e.cursor)
			e.cursor, e.anchor = start, start
		}
	case .Delete in keys, ctrl_only && .D in keys:
		if !delete_selection(e, text) && e.cursor < len(text) {
			remove_range(text, e.cursor, next_rune_start(text[:], e.cursor))
		}
	}
	if !alt_only {
		for r in in_.text {
			delete_selection(e, text)
			bytes, n := utf8.encode_rune(r)
			inject_at(text, e.cursor, ..bytes[:n])
			e.cursor += n
			e.anchor = e.cursor
		}
	}
	return .Enter in keys
}

// word_start: where the word before i begins (skipping spaces and
// punctuation first); a word is letters, digits, _ and anything non-ASCII.
@(private)
word_start :: proc(s: []u8, i: int) -> int {
	j := i
	for j > 0 && !is_word_byte(s[j - 1]) {j -= 1}
	for j > 0 && is_word_byte(s[j - 1]) {j -= 1}
	return j
}

// word_end: where the word after i ends.
@(private)
word_end :: proc(s: []u8, i: int) -> int {
	j := i
	for j < len(s) && !is_word_byte(s[j]) {j += 1}
	for j < len(s) && is_word_byte(s[j]) {j += 1}
	return j
}

@(private)
is_word_byte :: proc(b: u8) -> bool {
	switch b {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', 0x80 ..= 0xff:
		return true
	}
	return false
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
