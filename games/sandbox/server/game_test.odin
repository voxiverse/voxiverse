package sandbox_server

import "core:testing"

import "common:game"
import "common:worldgen"
import "server:core"

// The sandbox on a stepped server with the local player: the world it chooses (the Earth
// generator, whatever the harness asked for), and the player plays it.
@(test)
test_sandbox_world :: proc(t: ^testing.T) {
	sess := new(core.Session)
	defer free(sess)
	config := core.harness_world() // (a flat world, which the sandbox does not play)
	config.game = GAME
	config.kit = "" // (the game's to choose, as a world of its own leaves it)
	if !testing.expect(t, core.session_start(sess, {}, false, with = config)) {return}
	defer core.session_stop(sess)
	srv := &sess.h.srv
	testing.expect_value(t, srv.config.game.id, "sandbox")
	testing.expect_value(t, srv.config.generator, worldgen.Kind.Earth)
	testing.expect_value(t, srv.home.generator, worldgen.Kind.Earth)
	testing.expect_value(t, srv.config.kit, KIT)
	welcomed :: proc(data: rawptr) -> bool {return (^core.Session)(data).mirror.welcomed}
	_, ok := core.harness_step_until(&sess.h, welcomed, sess, 600)
	testing.expect(t, ok, "the player never joined")
	testing.expect_value(t, len(sess.failures), 0)
}

// A new sandbox universe's home world, made from the seed or Earth itself, has a dead gate
// standing in front of the spawn (its ring a few blocks north, where a newcomer looks).
@(test)
test_sandbox_home_gate_dead_at_spawn :: proc(t: ^testing.T) {
	for earth in ([]bool{false, true}) {
		h := new(core.Harness)
		defer free(h)
		config := core.Config {
			game        = GAME,
			seed        = 33,
			earth       = earth,
			view_radius = 2,
			view_height = 1,
			max_players = 1,
			rules       = game.rules_still(),
		}
		if !testing.expect(t, core.harness_start(h, config)) {continue}
		defer core.harness_stop(h)
		w := h.srv.home
		home, has_home := w.chunks.gen.home.?
		if !testing.expectf(t, has_home, "earth %v: no home gate", earth) {continue}
		testing.expectf(
			t,
			len(w.gates) == 1 && w.gates[0].phase == .Dead && w.gates[0].structure == home,
			"earth %v: the home gate is not dead: %v",
			earth,
			w.gates[:],
		)
		front, _ := worldgen.gate_front(home)
		ahead := w.spawn.position.z - front.z
		testing.expectf(
			t,
			abs(w.spawn.position.x - front.x) < 1 && ahead > 0 && ahead < 16,
			"earth %v: the home gate's front %v, the spawn %v",
			earth,
			front,
			w.spawn.position,
		)
	}
}
