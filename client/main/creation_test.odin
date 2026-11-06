package main

import "core:math"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:mesh"
import "client:planet"
import "client:screen"
import "client:starfield"
import "client:ui"
import "common:game"
import "common:worldgen"

// The creation screen and Ignite (screen_creation.odin, screen_ignite.odin).
// (A universe made with a typed seed has that seed's glyph address:
// server/core/gamemode_test.odin.)

@(private = "file")
creation_app :: proc(t: ^testing.T) -> ^engine.App {
	app := ui_app(t)
	app.screen = .Universes
	screen.creation_open(app)
	return app
}

@(private = "file")
creation_free :: proc(app: ^engine.App) {
	screen.creation_destroy(&app.creation)
	delete(app.cues)
	ui_app_free(app)
}

@(test)
test_roll_keeps_name_and_mode :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	c := &app.creation
	testing.expect_value(t, c.mode, "creative") // the default
	clear(&c.name)
	append(&c.name, "Mine")
	c.mode = "survival"
	before := c.seed
	stars_before := c.stars[1]
	screen.creation_roll(c, 12345)
	testing.expect(t, c.seed != before, "a new seed")
	testing.expect(t, c.stars[1] != stars_before, "the galaxy redrawn")
	testing.expect_value(t, string(c.name[:]), "Mine")
	testing.expect_value(t, c.mode, "survival")
	testing.expect_value(t, c.settle, 0) // the stars re-settle ...
	free_all(context.temp_allocator)
	// ... over 0.4 s (and at once with Reduce motion).
	app.last_frame_ms = 100
	ui_frame(app)
	ui_frame(app)
	testing.expect(t, abs(c.settle - 0.5) < 1e-4, "half way after 0.2 s")
	ui_frame(app)
	ui_frame(app)
	testing.expect_value(t, c.settle, 1)
	screen.creation_roll(c, 777)
	app.settings.reduce_motion = true
	ui_frame(app)
	testing.expect_value(t, c.settle, 1)
}

@(test)
test_typed_seed_shows_its_glyphs :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	c := &app.creation
	// A number is the seed itself.
	append(&c.seed_text, "42")
	screen.creation_sync_seed(c, 1)
	testing.expect_value(t, c.seed, 42)
	testing.expect_value(t, game.seed_glyphs(c.seed), game.address_derive(42))
	// Text is hashed, and its glyphs are on the screen as they are typed.
	clear(&c.seed_text)
	append(&c.seed_text, "andromeda")
	screen.creation_sync_seed(c, 1)
	hashed, _ := game.seed_of_text("andromeda")
	testing.expect_value(t, c.seed, hashed)
	ui_frame(app)
	glyphs := game.address_text(game.seed_glyphs(hashed))
	found := false
	for text in app.ui.texts {if text == glyphs {found = true}}
	testing.expect(t, found, "the glyphs of the typed seed are shown")
	// Emptied: a fresh roll.
	clear(&c.seed_text)
	screen.creation_sync_seed(c, 99)
	testing.expect(t, c.seed != hashed && !c.typed)
	free_all(context.temp_allocator)
}

@(private = "file")
creation_frame :: proc(app: ^engine.App, input: ui.Input = {}) {
	ui.begin_frame(&app.ui, input, SCREEN, 1)
	screen.creation_screen(app, &app.ui)
	ui.end_frame(&app.ui)
}

@(private = "file")
inside :: proc(inner, outer: ui.Rect) -> bool {
	return(
		inner.w > 0 &&
		inner.h > 0 &&
		inner.x >= outer.x &&
		inner.y >= outer.y &&
		inner.x + inner.w <= outer.x + outer.w + 1e-3 &&
		inner.y + inner.h <= outer.y + outer.h + 1e-3 \
	)
}

@(private = "file")
apart :: proc(a, b: ui.Rect) -> bool {
	return(
		a.x + a.w <= b.x + 1e-3 ||
		b.x + b.w <= a.x + 1e-3 ||
		a.y + a.h <= b.y + 1e-3 ||
		b.y + b.h <= a.y + 1e-3 \
	)
}

// The compact screen fits every supported window, at the automatic scale
// (1.0 at 720 px, in quarter steps with the height), with nothing to scroll.
@(test)
test_creation_layout_fits :: proc(t: ^testing.T) {
	sizes := make([dynamic][2]f32, context.temp_allocator)
	for w := f32(1280); w <= 3840; w += 160 {append(&sizes, [2]f32{w, w * 9 / 16})}
	append(&sizes, [2]f32{1280, 800}, [2]f32{1366, 768})
	th := ui.DEFAULT_THEME
	for size in sizes {
		scale := clamp(math.round(size.y / 720 * 4) / 4, 1, 3)
		r := ui.Rect{0, 0, size.x / scale, size.y / scale}
		l := screen.creation_layout(r, th)
		testing.expectf(t, l.fits, "%v: does not fit", size)
		controls := [8]ui.Rect {
			l.galaxy,
			l.planet,
			l.name,
			l.seed,
			l.glyphs,
			l.roll,
			l.mode,
			l.ignite,
		}
		for c, i in controls {
			testing.expectf(
				t,
				inside(c, r) && inside(c, l.panel),
				"%v: control %d outside",
				size,
				i,
			)
			for d in controls[i + 1:] {
				testing.expectf(t, apart(c, d), "%v: control %d overlaps", size, i)
			}
		}
		top := l.galaxy.y + l.galaxy.h
		testing.expect(t, l.name.y >= top && l.name.y < l.seed.y, "name below the band")
		testing.expect(t, l.seed.y < l.mode.y && l.mode.y < l.ignite.y, "rows in order")
		testing.expect(t, l.galaxy.x < l.planet.x && l.galaxy.h == l.planet.h, "galaxy, planet")
		testing.expect(t, l.roll.y == l.seed.y && l.glyphs.y == l.seed.y, "one seed row")
		testing.expect(t, abs(l.panel.x + l.panel.w / 2 - r.w / 2) < 1, "centred")
		testing.expect(t, abs(l.panel.y + l.panel.h / 2 - r.h / 2) < 1, "centred")
	}
	// Too short a screen says so.
	testing.expect(t, !screen.creation_layout({0, 0, 1280, 300}, th).fits)
}

// One click on the toggle flips the mode and back; Left and Right do the same
// while it is focused; the mode reaches the plan.
@(test)
test_creation_mode_toggle :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	c := &app.creation
	l := screen.creation_layout({0, 0, SCREEN.x, SCREEN.y}, app.ui.theme)
	at := ui.Vec2{l.mode.x + l.mode.w / 2, l.mode.y + l.mode.h / 2}
	click :: proc(app: ^engine.App, at: ui.Vec2) {
		creation_frame(app, {mouse = at})
		creation_frame(app, {mouse = at, mouse_down = {.Left}, mouse_pressed = {.Left}})
		creation_frame(app, {mouse = at, mouse_released = {.Left}})
	}
	testing.expect_value(t, c.mode, "creative")
	click(app, at)
	testing.expect_value(t, c.mode, "survival")
	click(app, at)
	testing.expect_value(t, c.mode, "creative")
	click(app, at) // (focused now)
	creation_frame(app, {mouse = at, nav = {.Left}})
	testing.expect_value(t, c.mode, "creative")
	creation_frame(app, {mouse = at, nav = {.Right}})
	testing.expect_value(t, c.mode, "survival")
	plan := screen.universe_plan("Mode", 1, c.mode)
	testing.expect_value(t, plan.mode, "survival")
	free_all(context.temp_allocator)
}

// The plan Ignite carries out: one directory, a free variant of the name,
// with the seed and mode chosen.
@(test)
test_universe_plan :: proc(t: ^testing.T) {
	dir := "build/test/plan"
	os.remove_all(dir)
	defer os.remove_all(dir)
	screen.saves_override = dir
	defer screen.saves_override = ""
	plan := screen.universe_plan("My World", 42, "survival")
	testing.expect_value(t, plan.seed, 42)
	testing.expect_value(t, plan.mode, "survival")
	testing.expect(t, strings.has_suffix(plan.path, "My World"))
	os.make_directory_all(plan.path)
	again := screen.universe_plan("My World", 43, "creative")
	testing.expect(t, strings.has_suffix(again.path, "My World (2)"), "a free variant")
	testing.expect(
		t,
		strings.has_suffix(screen.universe_plan("///", 1, "creative").path, "New Universe") ||
		strings.contains(screen.universe_plan("///", 1, "creative").path, "___"),
	)
	free_all(context.temp_allocator)
}

@(private = "file")
ignite_frame :: proc(app: ^engine.App, input: ui.Input = {}) {
	ui.begin_frame(&app.ui, input, SCREEN, 1)
	screen.ignite_ui(app, &app.ui)
	ui.end_frame(&app.ui)
}

// Ignite plays 2.5 s on a stepped clock (and the cue is fired once), any key
// skips it, and with Reduce motion it is a 0.3 s cross-fade.
@(test)
test_ignite_plays_and_skips :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	app.last_frame_ms = 1000.0 / 60
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	testing.expect_value(t, len(app.cues), 1)
	testing.expect_value(t, app.cues[0], "ui_ignite")
	frames := 0
	for app.ignite.active && frames < 1000 {
		ignite_frame(app)
		frames += 1
	}
	testing.expect(t, abs(f32(frames) / 60 - screen.IGNITE_SECONDS) < 0.05, "2.5 s of frames")
	testing.expect_value(t, len(app.cues), 1) // (not fired again)

	// A key press skips it (the first frame's input is the click that began it).
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	ignite_frame(app, {keys_pressed = {.Enter}})
	testing.expect(t, app.ignite.active, "the key that started it does not skip it")
	ignite_frame(app)
	ignite_frame(app, {keys_pressed = {.Space}})
	testing.expect(t, !app.ignite.active, "a key skips it")
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	ignite_frame(app)
	ignite_frame(app, {mouse_pressed = {.Left}})
	testing.expect(t, !app.ignite.active, "a click skips it")

	// Reduce motion: no collapse, flash or zoom, a cross-fade of 0.3 s.
	app.settings.reduce_motion = true
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	ignite_frame(app)
	quads_reduced := len(app.ui.output.vertices)
	frames = 1
	for app.ignite.active && frames < 1000 {
		ignite_frame(app)
		frames += 1
	}
	testing.expect(t, abs(f32(frames) / 60 - screen.IGNITE_FADE) < 0.05, "a 0.3 s cross-fade")
	app.settings.reduce_motion = false
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	for _ in 0 ..< 100 {ignite_frame(app)} 	// well into the zoom
	testing.expect(
		t,
		quads_reduced < len(app.ui.output.vertices) / 10,
		"no zoom with Reduce motion",
	)
	free_all(context.temp_allocator)
}

// ignite_phase gives the five phases in order, each starting where the last
// ends, x from 0 to 1 within each, Done from IGNITE_SECONDS.
@(test)
test_ignite_phases :: proc(t: ^testing.T) {
	sum: f32
	for d in screen.IGNITE_PHASES {sum += d}
	testing.expect(t, abs(sum - screen.IGNITE_SECONDS) < 0.05, "the table sums to 2.5 s")
	last := screen.Ignite_Phase.Wind
	last_x: f32
	for ms in 0 ..< 2500 {
		phase, x := screen.ignite_phase(f32(ms) / 1000)
		testing.expect(t, phase >= last && int(phase) <= int(last) + 1, "phases in order")
		if phase == last {
			testing.expect(t, x >= last_x && x <= 1, "x rises within a phase")
		} else {
			testing.expect(t, x < 0.05, "x starts at 0 in the next phase")
		}
		last, last_x = phase, x
	}
	testing.expect_value(t, last, screen.Ignite_Phase.Fade)
	first, fx := screen.ignite_phase(0)
	testing.expect_value(t, first, screen.Ignite_Phase.Wind)
	testing.expect_value(t, fx, 0)
	done, _ := screen.ignite_phase(screen.IGNITE_SECONDS)
	testing.expect_value(t, done, screen.Ignite_Phase.Done)
}

// The plan: the galaxy winds to the centre, the ring grows, the streaks
// are fast only in their phase, the planet grows from a dot to the screen,
// the fade goes 0 to 1, and no frame draws more quads than the budget.
@(test)
test_ignite_plan :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	i := &app.ignite
	rect := ui.Rect{0, 0, SCREEN.x, SCREEN.y}
	centre := ui.Vec2{rect.w / 2, rect.h / 2}
	at :: proc(i: ^engine.Ignite, rect: ui.Rect, t: f32) -> ^screen.Ignite_Frame {
		i.t = t
		f := new(screen.Ignite_Frame, context.temp_allocator)
		f^ = screen.ignite_plan(i, rect)
		return f
	}
	// The end of Wind: every star is at the centre.
	end := at(i, rect, screen.IGNITE_PHASES[0] - 0.0001)
	testing.expect_value(t, end.phase, screen.Ignite_Phase.Wind)
	for k in 0 ..< end.star_count {
		d := end.stars[k] - centre
		testing.expect(t, abs(d.x) < 1e-1 && abs(d.y) < 1e-1, "a star reaches the centre")
	}
	// Wind turns the stars: a star away from the middle has moved sideways.
	start := at(i, rect, 0)
	mid := at(i, rect, screen.IGNITE_PHASES[0] / 2)
	turned := 0
	for k in 0 ..< mid.star_count {
		a := start.stars[k] - centre
		b := mid.stars[k] - centre
		if abs(a.x * b.y - a.y * b.x) > 1 {turned += 1}
	}
	testing.expect(t, turned > mid.star_count / 2, "wind turns the stars about the centre")
	// The ring grows strictly through Flash and Streaks; the streaks alone are fast.
	ring: f32 = -1 // (the first Flash frame may have the ring at 0)
	planet_first, planet_last, fade_first, fade_last: f32 = -1, 0, -1, 0
	for ms in 1 ..< 2500 {
		f := at(i, rect, f32(ms) / 1000)
		if f.phase == .Flash || f.phase == .Streaks {
			testing.expect(t, f.ring_radius > ring, "the ring grows")
			ring = f.ring_radius
		} else {
			testing.expect_value(t, f.ring_radius, 0)
		}
		testing.expect_value(t, f.streak_speed > 1, f.phase == .Streaks)
		if f.phase == .Dive && planet_first < 0 {planet_first = f.planet}
		if f.phase == .Fade && fade_first < 0 {fade_first = f.fade_alpha}
		planet_last, fade_last = f.planet, f.fade_alpha
	}
	testing.expect(t, planet_first < 8, "the planet starts as a dot")
	testing.expect(t, planet_last >= math.sqrt(rect.w * rect.w + rect.h * rect.h) / 2, "and fills")
	testing.expect(t, fade_first < 0.05 && fade_last > 0.95, "the fade goes 0 to 1")
	// The budget: no frame's draw list is above IGNITE_MAX_QUADS quads.
	app.last_frame_ms = 1000.0 / 60
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	most := 0
	for _ in 0 ..< 200 {
		ignite_frame(app)
		most = max(most, len(app.ui.output.vertices))
		if !app.ignite.active {break}
	}
	testing.expectf(t, most <= screen.IGNITE_MAX_QUADS * 4, "a frame has %d vertices", most)
	free_all(context.temp_allocator)
}

// Reduce motion: the duration is the fade; the plan has nothing but the fade
// and the draw list holds one rect.
@(test)
test_ignite_reduce_motion :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	app.settings.reduce_motion = true
	app.last_frame_ms = 1000.0 / 60
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	testing.expect_value(t, screen.ignite_duration(true), screen.IGNITE_FADE)
	for _ in 0 ..< 10 {
		f := new(screen.Ignite_Frame, context.temp_allocator)
		f^ = screen.ignite_plan(&app.ignite, {0, 0, SCREEN.x, SCREEN.y})
		testing.expect(
			t,
			f.star_count == 0 && f.ring_radius == 0 && f.planet == 0 && f.streak_speed == 1,
			"nothing but the fade",
		)
		ignite_frame(app)
		if !app.ignite.active {break}
		testing.expect_value(t, len(app.ui.output.vertices), 4)
	}
	free_all(context.temp_allocator)
}

// The planet Ignite draws takes its colours from the home world's kind:
// its water, its palette's ground and dry ground, and snow; whatever the seed.
@(test)
test_planet_colours_are_the_kinds :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	surface := worldgen.PALETTES[int(worldgen.PARAMS_DEFAULTS.palette)]
	want := planet.Planet_Palette {
		water  = ui.Color(mesh.block_average_colour(app.registry, .Water, .Pos_Y)),
		ground = ui.Color(mesh.block_average_colour(app.registry, surface[0], .Pos_Y)),
		dry    = ui.Color(mesh.block_average_colour(app.registry, surface[2], .Pos_Y)),
		ice    = ui.Color(mesh.block_average_colour(app.registry, .Snow, .Pos_Y)),
	}
	for seed in ([]u64{42, 0xdead_beef}) {
		screen.creation_roll(&app.creation, seed)
		testing.expect_value(t, app.creation.planet, want)
		screen.ignite_start(app, app.creation.stars, seed)
		testing.expect_value(t, app.ignite.planet, want)
	}
	// Another kind of world has another palette (frost: snow, dirt, ice).
	p := worldgen.PARAMS_DEFAULTS
	p.palette = 2
	frost := planet.planet_palette(app.registry, p)
	testing.expect(t, frost.ground != want.ground, "frost's ground is not Earth's")
	testing.expect_value(
		t,
		frost.dry,
		ui.Color(mesh.block_average_colour(app.registry, .Ice, .Pos_Y)),
	)
	free_all(context.temp_allocator)
}

@(test)
test_star_colours_come_from_the_stars :: proc(t: ^testing.T) {
	seen: [game.STAR_COLORS][4]u8
	for c in 0 ..< game.STAR_COLORS {
		seen[c] = game.star_color({color = u8(c)})
		testing.expect_value(t, seen[c].a, 255)
		for o in 0 ..< c {testing.expect(t, seen[o] != seen[c], "each class has its own colour")}
	}
}

// One frame of the screen at 1280 x 720 has no scroll area: every clip a
// widget pushes lies inside the panel (or is the whole screen), so nothing
// of the panel is clipped away, and no vertex leaves the screen.
@(test)
test_creation_draws_no_scroll :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	creation_frame(app)
	l := screen.creation_layout({0, 0, SCREEN.x, SCREEN.y}, app.ui.theme)
	testing.expect(t, l.fits)
	testing.expect(t, len(app.ui.output.commands) > 0, "it draws")
	for c in app.ui.output.commands {
		whole :=
			c.scissor[0] <= 0 &&
			c.scissor[1] <= 0 &&
			c.scissor[2] >= i32(SCREEN.x) &&
			c.scissor[3] >= i32(SCREEN.y)
		clip := ui.Rect{f32(c.scissor[0]), f32(c.scissor[1]), f32(c.scissor[2]), f32(c.scissor[3])}
		testing.expectf(t, whole || inside(clip, l.panel), "a clip %v beyond the panel", c.scissor)
	}
	for v in app.ui.output.vertices {
		testing.expect(
			t,
			v.pos.x >= -1 && v.pos.y >= -1 && v.pos.x <= SCREEN.x + 1 && v.pos.y <= SCREEN.y + 1,
			"a vertex off the screen",
		)
	}
	free_all(context.temp_allocator)
}

// A theme whose every colour field is its own sentinel.
@(private = "file")
sentinel_theme :: proc(base: u8) -> (th: ui.Theme, colours: [dynamic][3]u8) {
	th = ui.DEFAULT_THEME
	colours = make([dynamic][3]u8, context.temp_allocator)
	n: u8
	// (every Color field of the theme is a sentinel: found by type)
	for f in reflect.struct_fields_zipped(ui.Theme) {
		if f.type.id != typeid_of(ui.Color) {continue}
		c := ui.Color{base + 7 * n, 255 - 5 * n, 40 + 3 * n, 255}
		(^ui.Color)(rawptr(uintptr(&th) + f.offset))^ = c
		append(&colours, [3]u8{c.r, c.g, c.b})
		n += 1
	}
	return
}

// Every colour the screen and each phase of Ignite draw is a theme colour, a
// star's colour, a warp tint or a lit shade of the planet's palette; another
// theme changes every interface-coloured vertex.
@(test)
test_creation_colours_from_theme_or_data :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	app.last_frame_ms = 1000.0 / 60
	allowed := make([dynamic][3]u8, context.temp_allocator)
	for s in app.creation.stars {
		c := game.star_color(s)
		append(&allowed, [3]u8{c.r, c.g, c.b})
	}
	for c in starfield.STAR_TINTS {append(&allowed, c)}
	p := app.creation.planet
	palette := [4]ui.Color{p.water, p.ground, p.dry, p.ice}

	lit_shade :: proc(v: [3]u8, p: ui.Color) -> bool {
		// v = p * k per channel (truncated), 0.12 <= k <= 1
		k := f32(0)
		for ch in 0 ..< 3 {
			if p[ch] > 100 {k = max(k, f32(v[ch]) / f32(p[ch]))}
		}
		if k > 1.001 || k < 0.1 {return false}
		for ch in 0 ..< 3 {
			if abs(f32(p[ch]) * k - f32(v[ch])) > 2 {return false}
		}
		return true
	}

	check :: proc(
		t: ^testing.T,
		what: string,
		app: ^engine.App,
		theme: [dynamic][3]u8,
		allowed: [dynamic][3]u8,
		palette: [4]ui.Color,
		lit_shade: proc(v: [3]u8, p: ui.Color) -> bool,
	) {
		for v in app.ui.output.vertices {
			c := [3]u8{v.color.r, v.color.g, v.color.b}
			ok := false
			for a in theme {ok ||= a == c}
			for a in allowed {ok ||= a == c}
			for p in palette {ok ||= lit_shade(c, p)}
			testing.expectf(t, ok, "%s: a colour %v from nowhere", what, c)
			if !ok {return}
		}
	}

	th, colours := sentinel_theme(10)
	app.ui.theme = th
	creation_frame(app)
	creation_frame(app)
	check(t, "creation", app, colours, allowed, palette, lit_shade)
	first := make([dynamic]ui.Color, context.temp_allocator)
	for v in app.ui.output.vertices {append(&first, v.color)}

	th2, _ := sentinel_theme(60)
	app.ui.theme = th2
	creation_frame(app)
	testing.expect_value(t, len(app.ui.output.vertices), len(first))
	changed, same := 0, 0
	for v, i in app.ui.output.vertices {
		if i >= len(first) {break}
		if v.color != first[i] {changed += 1} else {same += 1}
	}
	testing.expect(t, changed > 0, "another theme changes the interface's colours")

	// One frame in each phase of Ignite.
	app.ui.theme = th
	for at in ([]f32{0.4, 1.0, 1.4, 1.9, 2.4}) {
		screen.ignite_start(app, app.creation.stars, app.creation.seed)
		app.debug.ignite_at = at
		ignite_frame(app)
		ignite_frame(app)
		check(t, "ignite", app, colours, allowed, palette, lit_shade)
		app.ignite.active = false
	}
	free_all(context.temp_allocator)
}

// debug.ignite_at holds Ignite at that time (a picture's frozen frame); a key
// still skips it.
@(test)
test_ignite_held_by_debug_time :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	app.last_frame_ms = 1000.0 / 60
	screen.ignite_start(app, app.creation.stars, app.creation.seed)
	app.debug.ignite_at = 1.35
	for _ in 0 ..< 30 {ignite_frame(app)}
	testing.expect(t, app.ignite.active, "still playing")
	testing.expect_value(t, app.ignite.t, 1.35)
	phase, _ := screen.ignite_phase(app.ignite.t)
	testing.expect_value(t, phase, screen.Ignite_Phase.Streaks)
	ignite_frame(app, {keys_pressed = {.Space}})
	testing.expect(t, !app.ignite.active, "a key skips it")
	free_all(context.temp_allocator)
}
