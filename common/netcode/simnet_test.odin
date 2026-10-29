package netcode

import "core:net"
import "core:testing"
import "core:time"

@(private = "file")
Arrival :: struct {
	tick: int,
	port: int,
	num:  u16,
}

// One run of the transport test: 2000 numbered packets each way, one tick's
// time apart, received every tick (and 100 ticks more for the stragglers).
@(private = "file")
loss_run :: proc(n: ^Simnet, seed: u64) -> (arrivals: [dynamic]Arrival) {
	simnet_init(n, {loss = 0.2, duplicate = 0.1, latency_ms = 40, jitter_ms = 60, seed = seed})
	a, b: Socket
	socket_open(&a, 0, sim = n)
	socket_open(&b, 0, sim = n)
	defer socket_close(&a)
	defer socket_close(&b)
	socks := [2]^Socket{&a, &b}
	for tick in 0 ..< 2100 {
		now := simnet_tick_time(u64(tick), 30)
		n.now = now
		if tick < 2000 {
			for s, i in socks {
				p := [2]u8{u8(tick), u8(tick >> 8)}
				socket_send(s, {net.IP4_Loopback, socks[1 - i].port}, p[:], now)
			}
		}
		for s in socks {
			socket_pump(s, now)
			for {
				data, _, ok := socket_receive(s)
				if !ok {break}
				append(&arrivals, Arrival{tick, s.port, u16(data[0]) | u16(data[1]) << 8})
			}
		}
	}
	return
}

// The same seed gives the same losses, duplicates and reordering at the same
// ticks; another seed gives others; the conditions really applied.
@(test)
test_simnet_same_seed_same_losses :: proc(t: ^testing.T) {
	n1, n2, n3: Simnet
	r1 := loss_run(&n1, 7)
	r2 := loss_run(&n2, 7)
	r3 := loss_run(&n3, 8)
	defer {
		delete(r1)
		delete(r2)
		delete(r3)
		simnet_destroy(&n1)
		simnet_destroy(&n2)
		simnet_destroy(&n3)
	}
	same := len(r1) == len(r2)
	for i in 0 ..< min(len(r1), len(r2)) {
		if r1[i] != r2[i] {same = false; break}
	}
	testing.expect(t, same, "the same seed gave different arrivals")
	differs := len(r1) != len(r3)
	for i in 0 ..< min(len(r1), len(r3)) {
		if r1[i] != r3[i] {differs = true; break}
	}
	testing.expect(t, differs, "another seed gave the same arrivals")

	counts: map[[2]int]int // (port, number) -> arrivals
	defer delete(counts)
	reordered := 0
	last: map[int]int
	defer delete(last)
	for a in r1 {
		counts[{a.port, int(a.num)}] += 1
		if prev, ok := last[a.port]; ok && int(a.num) < prev {reordered += 1}
		last[a.port] = max(last[a.port], int(a.num))
	}
	lost, twice := 0, 0
	for port in ([2]int{SIM_FIRST_PORT, SIM_FIRST_PORT + 1}) {
		for num in 0 ..< 2000 {
			switch counts[{port, num}] {
			case 0:
				lost += 1
			case 2:
				twice += 1
			}
		}
	}
	testing.expectf(t, lost > 400, "lost %d of 4000", lost)
	testing.expectf(t, twice > 200, "%d came twice", twice)
	testing.expectf(t, reordered > 100, "%d arrived out of order", reordered)
	testing.expect_value(t, n1.delivered, len(r1))
	testing.expect_value(t, n1.unbound, 0)
	testing.expect_value(t, n1.overflowed, 0)
	// sent counts datagrams handed to the network once the delay is up: every copy.
	testing.expect_value(t, n1.sent, n1.delivered)
}

@(test)
test_simnet_clean_delivery :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n)
	defer simnet_destroy(&n)
	testing.expect(t, n.conditions.seed != 0, "a simulated network is never seeded from the clock")
	a, b: Socket
	testing.expect(t, socket_open(&a, 0, sim = &n) == nil)
	testing.expect(t, socket_open(&b, 0, sim = &n) == nil)
	defer socket_close(&a)
	defer socket_close(&b)
	testing.expect_value(t, a.port, SIM_FIRST_PORT)
	testing.expect_value(t, b.port, SIM_FIRST_PORT + 1)
	dup: Socket
	testing.expect(t, socket_open(&dup, b.port, sim = &n) != nil, "a held port was bound twice")
	to_b := net.Endpoint{net.IP4_Loopback, b.port}
	for i in 0 ..< 50 {
		p := [1]u8{u8(i)}
		socket_send(&a, to_b, p[:], n.now)
	}
	for i in 0 ..< 50 {
		data, from, ok := socket_receive(&b)
		testing.expect(t, ok && len(data) == 1 && data[0] == u8(i))
		testing.expect_value(t, from.port, a.port)
	}
	_, _, ok := socket_receive(&b)
	testing.expect(t, !ok)
	// Nobody there.
	p := [1]u8{1}
	socket_send(&a, {net.IP4_Loopback, 1234}, p[:], n.now)
	testing.expect_value(t, n.unbound, 1)
	// A full inbox drops the rest.
	for _ in 0 ..< SIM_INBOX_MAX + 10 {socket_send(&a, to_b, p[:], n.now)}
	testing.expect_value(t, n.overflowed, 10)
	// What nobody received is freed by simnet_destroy (the suite's memory check).
}

@(test)
test_simnet_clock_only :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n, {latency_ms = 50})
	defer simnet_destroy(&n)
	a, b: Socket
	socket_open(&a, 0, sim = &n)
	socket_open(&b, 0, sim = &n)
	defer socket_close(&a)
	defer socket_close(&b)
	p := [1]u8{9}
	socket_send(&a, {net.IP4_Loopback, b.port}, p[:], n.now)
	for _ in 0 ..< 1000 {
		socket_pump(&a, n.now) // the OS clock goes on; the network's does not
		_, _, ok := socket_receive(&b)
		testing.expect(t, !ok)
	}
	n.now = time.tick_add(n.now, 49 * time.Millisecond)
	socket_pump(&a, n.now)
	_, _, early := socket_receive(&b)
	testing.expect(t, !early)
	n.now = time.tick_add(n.now, 2 * time.Millisecond)
	socket_pump(&a, n.now)
	_, _, late := socket_receive(&b)
	testing.expect(t, late)
}

@(test)
test_simnet_tick_time :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		time.tick_diff(simnet_tick_time(0, 30), simnet_tick_time(30, 30)),
		time.Second,
	)
	testing.expect_value(t, simnet_tick_time(0, 30)._nsec, SIM_EPOCH_NS)
}
