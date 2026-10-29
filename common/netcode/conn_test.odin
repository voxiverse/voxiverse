package netcode

import "core:encoding/endian"
import "core:math/rand"
import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

// A simulated link between two connections: two sockets on one simulated
// network (simnet.odin), stepped 5 ms at a time. Each packet may be lost,
// duplicated or delayed (which reorders), from a seed: the same every run.
@(private = "file")
Wire :: struct {
	net:        Simnet,
	socks:      [2]Socket,
	step:       int,
	base:       time.Tick,
	buffer:     [dynamic]u8,
	packets:    [dynamic][]u8,
	sent_bytes: [2]int,
}

@(private = "file")
STEP :: 5 * time.Millisecond

@(private = "file")
wire_init :: proc(w: ^Wire, c: Conditions) {
	simnet_init(&w.net, c)
	w.base = w.net.now
	for &s in w.socks {socket_open(&s, 0, sim = &w.net)}
}

@(private = "file")
wire_now :: proc(w: ^Wire) -> time.Tick {
	return time.tick_add(w.base, time.Duration(w.step) * STEP)
}

@(private = "file")
wire_address :: proc(w: ^Wire, i: int) -> net.Endpoint {
	return {net.IP4_Loopback, w.socks[i].port}
}

// wire_step: both sides flush; the network carries what they sent; what is
// due arrives.
@(private = "file")
wire_step :: proc(w: ^Wire, conns: [2]^Conn) {
	now := wire_now(w)
	w.net.now = now
	for c, from in conns {
		conn_flush(c, now, &w.buffer, &w.packets)
		for p in w.packets {
			w.sent_bytes[from] += len(p)
			socket_send(&w.socks[from], wire_address(w, 1 - from), p, now)
		}
	}
	w.step += 1
	now = wire_now(w)
	w.net.now = now
	for &s in w.socks {socket_pump(&s, now)}
	for &s, to in w.socks {
		for {
			data, _, ok := socket_receive(&s)
			if !ok {break}
			conn_packet(conns[to], data, now)
		}
	}
}

@(private = "file")
wire_destroy :: proc(w: ^Wire) {
	for &s in w.socks {socket_close(&s)}
	simnet_destroy(&w.net)
	delete(w.buffer)
	delete(w.packets)
}

@(private = "file")
message :: proc(n: int, size: int) -> []u8 {
	b := make([]u8, size)
	endian.put_u32(b, .Little, u32(n))
	for i in 4 ..< size {b[i] = u8(n * 31 + i)}
	return b
}

// Reliable messages of every size, both ways, through 10% loss, 10%
// duplication and reordering: each arrives exactly once, in order, intact.
@(test)
test_reliable_through_a_bad_link :: proc(t: ^testing.T) {
	w: Wire
	wire_init(&w, {loss = 0.1, duplicate = 0.1, latency_ms = 10, jitter_ms = 50, seed = 77})
	defer wire_destroy(&w)
	a, b: Conn
	conn_init(&a, 77, w.base)
	conn_init(&b, 77, w.base)
	defer conn_destroy(&a)
	defer conn_destroy(&b)
	sizes := []int{4, 50, 1000, FRAGMENT_SIZE, FRAGMENT_SIZE + 1, 5000, 30_000}
	COUNT :: 300
	for i in 0 ..< COUNT {
		m := message(i, sizes[i % len(sizes)])
		conn_send(&a, m, true)
		if i % 3 == 0 {conn_send(&b, m, true)}
		delete(m)
	}
	got: [2][dynamic][]u8
	defer for g in got {for m in g {delete(m)}; delete(g)}
	for _ in 0 ..< 20_000 {
		wire_step(&w, {&a, &b})
		conn_receive(&b, &got[0]) // a -> b
		conn_receive(&a, &got[1])
		if len(got[0]) == COUNT && len(got[1]) == COUNT / 3 {break}
	}
	testing.expect_value(t, len(got[0]), COUNT)
	testing.expect_value(t, len(got[1]), COUNT / 3)
	for m, i in got[0] {
		want := message(i, sizes[i % len(sizes)])
		defer delete(want)
		if !testing.expectf(
			t,
			slice.equal(m, want),
			"message %d differs (or out of order)",
			i,
		) {break}
	}
	for m, k in got[1] {
		i := 3 * k
		want := message(i, sizes[i % len(sizes)])
		defer delete(want)
		if !testing.expectf(t, slice.equal(m, want), "reply %d differs", k) {break}
	}
	// Run on a little: everything acknowledged, nothing left to resend.
	for _ in 0 ..< 200 {wire_step(&w, {&a, &b})}
	testing.expect_value(t, conn_backlog(&a), 0)
	testing.expect_value(t, len(a.out), 0)
}

// Unreliable messages: some are lost, none arrive twice, and never an older
// one after a newer one.
@(test)
test_unreliable_latest_wins :: proc(t: ^testing.T) {
	w: Wire
	wire_init(&w, {loss = 0.1, duplicate = 0.2, latency_ms = 5, jitter_ms = 45, seed = 5})
	defer wire_destroy(&w)
	a, b: Conn
	conn_init(&a, 5, w.base)
	conn_init(&b, 5, w.base)
	defer conn_destroy(&a)
	defer conn_destroy(&b)
	got: [dynamic][]u8
	defer delete(got)
	last := -1
	arrived := 0
	for i in 0 ..< 2000 {
		m := message(i, 20)
		conn_send(&a, m, false)
		delete(m)
		wire_step(&w, {&a, &b})
		conn_receive(&b, &got)
		for g in got {
			n := int(endian.unchecked_get_u32le(g))
			testing.expectf(t, n > last, "%d after %d", n, last)
			last = n
			arrived += 1
			conn_free(&b, g)
		}
		clear(&got)
	}
	// Late ones are dropped as stale, so with this much reordering about half arrive.
	testing.expectf(t, arrived > 600 && arrived < 2000, "%d of 2000 arrived", arrived)
}

// A big burst on a clean link is acknowledged as a whole: hardly anything
// is sent twice, even though the packet acks cover only 33 packets.
@(test)
test_burst_is_acknowledged :: proc(t: ^testing.T) {
	w: Wire
	wire_init(&w, {latency_ms = 20}) // one way
	defer wire_destroy(&w)
	a, b: Conn
	conn_init(&a, 9, w.base)
	conn_init(&b, 9, w.base)
	defer conn_destroy(&a)
	defer conn_destroy(&b)
	m := message(1, 60_000)
	defer delete(m)
	for _ in 0 ..< 10 {conn_send(&a, m, true)} 	// 600 KB at once
	got: [dynamic][]u8
	defer {for g in got {delete(g)}; delete(got)}
	for _ in 0 ..< 2000 {
		wire_step(&w, {&a, &b})
		conn_receive(&b, &got)
		if len(got) == 10 && conn_backlog(&a) == 0 {break}
	}
	testing.expect_value(t, len(got), 10)
	testing.expectf(
		t,
		a.stats.resent < a.stats.packets_sent / 50,
		"resent %d of %d",
		a.stats.resent,
		a.stats.packets_sent,
	)
	// The rate was kept: 600 KB at 2 MiB/s takes about 0.3 s.
	seconds := f32(w.step) * f32(time.duration_seconds(STEP))
	testing.expectf(t, seconds > 0.25, "600 KB in %.2f s: faster than the rate", seconds)
}

// Garbage, truncated and forged packets are refused without harm.
@(test)
test_bad_packets_refused :: proc(t: ^testing.T) {
	now := time.tick_now()
	a, b: Conn
	conn_init(&a, 1234, now)
	conn_init(&b, 1234, now)
	defer conn_destroy(&a)
	defer conn_destroy(&b)
	m := message(3, 3000)
	defer delete(m)
	conn_send(&a, m, true)
	buffer: [dynamic]u8
	packets: [dynamic][]u8
	defer delete(buffer)
	defer delete(packets)
	conn_flush(&a, now, &buffer, &packets)
	testing.expect(t, len(packets) == 3)
	good := slice.clone(packets[0])
	defer delete(good)
	for n in 0 ..< DATA_HEADER {
		testing.expectf(t, !conn_packet(&b, good[:n], now), "%d-byte prefix accepted", n)
	}
	forged := slice.clone(good)
	defer delete(forged)
	forged[5] ~= 1 // the token
	testing.expect(t, !conn_packet(&b, forged, now))
	noise := make([]u8, MTU)
	defer delete(noise)
	for _ in 0 ..< 2000 {
		for &x in noise {x = u8(rand.uint32())}
		n := rand.int_max(MTU)
		endian.put_u32(noise, .Little, MAGIC)
		noise[4] = u8(Packet_Kind.Data)
		endian.put_u32(noise[5:], .Little, 1234)
		conn_packet(&b, noise[:max(n, 9)], now) // must not crash or deliver nonsense
	}
	got: [dynamic][]u8
	defer {for g in got {delete(g)}; delete(got)}
	conn_receive(&b, &got)
	for g in got {testing.expect(t, len(g) <= MAX_MESSAGE)}
}
