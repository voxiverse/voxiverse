package client

import "core:testing"

// Escape backs out of the top overlay first, a step at a time; game
// controls run only with nothing over the world that takes them.
@(test)
test_overlay_escape_order :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	console_init(&app.console)
	defer console_destroy(&app.console)
	o := &app.overlays
	app.screen = .Game
	testing.expect(t, game_controls(app) && !world_paused(app))

	escape(app) // pause
	testing.expect(t, overlay_is_open(o, .Pause) && world_paused(app) && !game_controls(app))
	overlay_open(o, .Options)
	overlay_open(o, .Console)
	app.console.line.searching = true
	escape(app) // the console's search
	testing.expect(t, overlay_is_open(o, .Console) && !app.console.line.searching)
	escape(app) // the console
	top, _ := overlay_top(o)
	testing.expect_value(t, top, Overlay.Options)
	escape(app) // Options: back to the pause menu
	top, _ = overlay_top(o)
	testing.expect_value(t, top, Overlay.Pause)
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
