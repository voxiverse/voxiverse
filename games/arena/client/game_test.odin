package arena_client

import "core:fmt"
import "core:strings"
import "core:testing"

import "client:engine"
import "client:playtest"
import "common:game"
import "games:arena"
import arena_server "games:arena/server"
import "server:core"

// Arena played whole: the server part on a stepped server, a session that joins it
// over the harness's network with this client part (fetching the game's pack as any
// pack), a second player beside it, and what the client draws: the HUD's line, the
// kill feed, the scoreboard, the results and the F3 line.

@(test)
test_arena_on_the_hud :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, arena_server.GAME, GAME, {name = "host"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "arena")
	_, has_fighter := game.mode_find(s.reg, arena.FIGHTER_MODE)
	testing.expect(t, has_fighter, "the game's pack did not reach the client")

	// Alone over the LAN: the warm-up waits for a second player.
	playtest.step(rig, 10)
	v := view(s)
	testing.expect_value(t, v.match.phase, arena.Phase.Warmup)
	testing.expect_value(t, status(s), "ARENA  warm-up: waiting for players (1 of 2)")

	// A guest joins: the match.
	guest := playtest.guest_join(rig, "guest")
	playtest.until(
		rig,
		proc(rig: ^playtest.Rig) -> bool {return view(rig.s).match.phase == .Playing},
		30,
	)
	if !testing.expect_value(t, v.match.phase, arena.Phase.Playing) {return}
	testing.expect_value(t, s.reg.game_modes[s.mode].id, arena.FIGHTER_MODE)

	// The host shoots the guest down (the engine's pipeline, as a shot does).
	srv := playtest.srv(rig)
	source := core.Damage_Source {
		kind     = .Weapon,
		attacker = core.player_id(srv, playtest.client(rig)),
		weapon   = "Rifle",
	}
	testing.expect_value(t, core.damage(srv, guest, 1000, source), core.Damage_Result.Killed)
	playtest.step(rig, 3)

	want := fmt.tprintf("ARENA  match %d   ", v.match.match)
	testing.expect(t, playtest.drawn(rig, want), "the match is not on the HUD")
	testing.expect(t, strings.contains(status(s), "you 1   leader host 1"), status(s))
	testing.expect(t, playtest.drawn(rig, "host [Rifle] guest"), "the kill is not in the feed")

	// The scoreboard: both fighters, the host first, with the frag and the death.
	testing.expect(
		t,
		playtest.drawn(rig, "Arena: match 1, first to 15", scores = true),
		"no scoreboard",
	)
	board, has_board := engine.game_scoreboard(s)
	testing.expect(t, has_board && len(board.rows) == 2, "the scoreboard does not list both")
	if len(board.rows) == 2 {
		testing.expect_value(t, board.rows[0].name, "host")
		testing.expect_value(t, board.rows[0].cells[0], "1")
		testing.expect(t, board.rows[0].you && !board.rows[1].you)
		testing.expect_value(t, board.rows[1].name, "guest")
		testing.expect_value(t, board.rows[1].cells[1], "1")
	}

	// F3.
	line := engine.game_debug_line(s)
	testing.expect(t, strings.has_prefix(line, "game arena: match 1 Playing  t="), line)

	// The results: the winner, big.
	v.match.phase, v.match.winner, v.match.top_frags = .Results, "host", 15
	testing.expect(t, playtest.drawn(rig, "HOST WINS"), "no results banner")
	testing.expect(t, playtest.drawn(rig, "next match in "))
}
