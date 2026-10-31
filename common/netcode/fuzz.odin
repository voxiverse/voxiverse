package netcode

import "base:runtime"
import "core:net"
import "core:time"

import "common:base"
import "common:base/fuzz"

// The fuzz targets of the packet layer and the host's first datagrams (Q2, docs/fuzzing.md):
// what any machine on the network can send to a port. tools/fuzz lists net_fuzz_targets; the
// suite replays their regression files.

SEEDS :: "testdata/fuzz/"

net_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "net.packets",
			run = fuzz_net_packets,
			seeds = SEEDS + "net.packets",
			dictionary = {"VXV1", "\x00\x00", "\xff\xff", "\xff\xff\xff\xff", "\x01\x00"},
			max_len = MTU + 1,
			generate = fuzz_net_generate_packet,
			alloc_cap = 8 << 20,
		},
		{
			name = "net.handshake",
			run = fuzz_net_handshake,
			seeds = SEEDS + "net.handshake",
			dictionary = {"VXV1", "\x01", "\x02", "\x04", "\x07", "\x00\x00\x00\x00"},
			max_len = DISCOVER_SIZE + 64,
			generate = fuzz_net_generate_handshake,
			alloc_cap = 8 << 20,
			fixup = fuzz_net_fixup_handshake,
		},
	}
	return targets[:]
}

// ---- net.packets
//
// The first byte picks the connection's state (fresh; first fragments received; established,
// with messages in flight both ways); the rest is one packet that arrives at it.

FUZZ_TOKEN :: u32(0x1234_abcd)

@(private = "file")
Fuzz_Pair :: struct {
	a, b:    Conn,
	buffer:  [dynamic]u8,
	packets: [dynamic][]u8,
	now:     time.Tick,
}

@(private = "file")
fuzz_pair_make :: proc(p: ^Fuzz_Pair, state: int, allocator: runtime.Allocator) {
	p.now = time.Tick{SIM_EPOCH_NS}
	conn_init(&p.a, FUZZ_TOKEN, p.now, allocator)
	conn_init(&p.b, FUZZ_TOKEN, p.now, allocator)
	p.buffer = make([dynamic]u8, allocator)
	p.packets = make([dynamic][]u8, allocator)
	data := make([]u8, 3000, allocator) // fragments: three records
	defer delete(data, allocator)
	for &d, i in data {d = u8(i)}
	conn_send(&p.b, data, true)
	conn_send(&p.b, data[:20], false)
	conn_send(&p.a, data[:2500], true)
	inbox := make([dynamic][]u8, allocator)
	defer delete(inbox)
	switch state {
	case 1:
		conn_flush(&p.b, p.now, &p.buffer, &p.packets)
		if len(p.packets) > 0 {conn_packet(&p.a, p.packets[0], p.now)}
	case 2:
		for _ in 0 ..< 3 {
			p.now = time.tick_add(p.now, 5 * time.Millisecond)
			conn_flush(&p.b, p.now, &p.buffer, &p.packets)
			for pk in p.packets {conn_packet(&p.a, pk, p.now)}
			conn_flush(&p.a, p.now, &p.buffer, &p.packets)
			for pk in p.packets {conn_packet(&p.b, pk, p.now)}
		}
	}
	conn_receive(&p.a, &inbox)
	for m in inbox {conn_free(&p.a, m)}
	conn_send(&p.b, data[:1500], true)
	conn_send(&p.b, data[:30], false)
	p.now = time.tick_add(p.now, 5 * time.Millisecond)
}

@(private = "file")
fuzz_pair_destroy :: proc(p: ^Fuzz_Pair) {
	conn_destroy(&p.a)
	conn_destroy(&p.b)
	delete(p.buffer)
	delete(p.packets)
}

fuzz_net_packets :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	if len(data) == 0 {return 1}
	p: Fuzz_Pair
	state := int(data[0]) % 3
	fuzz_pair_make(&p, state, allocator)
	defer fuzz_pair_destroy(&p)
	ok := conn_packet(&p.a, data[1:], p.now)
	inbox := make([dynamic][]u8, allocator)
	defer delete(inbox)
	conn_receive(&p.a, &inbox)
	total := 0
	for m in inbox {
		if len(m) == 0 ||
		   len(m) > MAX_MESSAGE {fuzz.fail("a message of %d bytes was delivered", len(m))}
		total += len(m)
		conn_free(&p.a, m)
	}
	if conn_backlog(&p.a) < 0 {fuzz.fail("the backlog is %d", conn_backlog(&p.a))}
	p.now = time.tick_add(p.now, 10 * time.Millisecond)
	conn_flush(&p.a, p.now, &p.buffer, &p.packets)
	for pk in p.packets {
		if len(pk) > MTU {fuzz.fail("a packet of %d bytes", len(pk))}
	}
	return fuzz.sig_mix(
		2,
		u64(state),
		u64(ok),
		u64(len(inbox)),
		fuzz.sig_bucket(total),
		u64(len(p.packets)),
		u64(p.a.stats.duplicates),
	)
}

fuzz_net_generate_packet :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	state := base.rng_int_max(rng, 3)
	p: Fuzz_Pair
	fuzz_pair_make(&p, state, context.temp_allocator)
	conn_flush(&p.b, p.now, &p.buffer, &p.packets)
	append(out, u8(state))
	if len(p.packets) == 0 {return}
	append(out, ..p.packets[base.rng_int_max(rng, len(p.packets))])
}

// ---- net.handshake
//
// The first byte: bit 0 = a peer was admitted at the sender's address first. The rest is one
// datagram to the host's port, as from FUZZ_FROM. The host's cookie key is fixed so a
// generated Response can carry a good cookie (the fixup repairs it after a mutation).

FUZZ_FROM :: net.Endpoint{net.IP4_Loopback, 40000}

@(private = "file")
fuzz_host :: proc(h: ^Host, n: ^Simnet, allocator: runtime.Allocator) -> bool {
	simnet_init(n, {}, allocator)
	if host_open(h, 0, 2, "", allocator, n) != nil {return false}
	h.secret = {}
	host_set_info(h, {1, 2, 3, 4})
	return true
}

@(private = "file")
fuzz_response :: proc(h: ^Host, salt: u64, out: ^[dynamic]u8) {
	buf: [64]u8
	w := writer(buf[:])
	put_u32(&w, MAGIC)
	put_u8(&w, u8(Packet_Kind.Response))
	put_u64(&w, salt)
	cookie := make_cookie(h, FUZZ_FROM, salt, window())
	put_bytes(&w, cookie[:])
	w.n += COOKIE_SIZE // the proof
	append(out, ..buf[:w.n])
}

fuzz_net_handshake :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	if len(data) == 0 {return 1}
	n: Simnet
	h: Host
	if !fuzz_host(&h, &n, allocator) {return 1}
	defer simnet_destroy(&n)
	defer host_close(&h, "bye")
	now := n.now
	if data[0] & 1 != 0 {
		first := make([dynamic]u8, allocator)
		defer delete(first)
		fuzz_response(&h, 7, &first)
		handle(&h, first[:], FUZZ_FROM, now)
	}
	peers := 0
	for p in h.peers {if p.active {peers += 1}}
	before := len(h.events)
	handle(&h, data[1:], FUZZ_FROM, now)
	after := 0
	for p in h.peers {if p.active {after += 1}}
	if after > len(h.peers) {fuzz.fail("more peers than seats")}
	return fuzz.sig_mix(
		2,
		u64(data[0] & 1),
		u64(peers),
		u64(after),
		u64(len(h.events) - before),
		fuzz.sig_bucket(len(data)),
		u64(data[5]) if len(data) > 5 && data[5] < 10 else 0, // the packet's kind
	)
}

fuzz_net_generate_handshake :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	n: Simnet
	h: Host
	if !fuzz_host(&h, &n, context.temp_allocator) {return}
	append(out, u8(base.rng_int_max(rng, 2)))
	buf: [DISCOVER_SIZE]u8
	pad := 0
	w := writer(buf[:])
	put_u32(&w, MAGIC)
	switch base.rng_int_max(rng, 5) {
	case 0:
		put_u8(&w, u8(Packet_Kind.Connect))
		put_u64(&w, base.rng_u64(rng))
		pad = CONNECT_SIZE
	case 1:
		fuzz_response(&h, base.rng_u64(rng), out)
		return
	case 2:
		put_u8(&w, u8(Packet_Kind.Disconnect))
		put_u32(&w, FUZZ_TOKEN)
	case 3:
		put_u8(&w, u8(Packet_Kind.Discover))
		put_u32(&w, u32(base.rng_u32(rng)))
		pad = DISCOVER_SIZE
	case:
		put_u8(&w, u8(1 + base.rng_int_max(rng, 9)))
		put_u32(&w, FUZZ_TOKEN)
	}
	append(out, ..buf[:max(w.n, pad)])
}

// fuzz_net_fixup_handshake: a Response keeps the cookie the host would give, with the salt
// it now has, so a mutated Response still reaches the host's later checks.
fuzz_net_fixup_handshake :: proc(data: ^[dynamic]u8) {
	if len(data) < 1 + 4 + 1 + 8 + COOKIE_SIZE {return}
	d := data[1:]
	if d[4] != u8(Packet_Kind.Response) {return}
	r := reader(d[5:])
	salt := get_u64(&r)
	h := Host{}
	cookie := make_cookie(&h, FUZZ_FROM, salt, window())
	copy(d[5 + 8:5 + 8 + COOKIE_SIZE], cookie[:])
}
