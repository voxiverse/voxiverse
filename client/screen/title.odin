package screen

import "core:math"
import "core:strings"
import "core:time"

import "client:engine"
import "client:ui"
import "common:base"

// SPLASHES: the splash texts (assets/splashes.txt, one per line; blank lines
// and # lines ignored).
SPLASHES :: #load("../../assets/splashes.txt", string)

SPLASH_TILT :: -0.105 // radians: a few degrees, rising to the right
SPLASH_PULSE :: 0.05 // how much its size swells and shrinks

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
	}
	if app.splash != "" {
		size := t.font_size
		if !app.settings.reduce_motion {
			size *=
				1 +
				SPLASH_PULSE *
					math.sin(f32(time.duration_seconds(time.tick_since(app.started))) * 3)
		}
		ui.draw_text_tilted(
			ctx,
			{logo.x + logo.w / 2 + 120, logo.y + logo.h - 4},
			app.splash,
			size,
			t.text,
			SPLASH_TILT,
			t.font_size * (1 + SPLASH_PULSE),
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
