package client

import "core:os"
import "core:strings"
import "core:testing"

import "client:mesh"
import "client:ui"
import "common:game"
import "common:worldgen"

// The creation screen and Ignite (screen_creation.odin, screen_ignite.odin).
// (A universe made with a typed seed has that seed's glyph address:
// server/gamemode_test.odin.)

@(private = "file")
creation_app :: proc(t: ^testing.T) -> ^App {
	app := ui_app(t)
	app.screen = .Universes
	creation_open(app)
	return app
}

@(private = "file")
creation_free :: proc(app: ^App) {
	creation_destroy(&app.creation)
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
	creation_roll(c, 12345)
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
	creation_roll(c, 777)
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
	creation_sync_seed(c, 1)
	testing.expect_value(t, c.seed, 42)
	testing.expect_value(t, game.seed_glyphs(c.seed), game.address_derive(42))
	// Text is hashed, and its glyphs are on the screen as they are typed.
	clear(&c.seed_text)
	append(&c.seed_text, "andromeda")
	creation_sync_seed(c, 1)
	hashed, _ := game.seed_of_text("andromeda")
	testing.expect_value(t, c.seed, hashed)
	ui_frame(app)
	glyphs := game.address_text(game.seed_glyphs(hashed))
	found := false
	for text in app.ui.texts {if text == glyphs {found = true}}
	testing.expect(t, found, "the glyphs of the typed seed are shown")
	// Emptied: a fresh roll.
	clear(&c.seed_text)
	creation_sync_seed(c, 99)
	testing.expect(t, c.seed != hashed && !c.typed)
	free_all(context.temp_allocator)
}

// The three facts under the preview are the generator's parameters: the
// home world is Earth's, whatever the seed.
@(test)
test_preview_facts_are_the_generators :: proc(t: ^testing.T) {
	f := home_facts()
	p := worldgen.PARAMS_DEFAULTS
	testing.expect_value(t, f, home_facts_of(p, game.RULES_DEFAULTS))
	testing.expect_value(t, f.minutes, int(game.RULES_DEFAULTS.day_length / 60))
	// The words follow the numbers.
	p.warmth, p.wetness, p.mountain_height = -0.9, 0.9, 150
	cold := home_facts_of(p, game.RULES_DEFAULTS)
	testing.expect_value(t, cold.warmth, Text.Fact_Cold)
	testing.expect_value(t, cold.wetness, Text.Fact_Wet)
	testing.expect_value(t, cold.terrain, Text.Fact_Terrain_Mountains)
	p.warmth, p.wetness, p.mountain_height, p.hill_height = 0.9, -0.9, 20, 2
	hot := home_facts_of(p, game.RULES_DEFAULTS)
	testing.expect_value(t, hot.warmth, Text.Fact_Hot)
	testing.expect_value(t, hot.wetness, Text.Fact_Dry)
	testing.expect_value(t, hot.terrain, Text.Fact_Terrain_Flat)
	// All shown on the screen.
	app := creation_app(t)
	defer creation_free(app)
	ui_frame(app)
	for want in ([]string{"Climate: ", "Sky: ", "Terrain: "}) {
		seen := false
		for text in app.ui.texts {if strings.has_prefix(text, want) {seen = true}}
		testing.expectf(t, seen, "no %q line", want)
	}
	free_all(context.temp_allocator)
}

// The plan Ignite carries out: one directory, a free variant of the name,
// with the seed and mode chosen.
@(test)
test_universe_plan :: proc(t: ^testing.T) {
	dir := "build/test/plan"
	os.remove_all(dir)
	defer os.remove_all(dir)
	saves_override = dir
	defer saves_override = ""
	plan := universe_plan("My World", 42, "survival")
	testing.expect_value(t, plan.seed, 42)
	testing.expect_value(t, plan.mode, "survival")
	testing.expect(t, strings.has_suffix(plan.path, "My World"))
	os.make_directory_all(plan.path)
	again := universe_plan("My World", 43, "creative")
	testing.expect(t, strings.has_suffix(again.path, "My World (2)"), "a free variant")
	testing.expect(
		t,
		strings.has_suffix(universe_plan("///", 1, "creative").path, "New Universe") ||
		strings.contains(universe_plan("///", 1, "creative").path, "___"),
	)
	free_all(context.temp_allocator)
}

@(private = "file")
ignite_frame :: proc(app: ^App, input: ui.Input = {}) {
	ui.begin_frame(&app.ui, input, SCREEN, 1)
	ignite_ui(app, &app.ui)
	ui.end_frame(&app.ui)
}

// Ignite plays 2.5 s on a stepped clock (and the cue is fired once), any key
// skips it, and with Reduce motion it is a 0.3 s cross-fade.
@(test)
test_ignite_plays_and_skips :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	app.last_frame_ms = 1000.0 / 60
	ignite_start(app, app.creation.stars, app.creation.seed)
	testing.expect_value(t, len(app.cues), 1)
	testing.expect_value(t, app.cues[0], "ui_ignite")
	frames := 0
	for app.ignite.active && frames < 1000 {
		ignite_frame(app)
		frames += 1
	}
	testing.expect(t, abs(f32(frames) / 60 - IGNITE_SECONDS) < 0.05, "2.5 s of frames")
	testing.expect_value(t, len(app.cues), 1) // (not fired again)

	// A key press skips it (the first frame's input is the click that began it).
	ignite_start(app, app.creation.stars, app.creation.seed)
	ignite_frame(app, {keys_pressed = {.Enter}})
	testing.expect(t, app.ignite.active, "the key that started it does not skip it")
	ignite_frame(app)
	ignite_frame(app, {keys_pressed = {.Space}})
	testing.expect(t, !app.ignite.active, "a key skips it")
	ignite_start(app, app.creation.stars, app.creation.seed)
	ignite_frame(app)
	ignite_frame(app, {mouse_pressed = {.Left}})
	testing.expect(t, !app.ignite.active, "a click skips it")

	// Reduce motion: no collapse, flash or zoom, a cross-fade of 0.3 s.
	app.settings.reduce_motion = true
	ignite_start(app, app.creation.stars, app.creation.seed)
	ignite_frame(app)
	quads_reduced := len(app.ui.output.vertices)
	frames = 1
	for app.ignite.active && frames < 1000 {
		ignite_frame(app)
		frames += 1
	}
	testing.expect(t, abs(f32(frames) / 60 - IGNITE_FADE) < 0.05, "a 0.3 s cross-fade")
	app.settings.reduce_motion = false
	ignite_start(app, app.creation.stars, app.creation.seed)
	for _ in 0 ..< 100 {ignite_frame(app)} 	// well into the zoom
	testing.expect(
		t,
		quads_reduced < len(app.ui.output.vertices) / 10,
		"no zoom with Reduce motion",
	)
	free_all(context.temp_allocator)
}

// The planet Ignite draws takes its colours from the home world's kind:
// its water, its palette's ground and dry ground, and snow; whatever the seed.
@(test)
test_planet_colours_are_the_kinds :: proc(t: ^testing.T) {
	app := creation_app(t)
	defer creation_free(app)
	surface := worldgen.PALETTES[int(worldgen.PARAMS_DEFAULTS.palette)]
	want := Planet_Palette {
		water  = ui.Color(mesh.block_average_colour(app.registry, .Water, .Pos_Y)),
		ground = ui.Color(mesh.block_average_colour(app.registry, surface[0], .Pos_Y)),
		dry    = ui.Color(mesh.block_average_colour(app.registry, surface[2], .Pos_Y)),
		ice    = ui.Color(mesh.block_average_colour(app.registry, .Snow, .Pos_Y)),
	}
	for seed in ([]u64{42, 0xdead_beef}) {
		creation_roll(&app.creation, seed)
		testing.expect_value(t, app.creation.planet, want)
		ignite_start(app, app.creation.stars, seed)
		testing.expect_value(t, app.ignite.planet, want)
	}
	// Another kind of world has another palette (frost: snow, dirt, ice).
	p := worldgen.PARAMS_DEFAULTS
	p.palette = 2
	frost := planet_palette(app.registry, p)
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
