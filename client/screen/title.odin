package screen

import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "client:engine"
import "client:ui"
import "common:base"
import "common:game"

// SPLASHES: the splash texts (assets/splashes.txt, one per line; blank lines
// and # lines ignored).
SPLASHES :: #load("../../assets/splashes.txt", string)

SPLASH_REVEAL :: 1.2 // seconds for the transmission's glyphs to resolve into the text

// splash_reveal: the splash as it shows `seconds` after it arrived, a
// transmission from another world: every letter is first a glyph of the dial
// (picked by the letter) and the text resolves from the left over
// SPLASH_REVEAL seconds; newest is the last letter resolved (-1: none yet).
// With reduce_motion it is simply there.
splash_reveal :: proc(
	text: string,
	seconds: f32,
	reduce_motion: bool,
) -> (
	shown: string,
	newest: int,
) {
	n := utf8.rune_count_in_string(text)
	if reduce_motion || n == 0 || seconds >= SPLASH_REVEAL {return text, n - 1}
	resolved := int(f32(n) * max(seconds, 0) / SPLASH_REVEAL)
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for r in text {
		if i < resolved || r == ' ' {
			strings.write_rune(&b, r)
		} else {
			strings.write_rune(&b, game.SYMBOL_RUNES[int(r) % game.SYMBOLS])
		}
		i += 1
	}
	return strings.to_string(b), resolved - 1
}

// splashes_parse: the entries of a splashes file (slices of text).
splashes_parse :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") {continue}
		append(&out, l)
	}
	return out[:]
}

// splash_choose: the entry for the clock's second (a client-visual use of
// time: the world's rules never see it), kept by the screen for its lifetime.
splash_choose :: proc(entries: []string, second: i64) -> string {
	if len(entries) == 0 {return ""}
	return entries[int(second % i64(len(entries)))]
}

title_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "title")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	rows: f32 = 5 if app.devchat.running else 4
	column := ui.rect_center(ctx.screen, 400, rows * t.row_height + (rows - 1) * t.spacing + 120)
	logo := ui.cut_top(&column, 80)
	ui.title(ctx, engine.tr(.Title_Voxiverse), logo)
	if app.splash == "" {
		app.splash = splash_choose(splashes_parse(SPLASHES), time.now()._nsec / 1e9)
		app.splash_at = time.tick_now()
	}
	if app.splash != "" {
		// A transmission under the logo, level: dial glyphs resolving into the
		// text, a faint flicker while it arrives, then steady.
		seconds := f32(time.duration_seconds(time.tick_since(app.splash_at)))
		shown, _ := splash_reveal(app.splash, seconds, app.settings.reduce_motion)
		color := t.text_muted
		if seconds < SPLASH_REVEAL && !app.settings.reduce_motion {
			color.a = u8(f32(color.a) * (0.75 + 0.25 * math.sin(seconds * 40)))
		}
		ui.draw_text(
			ctx,
			{logo.x - 100, logo.y + logo.h + 4, logo.w + 200, t.font_size + 6},
			shown,
			t.font_size * 0.9,
			color,
			.Center,
		)
	}
	ui.cut_top(&column, 40)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.default_focus(ctx)
	if ui.button(ctx, engine.tr(.Title_Singleplayer), ui.next(ctx)) {
		universes_refresh(&app.universes)
		app.screen = .Universes
	}
	if ui.button(ctx, engine.tr(.Title_Multiplayer), ui.next(ctx)) {multiplayer_open(app)}
	if ui.button(ctx, engine.tr(.Options), ui.next(ctx)) {
		app.options.tab = .Video
		app.screen = .Options
	}
	if app.devchat.running &&
	   ui.button(ctx, engine.tr(.Devchat_Title), ui.next(ctx)) {engine.devchat_open(app)}
	if ui.button(
		ctx,
		engine.tr(.Title_Quit_Game),
		ui.next(ctx),
	) {engine.overlay_open(&app.overlays, .Quit_Dialog)}
	if app.message != "" {
		ui.label(ctx, app.message, ui.next(ctx), .Center, t.text_muted)
	}
	// The version, small and grey in the lower left (Minecraft's place for it).
	small := t.font_size * 0.75
	ui.draw_text(
		ctx,
		{ctx.screen.x + 8, ctx.screen.y + ctx.screen.h - small - 6, ctx.screen.w / 2, small},
		engine.tr(.Title_Version, base.version_text()),
		small,
		t.text_muted,
	)
}
