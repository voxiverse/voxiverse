package horde_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "common:game"
import "games:horde"
import horde_server "games:horde/server"

// Horde played whole: the server part on a stepped server, a session that joins it over
// the harness's network with this client part (fetching the game's pack), and what the
// client does and draws: the countdown and the shop, a game action that buys at the
// counter, a wave's banner and line, the survivors and the F3 line.

@(test)
test_horde_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, horde_server.GAME, GAME, {name = "survivor"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "horde")
	v := view(s)
	testing.expect(
		t,
		v.kinds[.Matriarch] != 0 && v.round != game.NO_ITEM,
		"the pack did not reach the client",
	)
	counting :: proc(rig: ^playtest.Rig) -> bool {
		return view(rig.s).run.phase == .Countdown && horde_server.state(&rig.h.srv).built
	}
	if !testing.expect(t, playtest.until(rig, counting), "no countdown") {return}
	playtest.step(rig, 5)
	testing.expect(t, playtest.drawn(rig, "HORDE  run 1   the first wave in "), status(s))
	testing.expect(t, playtest.drawn(rig, "RUN 1"), "no countdown banner")
	testing.expect(t, playtest.drawn(rig, "at the counter:  Z rounds (8)"), "no shop line")
	testing.expect_value(t, s.reg.game_modes[s.mode].id, horde.SURVIVOR_MODE)

	// Z at the counter buys rounds: the server takes the coins and gives them.
	srv := playtest.srv(rig)
	c := playtest.client(rig)
	before := game.inventory_count(&s.inventory, v.round)
	rig.actions.pressed += {.Game_1}
	playtest.step(rig)
	rig.actions.pressed -= {.Game_1}
	playtest.step(rig, 4)
	r := horde_server.survivor(srv, c)
	testing.expect_value(t, r.coins, horde.DEFAULT_SETTINGS.coins - horde.DEFAULT_SETTINGS.rounds)
	testing.expect_value(
		t,
		game.inventory_count(&s.inventory, v.round),
		before + horde.ROUNDS_PACK,
	)
	testing.expect_value(t, int(mine(s).coins), r.coins)

	// The first wave: its banner, the line, the creatures' count.
	horde_server.wave_begin(srv)
	playtest.until(rig, proc(rig: ^playtest.Rig) -> bool {return view(rig.s).run.alive > 1}, 5)
	testing.expect(t, playtest.drawn(rig, "WAVE 1: 4 CREATURES"), "no wave banner")
	testing.expect(t, playtest.drawn(rig, "HORDE  wave 1   creatures "), status(s))
	testing.expect(
		t,
		strings.contains(status(s), fmt.tprintf("rounds %d", before + horde.ROUNDS_PACK)),
		status(s),
	)

	// The survivors, F3, and the HUD kept below F3.
	testing.expect(t, playtest.drawn(rig, "Horde: run 1, wave 1", scores = true), "no scoreboard")
	board, has_board := engine.game_scoreboard(s)
	if testing.expect(t, has_board && len(board.rows) == 1) {
		testing.expect_value(t, board.rows[0].name, "survivor")
		testing.expect(t, board.rows[0].you)
	}
	line := engine.game_debug_line(s)
	testing.expect(t, strings.has_prefix(line, "game horde: run 1 Wave  wave 1  creatures "), line)
	testing.expect(t, playtest.drawn_within(rig, 336), "drawn outside the screen below F3")

	// Down: the watcher's banner; the run's end.
	v.run.phase = .Wave
	mine(s).down = true
	testing.expect(t, playtest.drawn(rig, "DOWN: watching until the wave ends"))
	mine(s).down = false
	v.run.phase, v.run.wave, v.run.best = .Over, 4, 3
	testing.expect(t, playtest.drawn(rig, "THE HORDE WINS"))
	testing.expect(t, playtest.drawn(rig, "3 waves held   best 3"))
}
