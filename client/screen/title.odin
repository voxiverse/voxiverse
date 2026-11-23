package screen

import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "client:engine"
import "client:ui"
import "client:update"
import "common:base"
import "common:starmap"

// SPLASHES: the splash texts (assets/splashes.txt, one per line; blank lines
// and # lines ignored).
SPLASHES :: #load("../../assets/splashes.txt", string)

SPLASH_REVEAL :: 0.75 // seconds for the address symbols to resolve into the text
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
// stamp from elsewhere: every letter is first a gate address symbol
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
			strings.write_rune(&b, starmap.symbol_rune(u8(int(r) % starmap.SYMBOLS)))
		}
		i += 1
	}
	return strings.to_string(b), resolved - 1
}

// splashes_parse: the entries of a splashes file (slices of text), skipping
// comment lines and section headers ([<holiday>] starts a holiday's texts).
splashes_parse :: proc(text: string, allocator := context.temp_allocator) -> []string {
	parsed := splashes_parse_file(text, nil, allocator)
	return parsed.all
}

// splash_choose: the entry for the clock's second (a client-visual use of
// time: the world's rules never see it), kept by the screen for its lifetime.
splash_choose :: proc(entries: []string, second: i64) -> string {
	if len(entries) == 0 {return ""}
	return entries[int(second % i64(len(entries)))]
}

// TITLE_COLUMN: the width of the title's buttons.
TITLE_COLUMN :: 400

// LOGO_GAP: the gap under the logo.
LOGO_GAP :: 40

// title_screen: the logo and splash, then at most five buttons: Continue (the save played
// last, by its game and its name, when it is there to open: continue_save), Singleplayer
// (the games, each with its saves), Multiplayer, Options and Quit Game. Nothing else: the
// developer chat is F9's. In the corners: the version, and an update (update_notice).
title_screen :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "title")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	holiday := today_holiday(app)
	if !app.settings.reduce_motion {
		holiday_back(app, ctx, holiday, app.last_frame_ms / 1000)
	}
	continue_game, continue_name, continuing := continue_save(app)
	rows: f32 = 5 if continuing else 4
	stack := rows * t.row_height + (rows - 1) * t.spacing + 80
	column := ui.rect_center(ctx.screen, TITLE_COLUMN, stack + LOGO_GAP)
	logo := ui.cut_top(&column, 80)
	title_text := engine.tr(.Title_Voxiverse)
	ui.title(ctx, title_text, logo)
	if app.splash == "" {
		parsed := splashes_parse_file(SPLASHES, app.games)
		y, m, d := 1970, 1, 1
		if o, ok := app.title_date_override.?;
		   ok {y, m, d = o[0], o[1], o[2]} else if ly, lm, ld, ok2 := engine.local_date_of(engine.app_wall(app)); ok2 {y, m, d = ly, lm, ld}
		app.splash = splash_for(parsed, y, m, d, engine.app_wall(app)._nsec / i64(1e9))
		app.splash_at = engine.app_tick(app)
	}
	if app.splash != "" {
		// The stamp: it crackles in off the logo's right corner (symbols
		// resolving as it falls), overshoots, rings down, then breathes —
		// size and angle together — never a held line of text.
		seconds := f32(time.duration_seconds(engine.app_since(app, app.splash_at)))
		reduce := app.settings.reduce_motion || app.scene.menu // (a scene's stamp stands still)
		shown, _ := splash_reveal(app.splash, seconds, reduce)
		size := t.font_size * 1.05
		angle: f32 = SPLASH_TILT
		color := t.text
		shadow_color := t.text_shadow
		#partial switch holiday {
		case .Halloween:
			shadow_color = engine.HALLOWEEN_SHADOW
		case:
		}
		if tint, ok := engine.holiday_tint(holiday); ok {color = tint}
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
			shadow_color,
			angle,
			t.font_size * 1.05 * 1.3,
		)
		ui.draw_text_tilted(ctx, centre, shown, size, color, angle, t.font_size * 1.05 * 1.3)
	}
	ui.cut_top(&column, LOGO_GAP)
	ui.begin_column(ctx, column)
	defer ui.end_column(ctx)
	ui.default_focus(ctx)
	if continuing {
		text := engine.tr(.Title_Continue, continue_game, continue_name)
		text = ui.text_elide(ctx, text, TITLE_COLUMN - 2 * t.padding, t.font_size)
		if ui.button(ctx, text, ui.next(ctx), id = "continue") {continue_play(app)}
	}
	if ui.button(ctx, engine.tr(.Title_Singleplayer), ui.next(ctx)) {singleplayer_open(app)}
	if ui.button(ctx, engine.tr(.Title_Multiplayer), ui.next(ctx)) {multiplayer_open(app)}
	if ui.button(ctx, engine.tr(.Options), ui.next(ctx)) {
		app.options.tab = .Video
		app.screen = .Options
	}
	if ui.button(
		ctx,
		engine.tr(.Title_Quit_Game),
		ui.next(ctx),
	) {engine.overlay_open(&app.overlays, .Quit_Dialog)}
	if app.message != "" {
		ui.label(ctx, app.message, ui.next(ctx), .Center, t.text_muted)
	}
	// The version, small and grey in the lower left (Minecraft's place for it).
	// (Not in a menu scene: a baseline image must not change with the build's
	// version string.)
	if !app.scene.menu {
		small := t.font_size * 0.75
		ui.draw_text(
			ctx,
			{ctx.screen.x + 8, ctx.screen.y + ctx.screen.h - small - 6, ctx.screen.w / 2, small},
			engine.tr(.Title_Version, base.version_text()),
			small,
			t.text_muted,
		)
	}
	when update.ENABLED {
		if !app.scene.menu {update_notice(app, ctx)}
	}
	if !app.settings.reduce_motion {
		holiday_front(app, ctx, holiday, app.last_frame_ms / 1000)
	}
}

// update_notice: the update, in the lower right corner, small as the version across
// from it: reaching the title starts the launch's one check (when the setting allows);
// then "Update available: 0.5.3" with Update, the download's progress, Restart to
// update once it is installed, or why it failed. Nothing while there is nothing to say.
update_notice :: proc(app: ^engine.App, ctx: ^ui.Context) {
	u := &app.updater
	if app.settings.updates {update.check(u)}
	s := update.status(u)
	text, action: string
	switch s.phase {
	case .Off, .Idle, .Checking, .Current:
		return
	case .Available:
		text, action = engine.tr(.Update_Available, s.version), engine.tr(.Update_Install)
	case .Downloading:
		text = engine.tr(.Update_Downloading, s.version, s.percent)
	case .Installing:
		text = engine.tr(.Update_Installing, s.version)
	case .Ready:
		text, action = engine.tr(.Update_Ready, s.version), engine.tr(.Update_Restart)
	case .Failed:
		switch s.failure {
		case .None, .Install:
			text = engine.tr(.Update_Failed_Install)
		case .Download:
			text = engine.tr(.Update_Failed_Download)
		case .Mismatch:
			text = engine.tr(.Update_Failed_Mismatch)
		case .Not_Writable:
			text = engine.tr(.Update_Failed_Not_Writable)
		case .Not_Package:
			text = engine.tr(.Update_Failed_Not_Package)
		}
	}
	t := &ctx.theme
	small := t.font_size * 0.75
	// Alone, the line sits on the version's; beside its button, centred on it.
	line := ui.Rect{ctx.screen.x, ctx.screen.y + ctx.screen.h - small - 6, ctx.screen.w - 8, small}
	if action != "" {
		height := math.round(t.row_height * 0.8)
		row := ui.Rect {
			ctx.screen.x,
			ctx.screen.y + ctx.screen.h - height - 4,
			ctx.screen.w - 8,
			height,
		}
		width := ui.measure_text(ctx, action, t.font_size) + 2 * t.padding
		if ui.button(ctx, action, ui.cut_right(&row, width), id = "update") {
			if s.phase == .Available {
				update.install(u)
			} else {
				app.restart, app.quit = true, true
			}
		}
		ui.cut_right(&row, t.spacing)
		line = ui.rect_center(row, row.w, small)
	}
	ui.draw_text(ctx, line, text, small, t.text, .Right)
}
