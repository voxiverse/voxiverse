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

SPLASH_REVEAL :: 0.75 // seconds for the dial glyphs to resolve into the text
SPLASH_TILT :: -0.18 // resting angle of the stamp, radians: it rises to the right
SPLASH_WOBBLE :: 0.015 // how far the angle breathes around SPLASH_TILT
SPLASH_PULSE :: 0.025 // how much its size swells and shrinks
SPLASH_TEMPO :: 2.5 // radians per second of the pulse and the wobble
SPLASH_SPRING :: 5.6 // damping of the entrance pop
SPLASH_SPRING_FREQ :: 9.0 // springiness of the entrance pop

// splash_pop: the entrance, a stamp from above: nothing at 0 s, overshooting
// to about 1.27, ringing down to 1 (a damped spring, closed form).
splash_pop :: proc(seconds: f32) -> f32 {
	if seconds <= 0 {return 0}
	return 1 - math.exp(-SPLASH_SPRING * seconds) * math.cos(SPLASH_SPRING_FREQ * seconds)
}

// splash_pulse: the idle breathing, 1 +/- SPLASH_PULSE.
splash_pulse :: proc(seconds: f32) -> f32 {
	return 1 + SPLASH_PULSE * math.sin(max(seconds, 0) * SPLASH_TEMPO)
}

// splash_angle: the resting tilt breathing against the pulse (phase-shifted,
// so the splash never holds still).
splash_angle :: proc(seconds: f32) -> f32 {
	return SPLASH_TILT + SPLASH_WOBBLE * math.sin(max(seconds, 0) * SPLASH_TEMPO - 1.1)
}

// splash_reveal: the splash as it shows `seconds` after it arrived, a
// stamp from elsewhere: every letter is first a glyph of the dial
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
	title_text := engine.tr(.Title_Voxiverse)
	ui.title(ctx, title_text, logo)
	if app.splash == "" {
		app.splash = splash_choose(splashes_parse(SPLASHES), time.now()._nsec / 1e9)
		app.splash_at = time.tick_now()
	}
	if app.splash != "" {
		// The stamp: it crackles in off the logo's right corner (dial glyphs
		// resolving as it falls), overshoots, rings down, then breathes —
		// size and angle together — never a held line of text.
		seconds := f32(time.duration_seconds(time.tick_since(app.splash_at)))
		reduce := app.settings.reduce_motion
		shown, _ := splash_reveal(app.splash, seconds, reduce)
		size := t.font_size * 1.05
		angle: f32 = SPLASH_TILT
		color := t.text
		if !reduce {
			size *= splash_pop(seconds) * splash_pulse(seconds)
			angle = splash_angle(seconds)
			if seconds < SPLASH_REVEAL {
				color.a = u8(f32(color.a) * (0.7 + 0.3 * math.sin(seconds * 12)))
			}
		}
		width := ui.measure_text(ctx, shown, size)
		max_splash_w: f32 = 240
		if width > max_splash_w {
			size *= max_splash_w / width
			width = max_splash_w
		}
		title_w := ui.measure_text(ctx, title_text, t.title_size)
		title_right := logo.x + (logo.w + title_w) / 2
		title_bottom := logo.y + (logo.h + t.title_size) / 2
		centre := ui.Vec2{title_right + 15, title_bottom + 10}
		// Never run off the screen right edge; keep within screen padding.
		if centre.x + width / 2 > ctx.screen.x + ctx.screen.w - 12 {
			centre.x = ctx.screen.x + ctx.screen.w - width / 2 - 12
		}
		if centre.x - width / 2 < ctx.screen.x + 12 {
			centre.x = ctx.screen.x + width / 2 + 12
		}
		ui.draw_text_tilted(
			ctx,
			{centre.x + 2, centre.y + 2},
			shown,
			size,
			t.text_shadow,
			angle,
			t.font_size * 1.05 * 1.3,
		)
		ui.draw_text_tilted(ctx, centre, shown, size, color, angle, t.font_size * 1.05 * 1.3)
	}
	ui.cut_top(&column, 40)
	ui.begin_column(ctx, column)
	defer ui.end_column(ctx)
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
