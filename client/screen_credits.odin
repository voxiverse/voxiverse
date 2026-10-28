package client

import "core:strings"

import "ui"

// The credits screen (from Options, beside Done): the sound
// sources' and the music's credit lines (assets/music/CREDITS.txt, which the
// release packages copy to licenses/), then the fonts' licence names, scrolled
// by the wheel.

CREDITS_FILE :: #load("../assets/music/CREDITS.txt", string)
CREDITS_FONTS :: "\nFonts\n\nJetBrains Mono, OFL\nNoto Sans Old Turkic, OFL\n"
CREDITS_WIDTH :: 760

Credits_View :: struct {
	first:    int, // the first row shown
	selected: int,
}

// credits_lines: the screen's text, a row each.
credits_lines :: proc(allocator := context.temp_allocator) -> []string {
	text := strings.concatenate({CREDITS_FILE, CREDITS_FONTS}, allocator)
	lines, _ := strings.split_lines(strings.trim_right(text, "\r\n"), allocator)
	for &l in lines {l = strings.trim_right(l, "\r")}
	return lines
}

credits_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "credits")
	defer ui.pop_id(ctx)
	v := &app.credits
	t := &ctx.theme
	area := ui.rect_center(ctx.screen, CREDITS_WIDTH, ctx.screen.h - 60)
	ui.title(ctx, tr(.Credits_Credits), ui.cut_top(&area, 70))
	buttons := ui.cut_bottom(&area, t.row_height)
	ui.cut_bottom(&area, 2 * t.spacing)
	ui.fill_rect(ctx, area, t.list_fill)
	ui.stroke_rect(ctx, area, 1, t.list_border)
	lines := credits_lines()
	row_h := t.row_height * 0.7
	visible := int(area.h / row_h)
	ui.list_nav(ctx, "text", area, len(lines), &v.selected, &v.first, visible, row_h)
	ui.push_clip_rect(ctx, area)
	for i in v.first ..< min(len(lines), v.first + visible + 1) {
		row := ui.Rect{area.x + 12, area.y + f32(i - v.first) * row_h, area.w - 24, row_h}
		ui.label(ctx, lines[i], row, .Left, t.text)
	}
	ui.pop_clip_rect(ctx)
	ui.layout_begin(ctx, buttons)
	defer ui.layout_end(ctx)
	if ui.button(ctx, tr(.Credits_Back), ui.next(ctx)) {credits_back(app)}
}

credits_back :: proc(app: ^App) {
	app.screen = .Options
}
