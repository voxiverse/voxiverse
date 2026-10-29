package netcode

import "core:encoding/endian"
import "core:net"
import "core:slice"
import "core:testing"
import "core:time"

// The host and the link run over a Simnet stepped by the test (T4b): no
// socket, no thread, no wall clock. The real-UDP round trips are in smoke/.
@(private = "file")
loopback :: proc(port: int) -> net.Endpoint {
	return {net.IP4_Loopback, port}
}

@(private = "file")
STEP :: 5 * time.Millisecond

// pump steps both ends (5 ms of the network's time a step), collecting what
// the host saw and what the link received.
@(private = "file")
Seen :: struct {
	connected:    [dynamic]Peer_Id,
	disconnected: [dynamic]Peer_Disconnected,
	at_host:      [dynamic][]u8, // copies
	at_link:      [dynamic][]u8, // owned by the test (freed with link_free semantics: plain delete)
}

@(private = "file")
seen_destroy :: proc(s: ^Seen) {
	delete(s.connected)
	delete(s.disconnected)
	for m in s.at_host {delete(m)}
	for m in s.at_link {delete(m)}
	delete(s.at_host)
	delete(s.at_link)
}

@(private = "file")
pump :: proc(
	n: ^Simnet,
	h: ^Host,
	links: []^Link,
	s: ^Seen,
	until: proc(s: ^Seen, links: []^Link) -> bool,
	seconds: f64 = 10,
) -> bool {
	steps := int(seconds * f64(time.Second) / f64(STEP))
	for _ in 0 ..< steps {
		n.now = time.tick_add(n.now, STEP)
		now := n.now
		for l in links {link_update(l, now)}
		host_update(h, now)
		for e in h.events {
			switch v in e {
			case Peer_Connected:
				append(&s.connected, v.peer)
			case Peer_Message:
				append(&s.at_host, slice.clone(v.data))
			case Peer_Disconnected:
				append(&s.disconnected, v)
			}
		}
		for l in links {
			if l.state == .Connected {link_receive(l, &s.at_link)}
		}
		if until(s, links) {return true}
		host_flush(h, now)
		for l in links {link_flush(l, now)}
	}
	return false
}

@(test)
test_connect_talk_and_leave :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n)
	defer simnet_destroy(&n)
	h: Host
	if !testing.expect(t, host_open(&h, 0, 4, sim = &n) == nil) {return}
	defer host_close(&h, "bye")
	l: Link
	testing.expect(t, link_connect(&l, loopback(h.socket.port), "", n.now, sim = &n) == nil)
	s: Seen
	defer seen_destroy(&s)
	ok := pump(&n, &h, {&l}, &s, proc(s: ^Seen, links: []^Link) -> bool {
		return len(s.connected) == 1 && links[0].state == .Connected
	})
	if !testing.expect(t, ok, "never connected") {
		link_close(&l, "")
		return
	}
	id := s.connected[0]
	link_send(&l, transmute([]u8)string("hello server"), true)
	host_send(&h, id, transmute([]u8)string("hello client"), true)
	ok = pump(&n, &h, {&l}, &s, proc(s: ^Seen, links: []^Link) -> bool {
		return len(s.at_host) == 1 && len(s.at_link) == 1
	})
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, string(s.at_host[0]), "hello server")
		testing.expect_value(t, string(s.at_link[0]), "hello client")
	}
	// Goodbye: the host hears of it at once (not by timing out).
	link_close(&l, "leaving")
	ok = pump(
		&n,
		&h,
		{},
		&s,
		proc(s: ^Seen, links: []^Link) -> bool {return len(s.disconnected) == 1},
	)
	testing.expect(t, ok && s.disconnected[0] == Peer_Disconnected{id, .Left})
}

@(test)
test_password_and_full_server :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n)
	defer simnet_destroy(&n)
	h: Host
	if !testing.expect(t, host_open(&h, 0, 1, password = "hunter2", sim = &n) == nil) {return}
	defer host_close(&h, "bye")
	wrong, right, extra: Link
	link_connect(&wrong, loopback(h.socket.port), "hunter3", n.now, sim = &n)
	link_connect(&right, loopback(h.socket.port), "hunter2", n.now, sim = &n)
	defer link_close(&wrong, "")
	defer link_close(&right, "")
	s: Seen
	defer seen_destroy(&s)
	pump(&n, &h, {&wrong, &right}, &s, proc(s: ^Seen, links: []^Link) -> bool {
		return links[0].state == .Failed && links[1].state == .Connected
	})
	testing.expect_value(t, wrong.reason, "wrong password")
	testing.expect_value(t, right.state, Link_State.Connected)
	// One seat, taken.
	link_connect(&extra, loopback(h.socket.port), "hunter2", n.now, sim = &n)
	defer link_close(&extra, "")
	pump(
		&n,
		&h,
		{&extra, &right},
		&s,
		proc(s: ^Seen, links: []^Link) -> bool {return links[0].state == .Failed},
	)
	testing.expect_value(t, extra.reason, "the server is full")
	testing.expect_value(t, len(s.connected), 1)
}

// settle: 40 ms of the network's time, the host and the raw socket stepped.
@(private = "file")
settle :: proc(n: ^Simnet, h: ^Host, sock: ^Socket) {
	for _ in 0 ..< 8 {
		n.now = time.tick_add(n.now, STEP)
		host_update(h, n.now)
		host_flush(h, n.now)
		socket_pump(sock, n.now)
	}
}

// A Response with a made-up cookie gets nothing: no peer, no answer.
@(test)
test_forged_cookie_refused :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n)
	defer simnet_destroy(&n)
	h: Host
	if !testing.expect(t, host_open(&h, 0, 4, sim = &n) == nil) {return}
	defer host_close(&h, "bye")
	sock: Socket
	socket_open(&sock, 0, sim = &n)
	defer socket_close(&sock)
	buf: [64]u8
	w := writer(buf[:])
	put_u32(&w, MAGIC)
	put_u8(&w, u8(Packet_Kind.Response))
	put_u64(&w, 42)
	w.n += 2 * COOKIE_SIZE // zero cookie, zero proof
	socket_send(&sock, loopback(h.socket.port), buf[:w.n], n.now)
	settle(&n, &h, &sock)
	testing.expect_value(t, len(h.events), 0)
	_, _, answered := socket_receive(&sock)
	testing.expect(t, !answered, "the server answered a forged response")
	// A short Connect (not padded) gets no Challenge either.
	w = writer(buf[:])
	put_u32(&w, MAGIC)
	put_u8(&w, u8(Packet_Kind.Connect))
	put_u64(&w, 7)
	socket_send(&sock, loopback(h.socket.port), buf[:w.n], n.now)
	settle(&n, &h, &sock)
	_, _, answered = socket_receive(&sock)
	testing.expect(t, !answered, "an unpadded connect was answered")
}

// Both directions through 10% loss, 10% duplication and jitter, on a
// simulated network: everything reliable arrives, intact and in order.
@(private = "file", rodata)
SIZES := [4]int{8, 700, 3000, 40_000}

@(test)
test_bad_network_through_host_and_link :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n)
	defer simnet_destroy(&n)
	h: Host
	if !testing.expect(t, host_open(&h, 0, 4, sim = &n) == nil) {return}
	defer host_close(&h, "bye")
	bad := Conditions {
		loss       = 0.1,
		duplicate  = 0.1,
		latency_ms = 20,
		jitter_ms  = 30,
	}
	simnet_set_conditions(&n, bad)
	l: Link
	link_connect(&l, loopback(h.socket.port), "", n.now, sim = &n)
	defer link_close(&l, "")
	s: Seen
	defer seen_destroy(&s)
	ok := pump(&n, &h, {&l}, &s, proc(s: ^Seen, links: []^Link) -> bool {
		return len(s.connected) == 1 && links[0].state == .Connected
	})
	if !testing.expect(t, ok, "never connected") {return}
	COUNT :: 150
	for i in 0 ..< COUNT {
		size := SIZES[i % 4]
		m := make([]u8, size)
		endian.put_u32(m, .Little, u32(i))
		for j in 4 ..< size {m[j] = u8(i + j)}
		link_send(&l, m, true)
		host_send(&h, s.connected[0], m, true)
		delete(m)
	}
	ok = pump(&n, &h, {&l}, &s, proc(s: ^Seen, links: []^Link) -> bool {
			return len(s.at_host) == COUNT && len(s.at_link) == COUNT
		}, 30)
	testing.expectf(t, ok, "host got %d, link got %d of %d", len(s.at_host), len(s.at_link), COUNT)
	for side in ([][dynamic][]u8{s.at_host, s.at_link}) {
		for m, i in side {
			size := SIZES[i % 4]
			good := len(m) == size && endian.unchecked_get_u32le(m) == u32(i)
			for j in 4 ..< min(len(m), size) {if m[j] != u8(i + j) {good = false}}
			if !testing.expectf(t, good, "message %d damaged or out of order", i) {break}
		}
	}
}

@(test)
test_lan_discovery :: proc(t: ^testing.T) {
	n: Simnet
	simnet_init(&n)
	defer simnet_destroy(&n)
	h: Host
	port := DEFAULT_PORT + DISCOVERY_PORTS - 1 // the last one looked at
	if err := host_open(&h, port, 4, sim = &n); err != nil {
		testing.expectf(t, false, "port %d busy: %v", port, err)
		return
	}
	defer host_close(&h, "bye")
	host_set_info(&h, transmute([]u8)string("Test World"))
	d: Discovery
	if !testing.expect(t, discovery_open(&d, sim = &n) == nil) {return}
	defer discovery_close(&d)
	for _ in 0 ..< 600 { 	// 3 s of the network's time
		if len(d.found) > 0 {break}
		n.now = time.tick_add(n.now, STEP)
		discovery_update(&d, n.now)
		host_update(&h, n.now)
		host_flush(&h, n.now)
	}
	if testing.expect(t, len(d.found) == 1, "no server found on the LAN") {
		testing.expect_value(t, string(d.found[0].info), "Test World")
		testing.expect_value(t, d.found[0].address.port, port)
	}
}
