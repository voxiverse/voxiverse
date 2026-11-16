package main

import "core:os"
import "core:testing"

import "client:engine"
import "client:font"
import "client:overlay"
import "client:platform"
import "client:testkit"
import "client:ui"
import "common:base"
import "common:game"
import "common:protocol"

// A game's screen: opened by the game, drawn by its hook over the world and taking the
// keys and the pointer, closed by the game or by the player (Escape, the pad's Back) and
// with the world; a game without a screen hook has none.

@(private = "file")
SHOP_GAME :: engine.Game {
	info = {id = "shop", name = "Shop", description = "A shop."},
	screen = proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
		ui.panel(ctx, {440, 260, 400, 200})
		ui.label(ctx, "the shop's wares", {460, 280, 360, 30})
	},
}

@(private = "file")
Shop_Fixture :: struct {
	app:  ^engine.App,
	s:    ^engine.Session,
	pipe: protocol.Pipe,
}

@(private = "file")
shop_fixture :: proc(t: ^testing.T, f: ^Shop_Fixture) {
	f.app = new(engine.App)
	f.app.settings = engine.SETTINGS_DEFAULTS
	ok: bool
	f.app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&f.app.ui, &f.app.font))
	f.s = new(engine.Session)
	protocol.pipe_init(&f.pipe)
	f.s.endpoint = {&f.pipe, .Client}
	game.writer_init(&f.s.writer)
	f.s.state = .Playing
	f.s.reg = testkit.test_reg()
	f.s.game = SHOP_GAME
	f.app.session = f.s
	f.app.screen = .Game
}

@(private = "file")
shop_fixture_destroy :: proc(f: ^Shop_Fixture) {
	f.app.session = nil
	game.writer_destroy(&f.s.writer)
	protocol.pipe_destroy(&f.pipe)
	free(f.s)
	ui.destroy(&f.app.ui)
	free(f.app)
}

// shop_frame: the overlays' frame, as the client's: synced, then drawn.
@(private = "file")
shop_frame :: proc(app: ^engine.App) -> (drawn: bool) {
	engine.game_screen_sync(app)
	ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
	overlay.draw_overlays(app, &app.ui)
	for x in app.ui.texts {drawn ||= x == "the shop's wares"}
	ui.end_frame(&app.ui)
	return
}

@(test)
test_a_games_screen_opens_and_closes :: proc(t: ^testing.T) {
	f: Shop_Fixture
	shop_fixture(t, &f)
	defer shop_fixture_destroy(&f)
	app, s := f.app, f.s
	testing.expect(t, !shop_frame(app), "drawn before it was opened")
	testing.expect(t, engine.game_controls(app))

	engine.game_screen_open(s)
	testing.expect(t, shop_frame(app), "not drawn when opened")
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Game_Screen))
	testing.expect(t, !engine.game_controls(app), "the world kept the keys")
	testing.expect(t, !engine.world_paused(app), "the world paused")

	// The player closes it (Escape and the pad's Back are both escape).
	overlay.escape(app)
	testing.expect(t, !engine.game_screen_shown(s))
	testing.expect(t, !shop_frame(app), "drawn after Escape")
	testing.expect(t, !engine.overlay_is_open(&app.overlays, .Game_Menu), "Escape went past it")

	// The game closes it.
	engine.game_screen_open(s)
	testing.expect(t, shop_frame(app))
	engine.game_screen_close(s)
	testing.expect(t, !shop_frame(app), "drawn after the game closed it")
	testing.expect(t, engine.game_controls(app))

	// Leaving the world closes it.
	engine.game_screen_open(s)
	testing.expect(t, shop_frame(app))
	s.state = .Failed
	testing.expect(t, !shop_frame(app), "drawn after the world was left")
	s.state = .Playing

	// A game without a screen has none to open.
	s.game = {
		info = {id = "plain", name = "Plain", description = "No screen."},
	}
	engine.game_screen_open(s)
	testing.expect(t, !engine.game_screen_shown(s))
	testing.expect(t, !shop_frame(app))
}

// A game's HUD names the keys of its actions as the player bound them, and its screen hears
// them pressed while it is open (the key that opened a market closes it).
@(test)
test_a_games_actions_name_their_keys :: proc(t: ^testing.T) {
	f: Shop_Fixture
	shop_fixture(t, &f)
	defer shop_fixture_destroy(&f)
	app, s := f.app, f.s
	s.game.actions = {"Shop", "Haggle"}
	shop_frame(app) // (the game's bindings read: its defaults)
	s.binds.actions[1] = .H
	shop_frame(app)
	testing.expect_value(t, engine.game_action_key(s, 0), "Z")
	testing.expect_value(t, engine.game_action_key(s, 1), "H")
	testing.expect_value(t, engine.game_action_key(s, 2), "") // (the game has two)
	testing.expect(t, !engine.game_action_pressed(s, 0))

	engine.game_screen_open(s)
	shop_frame(app)
	app.actions.key_pressed += {.Game_1}
	shop_frame(app)
	testing.expect(t, engine.game_action_pressed(s, 0), "the screen did not hear its key")
	testing.expect(t, !engine.game_action_pressed(s, 1))
	app.actions.key_pressed -= {.Game_1}
	shop_frame(app)
	testing.expect(t, !engine.game_action_pressed(s, 0), "a press lasted past its frame")
}

// A game's own keys (a strategy game's hotkeys): named, pressed and held while the world
// has the keyboard, and not while a screen over it does.
@(test)
test_a_games_own_keys :: proc(t: ^testing.T) {
	f: Shop_Fixture
	shop_fixture(t, &f)
	defer shop_fixture_destroy(&f)
	app, s := f.app, f.s
	s.game.keys = {{"Group 1", .Num_1}, {"Stop", .S}}
	app.input.pressed += {.Num_1}
	app.input.held += {.Num_1}
	shop_frame(app)
	testing.expect_value(t, engine.game_key_label(s, 0), "1")
	testing.expect_value(t, engine.game_key_label(s, 1), "S")
	testing.expect_value(t, engine.game_key_label(s, 2), "")
	testing.expect(t, engine.game_key_pressed(s, 0), "the key's press was not heard")
	testing.expect(t, engine.game_key_down(s, 0))
	testing.expect(t, !engine.game_key_pressed(s, 1))
	app.input.pressed = {}
	shop_frame(app)
	testing.expect(t, !engine.game_key_pressed(s, 0), "a press lasted past its frame")
	testing.expect(t, engine.game_key_down(s, 0), "held, but not down")
	// A screen over the world has the keyboard: the game's keys are not heard.
	engine.game_screen_open(s)
	app.input.pressed += {.Num_1}
	shop_frame(app)
	shop_frame(app)
	testing.expect(t, !engine.game_key_pressed(s, 0), "heard under its screen")
}

// A key goes to one consumer: in the world a key bound to the game's action or key is the
// game's alone (the hotbar's slot on the same digit does not fire), rebound it is the
// engine's again, and a game whose players hold no hotbar frees the hotbar's keys.
@(test)
test_a_games_key_is_its_alone :: proc(t: ^testing.T) {
	f: Shop_Fixture
	shop_fixture(t, &f)
	defer shop_fixture_destroy(&f)
	app, s := f.app, f.s
	s.game.actions = {"Shop"}
	s.game.keys = {{"Group 1", .Num_1}}
	shop_frame(app)
	press :: proc(app: ^engine.App, k: platform.Key) {
		app.input.pressed, app.input.held = {k}, {k}
		engine.actions_update(
			&app.actions,
			&app.input,
			&app.settings,
			.World,
			false,
			1.0 / 60,
			engine.game_binds(app),
		)
		shop_frame(app)
		app.input.pressed, app.input.held = {}, {}
		engine.actions_update(
			&app.actions,
			&app.input,
			&app.settings,
			.World,
			false,
			1.0 / 60,
			engine.game_binds(app),
		)
	}
	press(app, .Num_1)
	testing.expect(t, engine.game_key_pressed(s, 0), "the game's key not heard")
	testing.expect(t, .Hotbar_1 not_in app.actions.pressed, "the hotbar heard the game's key")
	// Without the game, the digit is the hotbar's.
	app.input.pressed, app.input.held = {.Num_1}, {.Num_1}
	engine.actions_update(&app.actions, &app.input, &app.settings, .World, false, 1.0 / 60)
	testing.expect(t, .Hotbar_1 in app.actions.pressed)
	app.input.pressed, app.input.held = {}, {}
	engine.actions_update(&app.actions, &app.input, &app.settings, .World, false, 1.0 / 60)

	// The game's action bound to a digit: the action fires, the hotbar's slot does not.
	s.binds.actions[0] = .Num_2
	s.binds.keys[0] = .G
	app.input.pressed, app.input.held = {.Num_2}, {.Num_2}
	engine.actions_update(
		&app.actions,
		&app.input,
		&app.settings,
		.World,
		false,
		1.0 / 60,
		engine.game_binds(app),
	)
	testing.expect(t, .Game_1 in app.actions.pressed, "the game's action did not fire")
	testing.expect(t, .Hotbar_2 not_in app.actions.pressed, "the hotbar heard the game's action")
	app.input.pressed, app.input.held = {}, {}
	engine.actions_update(
		&app.actions,
		&app.input,
		&app.settings,
		.World,
		false,
		1.0 / 60,
		engine.game_binds(app),
	)
	// Rebound away from the digit: it is the hotbar's again.
	app.input.pressed, app.input.held = {.Num_1}, {.Num_1}
	engine.actions_update(
		&app.actions,
		&app.input,
		&app.settings,
		.World,
		false,
		1.0 / 60,
		engine.game_binds(app),
	)
	testing.expect(t, .Hotbar_1 in app.actions.pressed, "a rebound key still the game's")
	app.input.pressed, app.input.held = {}, {}
	engine.actions_update(
		&app.actions,
		&app.input,
		&app.settings,
		.World,
		false,
		1.0 / 60,
		engine.game_binds(app),
	)

	// A game with no hotbar: the hotbar's keys pick nothing.
	s.game.no_hotbar = true
	s.binds.loaded = false
	shop_frame(app)
	app.input.pressed, app.input.held = {.Num_3}, {.Num_3}
	engine.actions_update(
		&app.actions,
		&app.input,
		&app.settings,
		.World,
		false,
		1.0 / 60,
		engine.game_binds(app),
	)
	testing.expect(t, .Hotbar_3 not_in app.actions.pressed, "a hotbar key in a game with none")
}

// The keys a player binds to a game are kept for that game, and another game keeps its own.
@(test)
test_a_games_keys_are_saved_for_it :: proc(t: ^testing.T) {
	saved := base.boot_info()
	info := saved
	info.env.settings = "build/test/game_keys_test/settings.cfg"
	base.boot_install(info)
	defer base.boot_install(saved)
	defer os.remove_all("build/test/game_keys_test")

	f: Shop_Fixture
	shop_fixture(t, &f)
	defer shop_fixture_destroy(&f)
	app, s := f.app, f.s
	s.game.actions = {"Shop"}
	s.game.keys = {{"Group 1", .Num_1}, {"Stop", .S}}
	shop_frame(app)
	testing.expect_value(t, s.binds.keys[1], platform.Key.S) // (its default)
	s.binds.actions[0], s.binds.keys[1] = .K, .Num_9
	engine.game_binds_save(app)

	// The same game again: as bound.
	s.binds = {}
	shop_frame(app)
	testing.expect_value(t, s.binds.actions[0], platform.Key.K)
	testing.expect_value(t, s.binds.keys[0], platform.Key.Num_1)
	testing.expect_value(t, s.binds.keys[1], platform.Key.Num_9)
	testing.expect_value(t, engine.game_key_label(s, 1), "9")
	// Another game: its own defaults.
	s.game.id = "other"
	s.binds = {}
	shop_frame(app)
	testing.expect_value(t, s.binds.actions[0], platform.Key.Z)
	testing.expect_value(t, s.binds.keys[1], platform.Key.S)
}
