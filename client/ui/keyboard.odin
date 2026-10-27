package ui

import "core:unicode/utf8"

// The on-screen keyboard: for text fields when there is only a pad. It draws
// on Layer.Keyboard, over everything (below it all is inert), types into the
// text field that opened it (text_input), and is navigated like any menu: its
// keys are widgets, so directions move between them.
//
// Pad: Confirm types the focused key, X (Secondary) is Backspace, Y
// (Tertiary) a space, the bumpers move the text cursor (Input.osk_cursor),
// the stick press is Shift (Input.osk_shift), Start (Nav.Start) is Done, B
// closes it with the text kept (osk_cancel). A real keyboard types as usual.

Osk :: struct {
	open:     bool,
	target:   Id, // the text field it types into
	symbols:  bool, // the symbols page
	shift:    bool, // capitals
	last:     int, // the key (cell number) focused last: where it opens
	has_last: bool,
}

OSK_KEY :: 44 // key size, UI units
OSK_COLS :: 10
OSK_FIRST_KEY :: 25 // 'h': cell 2 * 10 + 5
// The bottom row's cells: ids by place, so a key keeps focus when the page or
// Shift changes its label.
@(private = "file")
CELL_SHIFT :: 40
@(private = "file")
CELL_PAGE :: 41
@(private = "file")
CELL_SPACE :: 42
@(private = "file")
CELL_BACKSPACE :: 43
@(private = "file")
CELL_DONE :: 44

@(private = "file")
LETTER_ROWS := [4]string{"1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm_.:"}
@(private = "file")
SYMBOL_ROWS := [4]string{"!@#$%^&*()", "-_=+[]{};'", "/\\|~<>?,\"#", "`"}

// osk_open opens the keyboard on the text field id, with the key used last
// focused ('h' the first time).
osk_open :: proc(ctx: ^Context, id: Id) {
	last := ctx.osk.last if ctx.osk.has_last else OSK_FIRST_KEY
	ctx.osk = {
		open     = true,
		target   = id,
		last     = last,
		has_last = true,
	}
	ctx.focus_by_layer[.Keyboard] = 0
}

osk_is_open :: proc(ctx: ^Context) -> bool {return ctx.osk.open}

// osk_cancel closes the keyboard (true if it was open): the text is kept.
osk_cancel :: proc(ctx: ^Context) -> bool {
	was := ctx.osk.open
	ctx.osk.open = false
	return was
}

// osk_height: how tall the keyboard's panel is.
osk_height :: proc(ctx: ^Context) -> f32 {
	t := &ctx.theme
	return 5 * OSK_KEY + 4 * t.spacing + t.row_height + 3 * t.padding
}

// osk_draw draws the keyboard and applies its keys to text with edit's
// cursor. Returns true when Done is pressed (the field is submitted).
@(private)
osk_draw :: proc(ctx: ^Context, e: ^Text_Edit, text: ^[dynamic]u8, field: Rect) -> (done: bool) {
	t := &ctx.theme
	prev := begin_layer(ctx, .Keyboard)
	defer end_layer(ctx, prev)
	push_clip_rect(ctx, ctx.screen)
	defer pop_clip_rect(ctx)
	push_id(ctx, "osk")
	defer pop_id(ctx)

	o := &ctx.osk
	if !o.open {return}
	in_ := &ctx.input
	if in_.osk_shift {o.shift = !o.shift}
	if in_.osk_cursor < 0 {
		for _ in 0 ..< -in_.osk_cursor {e.cursor = prev_rune_start(text[:], e.cursor)}
		e.anchor = e.cursor
	} else if in_.osk_cursor > 0 {
		for _ in 0 ..< in_.osk_cursor {e.cursor = next_rune_start(text[:], e.cursor)}
		e.anchor = e.cursor
	}
	if .Secondary in in_.nav {osk_backspace(e, text)}
	if .Tertiary in in_.nav {osk_type(e, text, ' ')}
	if .Start in in_.nav {done = true}

	// The panel along the bottom of the screen, above the prompt bar.
	w := OSK_COLS * OSK_KEY + (OSK_COLS - 1) * t.spacing + 2 * t.padding
	h := osk_height(ctx)
	panel_r := Rect{(ctx.screen.w - w) / 2, ctx.screen.h - h - OSK_BAR, w, h}
	panel(ctx, panel_r)
	inner := rect_shrink(panel_r, t.padding)
	line := cut_top(&inner, t.row_height)
	cut_top(&inner, t.padding)
	stroke_rect(ctx, line, 1, t.text_muted)
	line_in := rect_shrink(line, t.padding)
	push_clip_rect(ctx, line_in)
	content := string(text[:])
	cx := measure_text(ctx, content[:min(e.cursor, len(content))], t.font_size)
	shift := max(cx - line_in.w + 2, 0)
	draw_text(
		ctx,
		{line_in.x - shift, line_in.y, line_in.w + shift, line_in.h},
		content,
		t.font_size,
		t.text,
	)
	fill_rect(ctx, {line_in.x + cx - shift, line_in.y + 2, 1.5, line_in.h - 4}, t.text)
	pop_clip_rect(ctx)

	rows := LETTER_ROWS if !o.symbols else SYMBOL_ROWS
	for row in 0 ..< 4 {
		keys := rows[row]
		for col in 0 ..< len(keys) {
			ch := rune(keys[col])
			if !o.symbols && o.shift && ch >= 'a' && ch <= 'z' {ch -= 32}
			r := osk_cell(inner, t.spacing, col, row, 1)
			label := utf8.runes_to_string([]rune{ch}, ctx.frame_alloc)
			if osk_key(ctx, row * OSK_COLS + col, label, r) {osk_type(e, text, ch)}
		}
	}
	bottom := [?]struct {
		cell:  int,
		span:  int,
		label: string,
	} {
		{CELL_SHIFT, 1, "Shift"},
		{CELL_PAGE, 1, "abc" if o.symbols else "&123"},
		{CELL_SPACE, 4, "Space"},
		{CELL_BACKSPACE, 2, "Backspace"},
		{CELL_DONE, 2, "Done"},
	}
	col := 0
	for b in bottom {
		r := osk_cell(inner, t.spacing, col, 4, b.span)
		col += b.span
		if !osk_key(ctx, b.cell, b.label, r) {continue}
		switch b.cell {
		case CELL_SHIFT:
			o.shift = !o.shift
		case CELL_PAGE:
			o.symbols = !o.symbols
		case CELL_SPACE:
			osk_type(e, text, ' ')
		case CELL_BACKSPACE:
			osk_backspace(e, text)
		case CELL_DONE:
			done = true
		}
	}
	// Where it opens next time.
	for w in ctx.widgets {
		if w.layer == .Keyboard && w.id == ctx.focused {
			for cell in 0 ..= CELL_DONE {
				if get_id_int(ctx, cell) == w.id {o.last = cell}
			}
		}
	}
	if done {o.open = false}
	return
}

OSK_BAR :: 24 // room kept under the keyboard for the prompt bar

@(private = "file")
osk_cell :: proc(inner: Rect, spacing: f32, col, row, span: int) -> Rect {
	return {
		inner.x + f32(col) * (OSK_KEY + spacing),
		inner.y + f32(row) * (OSK_KEY + spacing),
		f32(span) * OSK_KEY + f32(span - 1) * spacing,
		OSK_KEY,
	}
}

// osk_key: one key, its id by place (cell) so it keeps focus when its label
// changes.
@(private = "file")
osk_key :: proc(ctx: ^Context, cell: int, label: string, r: Rect) -> bool {
	t := &ctx.theme
	if cell == ctx.osk.last {default_focus(ctx)}
	it := interact(ctx, get_id_int(ctx, cell), r, label = label)
	fill, ink := t.background, t.text
	if it.pressed {
		fill, ink = t.pressed, t.hover_text
	} else if it.hovered || (it.focused && ctx.focus_visible) {
		fill, ink = t.hover, t.hover_text
	}
	shifted := cell == CELL_SHIFT && ctx.osk.shift || cell == CELL_PAGE && ctx.osk.symbols
	if shifted && fill == t.background {fill = with_alpha(t.hover, 70)}
	fill_rect(ctx, r, fill)
	stroke_rect(ctx, r, t.border_width, t.border)
	// A long name (Shift, &123) on a narrow key is set smaller to fit.
	size := t.font_size
	if w := measure_text(ctx, label, size); w > r.w - 6 {size *= (r.w - 6) / w}
	draw_text(ctx, r, label, size, ink, .Center)
	focus_ring(ctx, r, it)
	return it.clicked
}

@(private = "file")
osk_type :: proc(e: ^Text_Edit, text: ^[dynamic]u8, r: rune) {
	if e.cursor != e.anchor {
		a, b := min(e.cursor, e.anchor), max(e.cursor, e.anchor)
		remove_range(text, a, b)
		e.cursor = a
	}
	bytes, n := utf8.encode_rune(r)
	inject_at(text, e.cursor, ..bytes[:n])
	e.cursor += n
	e.anchor = e.cursor
}

@(private = "file")
osk_backspace :: proc(e: ^Text_Edit, text: ^[dynamic]u8) {
	if e.cursor != e.anchor {
		a, b := min(e.cursor, e.anchor), max(e.cursor, e.anchor)
		remove_range(text, a, b)
		e.cursor, e.anchor = a, a
	} else if e.cursor > 0 {
		start := prev_rune_start(text[:], e.cursor)
		remove_range(text, start, e.cursor)
		e.cursor, e.anchor = start, start
	}
}
