package towers_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "common:game"
import "common:protocol"
import "games:towers"
import towers_server "games:towers/server"
import "server:core"

// Towers played whole: the server part on a stepped server, a session that joins it
// over the harness's network with this client part (fetching the game's pack, its
// creeps and blocks with it), and what the client draws: the HUD's line, a wave's
// banner, the creeps' health bars, the tower's shots, the builders and the F3 line.

@(test)
test_towers_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, towers_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "towers")
	v := view(s)
	testing.expect(
		t,
		v.kinds[.Brute] != 0 && v.pieces[.Cannon] != game.NO_ITEM,
		"the pack did not reach the client",
	)
	playtest.step(rig, 10)
	testing.expect_value(t, v.run.phase, towers.Phase.Building)
	testing.expect(t, strings.has_prefix(status(s), "TOWERS  build!  first wave in "), status(s))
	testing.expect_value(t, mine(s).coins, towers.DEFAULT_SETTINGS.coins)

	// A tower by the gate, and the first wave: the banner, the shots, a creep hurt.
	srv := playtest.srv(rig)
	builder := playtest.client(rig)
	at := game.Block_Pos{towers.BUILD_MIN_X + 1, 0, towers.MID_Z + 2}
	builder.player.position = {f64(at.x) + 0.5, 3, f64(at.z) + 0.5}
	d := towers_server.state(srv)
	r := core.apply_edit(srv, builder, protocol.edit_plain(1, 0, at, d.blocks[.Arrow]))
	testing.expect(t, r.accepted, "the tower was refused")
	towers_server.wave_begin(srv)
	playtest.until(rig, proc(rig: ^playtest.Rig) -> bool {return view(rig.s).shots > 0}, 10)
	testing.expect(t, v.shots > 0, "no shot was seen")
	testing.expect_value(t, v.run.phase, towers.Phase.Wave)
	hurt := false
	for _, e in s.entities {hurt ||= e.max_health > 0 && e.health < e.max_health}

	testing.expect(t, playtest.drawn(rig, "TOWERS  wave 1 of 10   creeps "), status(s))
	testing.expect(
		t,
		playtest.drawn(rig, fmt.tprintf("WAVE 1: %d CREEPS", towers.wave_size(1))),
		"no wave banner",
	)
	testing.expect(t, hurt || v.shots > 0, "no creep was hurt")

	// The builders: one row, the player's own, with its coins and what it spent.
	testing.expect(
		t,
		playtest.drawn(rig, "Towers: run 1, wave 1 of 10", scores = true),
		"no scoreboard",
	)
	board, has_board := engine.game_scoreboard(s)
	if testing.expect(t, has_board && len(board.rows) == 1) {
		testing.expect_value(t, board.rows[0].name, "builder")
		testing.expect_value(t, board.rows[0].cells[2], fmt.tprint(towers.PIECES[.Arrow].price))
		testing.expect(t, board.rows[0].you)
	}

	// F3, and the run's end.
	line := engine.game_debug_line(s)
	testing.expect(t, strings.has_prefix(line, "game towers: run 1 Wave None  wave 1/10"), line)
	v.run.phase = .Results
	testing.expect(t, playtest.drawn(rig, "a new run in "), "no results line")
}
