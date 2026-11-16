package sandbox_server

import "core:testing"

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
