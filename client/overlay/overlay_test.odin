package overlay

import "core:testing"

import "client:console"
import "client:engine"
import "client:font"
import "client:testkit"
import "client:ui"

// Escape backs out of the top overlay first, a step at a time; game
// controls run only with nothing over the world that takes them.
@(test)
test_overlay_escape_order :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	console.console_init(&app.console)
	defer console.console_destroy(&app.console)
	o := &app.overlays
	app.screen = .Game
	testing.expect(t, engine.game_controls(app) && !engine.world_paused(app))

	escape(app) // pause
	testing.expect(
		t,
		engine.overlay_is_open(o, .Game_Menu) &&
		engine.world_paused(app) &&
		!engine.game_controls(app),
	)
	engine.overlay_open(o, .Options)
	engine.overlay_open(o, .Console)
	app.console.line.searching = true
	escape(app) // the console's search
	testing.expect(t, engine.overlay_is_open(o, .Console) && !app.console.line.searching)
	escape(app) // the console
	top, _ := engine.overlay_top(o)
	testing.expect_value(t, top, engine.Overlay.Options)
	escape(app) // Options: back to the game menu
	top, _ = engine.overlay_top(o)
	testing.expect_value(t, top, engine.Overlay.Game_Menu)
	escape(app)
	testing.expect(t, o.count == 0 && engine.game_controls(app))

	// Tuning frees the mouse but the world runs on; the console opened
	// again goes on top, once.
	engine.overlay_open(o, .Tuning)
	testing.expect(t, !engine.game_controls(app) && !engine.world_paused(app))
	engine.overlay_open(o, .Console)
	engine.overlay_open(o, .Tuning)
	engine.overlay_open(o, .Console)
	testing.expect_value(t, o.count, 2)
	top, _ = engine.overlay_top(o)
	testing.expect_value(t, top, engine.Overlay.Console)

	// Leaving the world closes what belongs to it, not the console.
	engine.overlays_leave_game(o)
	testing.expect(t, o.count == 1 && engine.overlay_is_open(o, .Console))
	engine.overlay_close(o, .Console)
	app.screen = .Title
	escape(app)
	testing.expect(t, engine.overlay_is_open(o, .Quit_Dialog))
}

// Keys and typing go to the top overlay only: the console over the chat
// gets what is typed; closed, the chat gets it. `t` opens the chat only
// over the game.
@(test)
test_overlay_keys_go_to_the_top :: proc(t: ^testing.T) {
	app := new(engine.App)
	app.settings = engine.SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	console.console_init(&app.console)
	defer console.console_destroy(&app.console)
	engine.line_editor_init(&app.chat)
	defer engine.line_editor_destroy(&app.chat)
	s := new(engine.Session)
	defer free(s)
	s.state = .Playing
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game

	frame :: proc(app: ^engine.App, typed: []rune) {
		ui.begin_frame(&app.ui, {text = typed}, {1280, 720}, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	// `t` over the game opens the chat, typing nothing into it.
	app.input.pressed = {.T}
	engine.actions_sync(app)
	in_ := ui.Input {
		text = []rune{'t'},
	}
	chat_keys(app, &in_)
	testing.expect(t, engine.overlay_is_open(&app.overlays, .Chat) && in_.text == nil)
	app.input.pressed = {}
	engine.actions_sync(app)
	frame(app, nil)
	frame(app, {'h', 'i'})
	testing.expect_value(t, string(app.chat.text[:]), "hi")

	engine.overlay_open(&app.overlays, .Console)
	frame(app, nil)
	frame(app, {'x'})
	testing.expect_value(t, string(app.console.line.text[:]), "x")
	testing.expect_value(t, string(app.chat.text[:]), "hi")
	// Over the console, `t` is typing, not the chat.
	app.input.pressed = {.T}
	engine.actions_sync(app)
	in_ = {
		text = []rune{'t'},
	}
	chat_keys(app, &in_)
	testing.expect(t, in_.text != nil)
	app.input.pressed = {}
	engine.actions_sync(app)

	escape(app) // the console
	frame(app, nil)
	frame(app, {'!'})
	testing.expect_value(t, string(app.chat.text[:]), "hi!")
	escape(app) // the chat, its line dropped
	testing.expect(t, app.overlays.count == 0 && len(app.chat.text) == 0)
	free_all(context.temp_allocator)
}
