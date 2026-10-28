package client

import "core:testing"

import "../common/game"
import "font"
import "ui"

// The death screen: it opens when the server says the player is dead, says how
// (the death line), cannot be escaped, and its one button sends Respawn; it
// closes when the server says the player is alive again.
@(test)
test_death_screen :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	app.symbol_font, ok = font.load(SYMBOL_FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font, fallback = &app.symbol_font))
	defer ui.destroy(&app.ui)
	s := new(Session)
	defer free(s)
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	s.endpoint = {&pipe, .Client}
	game.writer_init(&s.writer)
	defer game.writer_destroy(&s.writer)
	s.state = .Playing
	s.reg = test_reg()
	app.session = s
	defer app.session = nil
	app.screen = .Game

	frame :: proc(app: ^App, in_: ui.Input) {
		ui.begin_frame(&app.ui, in_, {1280, 720}, 1)
		draw_overlays(app, &app.ui)
		ui.end_frame(&app.ui)
	}

	death_sync(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Death), "open while alive")
	line := game.death_text(.Fall, "", "", "", true)
	s.dead = true
	s.death_len = copy(s.death_line[:], line)
	death_sync(app)
	testing.expect(t, overlay_is_open(&app.overlays, .Death) && !game_controls(app))
	testing.expect_value(t, string(s.death_line[:s.death_len]), "You fell")

	// Escape and the pad's Start do not leave it.
	pause_toggle(app)
	escape(app)
	testing.expect(t, overlay_is_open(&app.overlays, .Death))

	// A click on the button: Respawn is sent.
	th := &app.ui.theme
	box := ui.rect_center({0, 0, 1280, 720}, 420, 170)
	inner := ui.rect_shrink(box, 2 * th.padding)
	button := ui.cut_bottom(&inner, th.row_height)
	at := ui.Vec2{button.x + button.w / 2, button.y + button.h / 2}
	frame(app, {mouse = at})
	frame(app, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
	frame(app, {mouse = at, mouse_released = {.Left}})
	m, decoded := game.decode_client(s.writer.buf[:], test_reg())
	_, respawn := m.(game.Respawn)
	testing.expect(t, decoded && respawn, "no Respawn sent")

	// Alive again: the screen goes.
	s.dead = false
	death_sync(app)
	testing.expect(t, !overlay_is_open(&app.overlays, .Death))
	free_all(context.temp_allocator)
}
