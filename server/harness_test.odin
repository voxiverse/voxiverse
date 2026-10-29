package server

import "core:testing"
import "core:time"

import "../common/game"
import "../common/netcode"

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
test_step_until_counts_ticks :: proc(t: ^testing.T) {
	h: Harness
	if !testing.expect(t, harness_start(&h, harness_world())) {return}
	defer harness_stop(&h)
	at_ten :: proc(data: rawptr) -> bool {return (^Harness)(data).srv.tick == 10}
	ticks, ok := harness_step_until(&h, at_ten, &h, 50)
	testing.expect(t, ok)
	testing.expect_value(t, ticks, 10)
	testing.expect_value(t, harness_ticks(&h), 10)
	never :: proc(data: rawptr) -> bool {return false}
	ticks, ok = harness_step_until(&h, never, &h, 50)
	testing.expect(t, !ok)
	testing.expect_value(t, ticks, 50)
	testing.expect_value(t, harness_ticks(&h), 60)
	harness_step(&h, 7)
	testing.expect_value(t, harness_ticks(&h), 67)
	testing.expect_value(t, harness_now(&h), netcode.simnet_tick_time(67, game.TICK_RATE))
}

@(private = "file")
Turn :: struct {
	h:     ^Harness,
	name:  int, // which party
	order: ^[dynamic]int,
	ticks: [dynamic]u64, // the server's tick at each call of party 0
	times: [dynamic]time.Tick,
}

@(test)
test_parties_run_before_the_tick :: proc(t: ^testing.T) {
	h: Harness
	if !testing.expect(t, harness_start(&h, harness_world())) {return}
	defer harness_stop(&h)
	order: [dynamic]int
	defer delete(order)
	one := Turn {
		h     = &h,
		name  = 1,
		order = &order,
	}
	two := Turn {
		h     = &h,
		name  = 2,
		order = &order,
	}
	defer delete(one.ticks)
	defer delete(one.times)
	record :: proc(data: rawptr) {
		p := (^Turn)(data)
		append(p.order, p.name)
		if p.name == 1 {
			append(&p.ticks, p.h.srv.tick)
			append(&p.times, harness_now(p.h))
		}
	}
	harness_add(&h, record, &one)
	harness_add(&h, record, &two)
	harness_step(&h, 5)
	testing.expect_value(t, len(one.ticks), 5)
	for k in 1 ..= len(one.ticks) {
		testing.expect_value(t, one.ticks[k - 1], u64(k - 1))
		testing.expect_value(t, one.times[k - 1], netcode.simnet_tick_time(u64(k), game.TICK_RATE))
	}
	for v, i in order {testing.expect_value(t, v, 1 + i % 2)}
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
