package server

import "core:testing"
import "core:time"

import "../common/game"
import "../common/netcode"
import "../common/worldgen"

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
	srv: Server
	config := harness_world()
	config.net = &net
	config.workers = 0
	// Not stepped.
	testing.expect(t, !start(&srv, config, {}), "a simulated network without stepped was taken")
	// With conditions of its own.
	config.stepped = true
	config.conditions = {
		loss = 0.1,
	}
	testing.expect(t, !start(&srv, config, {}), "a simulated network with conditions was taken")
}

@(private = "file")
Bot :: struct {
	t: ^testing.T,
	c: Net_Client,
}

@(private = "file")
bot_tick :: proc(data: rawptr) {
	b := (^Bot)(data)
	net_pump(b.t, &b.c)
}

@(private = "file")
Replay :: struct {
	roots:     [dynamic]u64,
	delivered: int,
	chunks:    [2]int, // held at the end
	wrong:     int, // blocks held that are not the flat world's
}

// replay_run: two players join over a lossy network, get their world, walk a
// fixed script; the root of every tick is recorded.
@(private = "file")
replay_run :: proc(t: ^testing.T, seed: u64, out: ^Replay) -> bool {
	h: Harness
	config := harness_world()
	config.listen = true
	conditions := netcode.Conditions {
		loss       = 0.1,
		duplicate  = 0.1,
		latency_ms = 50,
		jitter_ms  = 30,
		seed       = seed,
	}
	if !testing.expect(t, harness_start(&h, config, conditions = conditions)) {return false}
	defer harness_stop(&h)
	bots: [2]Bot
	names := [2]string{"alice", "bob"}
	for &b, i in bots {
		b.t = t
		net_connect(&b.c, h.srv.host.socket.port, names[i], sim = &h.net)
		harness_add(&h, bot_tick, &b)
	}
	defer for &b in bots {net_close(&b.c)}
	_, ok := harness_step_until(&h, proc(data: rawptr) -> bool {
			bs := (^[2]Bot)(data)
			for &b in bs {
				if !(b.c.welcomed &&
					   b.c.update.state.on_ground &&
					   len(b.c.chunks) >= HARNESS_INTEREST) {
					return false
				}
			}
			return true
		}, &bots, 600)
	if !testing.expect(t, ok, "the players did not get their world in 600 ticks") {return false}
	for i in 0 ..< 300 {
		for &b, k in bots {
			b.c.move = {0, 1} if (i / 50 + k) % 2 == 0 else {1, 0}
			b.c.look = {f32(i) / 100, 0}
		}
		harness_step(&h)
		append(&out.roots, h.last.root)
	}
	harness_step(&h, 60) // standing: what is in flight arrives
	for &b in bots {
		b.c.move = {}
	}
	harness_step(&h, 120)
	out.delivered = h.net.delivered
	for &b, i in bots {
		out.chunks[i] = len(b.c.chunks)
		for pos, &blocks in b.c.chunks {
			for k in 0 ..< game.CHUNK_VOLUME {
				l := game.local_from_index(k)
				if game.chunk_get(&blocks, l) !=
				   worldgen.flat_block(pos.y * game.CHUNK_SIZE + l.y) {
					out.wrong += 1
				}
			}
		}
	}
	return true
}

@(private = "file")
replay_free :: proc(r: ^Replay) {
	delete(r.roots)
}

// Two players through loss, duplication, delay and reordering: the same seed
// gives the same run, tick for tick; another seed loses other packets and the
// reliability layer still gives both players the same chunks.
@(test)
test_two_players_through_loss_replay :: proc(t: ^testing.T) {
	a, b, c: Replay
	defer {replay_free(&a); replay_free(&b); replay_free(&c)}
	if !replay_run(t, 66, &a) {return}
	if !replay_run(t, 66, &b) {return}
	if !replay_run(t, 67, &c) {return}
	testing.expect_value(t, len(a.roots), len(b.roots))
	for i in 0 ..< min(len(a.roots), len(b.roots)) {
		if a.roots[i] != b.roots[i] {
			testing.expectf(t, false, "the same seed diverged at tick %d of the walk", i)
			break
		}
	}
	testing.expect_value(t, a.delivered, b.delivered)
	testing.expect(t, a.delivered != c.delivered, "another seed lost the same packets")
	// Whatever was lost on the way, the reliability layer delivered every chunk, whole.
	for r in ([]^Replay{&a, &c}) {
		testing.expect_value(t, r.wrong, 0)
		for held in r.chunks {testing.expectf(t, held >= HARNESS_INTEREST, "holds %d chunks", held)}
	}
}
