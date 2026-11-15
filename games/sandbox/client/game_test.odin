package sandbox_client

import "core:testing"

import "client:engine"
import "client:testkit"
import "common:game"
import sandbox_server "games:sandbox/server"
import "server:core"

// The sandbox played whole: its server part on a stepped server and a session that joins
// it over the harness's network with this client part, playing it.

Rig :: struct {
	h:     core.Harness,
	s:     ^engine.Session,
	input: engine.Input_State,
	idle:  engine.Actions,
}

rig_frame :: proc(data: rawptr) {
	r := (^Rig)(data)
	engine.session_update(
		r.s,
		&r.input,
		&r.idle,
		engine.SETTINGS_DEFAULTS,
		{},
		game.TICK_SECONDS,
		true,
	)
}

@(test)
test_sandbox_joined :: proc(t: ^testing.T) {
	rig := new(Rig) // (the heap: a Harness is large, a test thread's stack is not)
	defer free(rig)
	config := core.Config {
		seed              = 33,
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		no_natural_spawns = true,
		rules             = engine.still_rules(),
		game              = sandbox_server.GAME,
	}
	if !testing.expect(t, core.harness_start(&rig.h, config)) {return}
	defer core.harness_stop(&rig.h)
	rig.s = new(engine.Session)
	defer free(rig.s)
	s := rig.s
	key: game.Account_Key
	game.account_key_set(&key, {0 ..< 32 = 4})
	engine.session_start(
		s,
		{
			name = "builder",
			key = key,
			join = engine.Join{address = core.harness_address(&rig.h)},
			view_radius = 3,
			view_height = 2,
			registry = testkit.test_reg(),
			net = &rig.h.net,
			games = {GAME},
		},
	)
	defer engine.session_end(s, nil, nil)
	core.harness_add(&rig.h, rig_frame, rig)
	core.harness_step_until(&rig.h, proc(data: rawptr) -> bool {
			return (^Rig)(data).s.state == .Playing
		}, rig, 3000)
	if !testing.expect_value(t, s.state, engine.Session_State.Playing) {return}
	testing.expect_value(t, s.game.id, "sandbox")
	testing.expect_value(t, s.welcome.game, "sandbox")
	testing.expect_value(t, engine.game_debug_line(s), "")
}
