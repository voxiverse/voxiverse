package main

import "core:testing"

import "client:engine"
import "client:font"
import "client:hud"
import "client:ui"

// The player list while its key is held: the engine's (names, kills, deaths, ping), or
// the table of a game that has a scoreboard, its title, headings and rows in its order.
@(test)
test_player_list_shows_a_games_scoreboard :: proc(t: ^testing.T) {
	app := new(engine.App)
	defer free(app)
	app.settings = engine.SETTINGS_DEFAULTS
	ok: bool
	app.font, ok = font.load(engine.FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	defer ui.destroy(&app.ui)
	s := new(engine.Session)
	defer free(s)
	s.config.name = "host"
	app.session = s
	defer app.session = nil

	// drawn: the frame's texts, in order, with the key held or not.
	drawn :: proc(app: ^engine.App, held: bool) -> []string {
		if held {app.actions.down += {.Player_List}} else {app.actions.down -= {.Player_List}}
		ui.begin_frame(&app.ui, {}, {1280, 720}, 1)
		hud.player_list_draw(app, &app.ui)
		texts := make([]string, len(app.ui.texts), context.temp_allocator)
		copy(texts, app.ui.texts[:])
		ui.end_frame(&app.ui)
		return texts
	}
	testing.expect_value(t, len(drawn(app, false)), 0)
	engine_list := drawn(app, true)
	testing.expect(t, len(engine_list) > 0 && engine_list[0] == "Player", "no engine list")
	testing.expect(t, has(engine_list, "Kills") && has(engine_list, "host"))

	s.game.scoreboard = proc(s: ^engine.Session, board: ^engine.Scoreboard) {
		board.title = "Match 4"
		engine.scoreboard_columns(board, "Frags", "Deaths")
		engine.scoreboard_row(board, "guest", "5", "1")
		engine.scoreboard_row(board, "host", "2", "3", you = true)
	}
	board := drawn(app, true)
	want := []string{"Match 4", "Player", "Frags", "Deaths", "guest", "5", "1", "host", "2", "3"}
	testing.expect_value(t, len(board), len(want))
	for w, i in want {
		if i < len(board) {testing.expect_value(t, board[i], w)}
	}
	testing.expect(t, !has(board, "Kills"), "the engine's list was drawn too")
	free_all(context.temp_allocator)
}

@(private = "file")
has :: proc(texts: []string, text: string) -> bool {
	for x in texts {if x == text {return true}}
	return false
}
