package client

import "core:testing"

import "client:font"
import "client:ui"

// Escape backs out of the top overlay first, a step at a time; game
// controls run only with nothing over the world that takes them.
@(test)
test_overlay_escape_order :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	console_init(&app.console)
	defer console_destroy(&app.console)
	o := &app.overlays
	app.screen = .Game
	testing.expect(t, game_controls(app) && !world_paused(app))

	escape(app) // pause
	testing.expect(t, overlay_is_open(o, .Game_Menu) && world_paused(app) && !game_controls(app))
	overlay_open(o, .Options)
	overlay_open(o, .Console)
	app.console.line.searching = true
	escape(app) // the console's search
	testing.expect(t, overlay_is_open(o, .Console) && !app.console.line.searching)
	escape(app) // the console
	top, _ := overlay_top(o)
	testing.expect_value(t, top, Overlay.Options)
	escape(app) // Options: back to the game menu
	top, _ = overlay_top(o)
	testing.expect_value(t, top, Overlay.Game_Menu)
	escape(app)
	testing.expect(t, o.count == 0 && game_controls(app))

	// Tuning frees the mouse but the world runs on; the console opened
	// again goes on top, once.
	overlay_open(o, .Tuning)
	testing.expect(t, !game_controls(app) && !world_paused(app))
	overlay_open(o, .Console)
	overlay_open(o, .Tuning)
	overlay_open(o, .Console)
	testing.expect_value(t, o.count, 2)
	top, _ = overlay_top(o)
	testing.expect_value(t, top, Overlay.Console)

	// Leaving the world closes what belongs to it, not the console.
	overlays_leave_game(o)
	testing.expect(t, o.count == 1 && overlay_is_open(o, .Console))
	overlay_close(o, .Console)
	app.screen = .Title
	escape(app)
	testing.expect(t, overlay_is_open(o, .Quit_Dialog))
}

// Keys and typing go to the top overlay only: the console over the chat
// gets what is typed; closed, the chat gets it. `t` opens the chat only
// over the game.
@(test)
test_overlay_keys_go_to_the_top :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	console_init(&app.console)
	defer console_destroy(&app.console)
	line_editor_init(&app.chat)
	defer line_editor_destroy(&app.chat)
	s := new(Session)
	defer free(s)
	s.state = .Playing
	s.reg = test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game

	frame :: proc(app: ^App, typed: []rune) {
		ui.begin_frame(&app.ui, {text = typed}, {1280, 720}, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	// `t` over the game opens the chat, typing nothing into it.
	app.input.pressed = {.T}
	actions_sync(app)
	in_ := ui.Input {
		text = []rune{'t'},
	}
	chat_keys(app, &in_)
	testing.expect(t, overlay_is_open(&app.overlays, .Chat) && in_.text == nil)
	app.input.pressed = {}
	actions_sync(app)
	frame(app, nil)
	frame(app, {'h', 'i'})
	testing.expect_value(t, string(app.chat.text[:]), "hi")

	overlay_open(&app.overlays, .Console)
	frame(app, nil)
	frame(app, {'x'})
	testing.expect_value(t, string(app.console.line.text[:]), "x")
	testing.expect_value(t, string(app.chat.text[:]), "hi")
	// Over the console, `t` is typing, not the chat.
	app.input.pressed = {.T}
	actions_sync(app)
	in_ = {
		text = []rune{'t'},
	}
	chat_keys(app, &in_)
	testing.expect(t, in_.text != nil)
	app.input.pressed = {}
	actions_sync(app)

	escape(app) // the console
	frame(app, nil)
	frame(app, {'!'})
	testing.expect_value(t, string(app.chat.text[:]), "hi!")
	escape(app) // the chat, its line dropped
	testing.expect(t, app.overlays.count == 0 && len(app.chat.text) == 0)
	free_all(context.temp_allocator)
}
