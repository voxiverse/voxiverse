package main

import "core:testing"

import "client:engine"
import "client:font"
import "client:overlay"
import "client:testkit"
import "client:ui"
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
	app.settings.keys.game_2 = .H
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
