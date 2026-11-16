package rally_client

import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "games:rally"
import rally_server "games:rally/server"
import "server:core"

// Rally played whole: the server part on a stepped server, a session that joins it over
// the harness's network with this client part (fetching the game's pack), and what the
// client draws: the course laid out from the server's seed, the countdown, a split, the
// gates marked ahead, the finish, the racers and the F3 line.

@(test)
test_rally_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, rally_server.GAME, GAME, {name = "racer"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "rally")
	counting :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).race.phase == .Countdown}
	if !testing.expect(t, playtest.until(rig, counting), "no countdown") {return}
	v := view(s)
	srv := playtest.srv(rig)
	d := rally_server.state(srv)
	testing.expect(t, v.course == d.course, "the client laid out another course")
	testing.expect_value(t, s.reg.game_modes[s.mode].id, rally.RACER_MODE)
	testing.expect(t, playtest.drawn(rig, "RALLY  race 1   starting"), status(s))
	testing.expect(t, playtest.drawn(rig, "RACE 1"), "no countdown banner")

	// The off; the first gate: its split; the next gate marked ahead.
	racing :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).race.phase == .Racing}
	if !testing.expect(t, playtest.until(rig, racing), "no off") {return}
	c := playtest.client(rig)
	go_to :: proc(rig: ^playtest.Rig, c: ^core.Client, k: int) {
		s := playtest.srv(rig)
		at := rally_server.place_at(&rally_server.state(s).course, k, 0)
		core.teleport(s, c, at, rally_server.EAST)
		playtest.step(rig, 6)
	}
	go_to(rig, c, 1)
	testing.expect(t, playtest.drawn(rig, "GATE 1  0:0"), "no split")
	testing.expect(t, playtest.drawn(rig, "RALLY  race 1   gate 2/6   0:0"), status(s))
	testing.expect(t, playtest.drawn(rig, "GATE 2"), "the next gate is not marked")

	// The finish: a course record, told; the racers; F3.
	for k in 2 ..= rally.CHECKPOINTS {go_to(rig, c, k)}
	testing.expect(t, playtest.drawn(rig, "COURSE RECORD: racer "), "no record banner")
	testing.expect(
		t,
		playtest.drawn(rig, "Rally: race 1, record ", scores = true),
		"no scoreboard",
	)
	board, has_board := engine.game_scoreboard(s)
	if testing.expect(t, has_board && len(board.rows) == 1) {
		testing.expect_value(t, board.rows[0].name, "racer")
		testing.expect_value(t, board.rows[0].cells[0], "done")
	}
	line := engine.game_debug_line(s)
	testing.expect(t, strings.has_prefix(line, "game rally: race 1 "), line)
	testing.expect(t, playtest.drawn_within(rig, 336), "drawn outside the screen below F3")
	// Alone and finished: the race is over, its results shown.
	results :: proc(rig: ^playtest.Rig) -> bool {return view(rig.s).race.phase == .Results}
	testing.expect(t, playtest.until(rig, results, 2), "no results")
	testing.expect(t, playtest.drawn(rig, "1. racer  0:"), "no results line")
}
