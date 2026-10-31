package server

import "core:testing"

import "common:netcode"

@(private = "file")
HARNESS_INTEREST :: 39 // the chunks a player holds in the harness world: 13 columns, 3 high

// The fixed world is still: nobody to spawn, no random tick, no daylight, so
// what a test sees is what the test did.
@(test)
test_harness_world_is_still :: proc(t: ^testing.T) {
	sess: Session
	defer session_stop(&sess)
	if !testing.expect(t, session_start(&sess, {}, false, with = harness_world())) {return}
	_, landed := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			m := &(^Session)(data).mirror
			s := m.last_update.state
			return s.on_ground && m.last_update.acked > 0 && m.prediction.state == s
		}, &sess, 300)
	if !testing.expect(t, landed, "the player never landed") {return}
	m := &sess.mirror
	testing.expect_value(t, m.last_update.state.position.y, 0)
	clock := sess.h.srv.home.clock
	for i in 0 ..< 600 {
		session_step(&sess, false)
		if sess.h.srv.home.clock != clock {
			testing.expectf(t, false, "the clock moved at step %d", i)
			break
		}
	}
	// The world is whole (39 chunks: 13 columns of the radius 2, three high) and does not change.
	testing.expect_value(t, len(m.chunks), HARNESS_INTEREST)
	world := world_hash(&sess.h.srv)
	for _ in 0 ..< 60 {session_step(&sess, false)}
	testing.expect_value(t, len(sess.h.srv.home.entities.list), 0)
	testing.expect_value(t, world_hash(&sess.h.srv), world)
	testing.expect_value(t, sess.h.srv.home.clock, clock)
	testing.expect(t, chunks_agree(&sess), "the mirror's chunks differ from the server's")
	for f in sess.failures {testing.expect(t, false, f)}
}

@(test)
test_harness_refusals :: proc(t: ^testing.T) {
	net: netcode.Simnet
	netcode.simnet_init(&net)
	defer netcode.simnet_destroy(&net)
	config := harness_world()
	config.net = &net
	config.workers = 0
	// Not stepped.
	testing.expect(t, harness_refused(config), "a simulated network without stepped was taken")
	// With conditions of its own.
	config.stepped = true
	config.conditions = {
		loss = 0.1,
	}
	testing.expect(t, harness_refused(config), "a simulated network with conditions was taken")
}
