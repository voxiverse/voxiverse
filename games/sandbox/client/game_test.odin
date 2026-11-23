package sandbox_client

import "core:testing"

import "client:engine"
import "client:playtest"
import sandbox_server "games:sandbox/server"

// The sandbox played whole: its server part on a stepped server and a session that joins
// it over the harness's network with this client part, playing it.

@(test)
test_sandbox_joined :: proc(t: ^testing.T) {
	rig := new(playtest.Rig) // (the heap: a Harness is large, a test thread's stack is not)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	s := rig.s
	testing.expect_value(t, s.game.id, "sandbox")
	testing.expect_value(t, s.welcome.game, "sandbox")
	testing.expect_value(t, engine.game_debug_line(s), "")
}

// The ruin's fight shows as a bar across the top while the player is in one, and nothing
// shows while it is in none.
@(test)
test_sandbox_ruin_bar :: proc(t: ^testing.T) {
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, sandbox_server.GAME, GAME, {name = "builder"}) {return}
	defer playtest.stop(rig)
	testing.expect(t, !playtest.drawn(rig, "RUIN"), "a bar with no fight")
	view(rig.s).ruin = {
		phase   = .Wave,
		wave    = 2,
		waves   = 5,
		alive   = 3,
		to_come = 4,
	}
	testing.expect(t, playtest.drawn(rig, "RUIN   wave 2 of 5   7 creatures left"))
	view(rig.s).ruin = {
		phase = .Break,
		wave  = 2,
		waves = 5,
		left  = 6,
	}
	testing.expect(t, playtest.drawn(rig, "RUIN   wave 2 of 5 held   the next in 6 s"))
}
