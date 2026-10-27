package netcode

import "core:crypto"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

// The client's side: one connection to one server.
//
//	link_connect(&l, server_endpoint, password, now)
//	every frame:
//		link_update(&l, now)                 // packets in; handshake
//		switch l.state {...}                  // .Connected: messages flow
//		link_receive(&l, &messages) ... link_free(&l, m)
//		link_send(&l, bytes, reliable)
//		link_flush(&l, now)
//	link_close(&l, "bye")

Link_State :: enum u8 {
	Connecting, // sending Connect, waiting for a Challenge
	Responding, // sending the Response, waiting for Accept
	Connected,
	Failed, // see reason
}

Link :: struct {
	state:     Link_State,
	reason:    string, // why it failed (allocated)
	socket:    Socket,
	server:    net.Endpoint,
	password:  string, // (allocated)
	salt:      u64,
	cookie:    [COOKIE_SIZE]u8,
	started:   time.Tick,
	last_try:  time.Tick,
	conn:      Conn,
	allocator: mem.Allocator,
	buffer:    [dynamic]u8,
	packets:   [dynamic][]u8,
}

CONNECT_TIMEOUT :: 10 * time.Second
CONNECT_RETRY :: 250 * time.Millisecond

link_connect :: proc(
	l: ^Link,
	server: net.Endpoint,
	password: string,
	now: time.Tick,
	allocator := context.allocator,
) -> net.Network_Error {
	l^ = {
		server    = server,
		started   = now,
		allocator = allocator,
	}
	socket_open(&l.socket, 0) or_return
	l.password = strings.clone(password, allocator)
	crypto.rand_bytes(mem.ptr_to_bytes(&l.salt))
	l.buffer = make([dynamic]u8, allocator)
	l.packets = make([dynamic][]u8, allocator)
	send_handshake(l, now)
	return nil
}

// link_close says goodbye (if connected) and frees everything.
link_close :: proc(l: ^Link, reason: string) {
	if l.state == .Connected {
		buf: [64 + MAX_REASON]u8
		w := writer(buf[:])
		put_u32(&w, MAGIC)
		put_u8(&w, u8(Packet_Kind.Disconnect))
		put_u32(&w, l.conn.token)
		put_blob(&w, transmute([]u8)reason[:min(len(reason), MAX_REASON)])
		now := time.tick_now()
		for _ in 0 ..< 3 {socket_send(&l.socket, l.server, buf[:w.n], now)}
		socket_pump(&l.socket, time.tick_add(now, time.Hour))
		conn_destroy(&l.conn)
	}
	socket_close(&l.socket)
	delete(l.reason, l.allocator)
	delete(l.password, l.allocator)
	delete(l.buffer)
	delete(l.packets)
	l^ = {}
}

link_update :: proc(l: ^Link, now: time.Tick) {
	if l.state == .Failed {return}
	socket_pump(&l.socket, now)
	for {
		data, from, ok := socket_receive(&l.socket)
		if !ok {break}
		if from != l.server {continue}
		handle_reply(l, data, now)
		if l.state == .Failed {return}
	}
	switch l.state {
	case .Connecting, .Responding:
		if time.tick_diff(l.started, now) > CONNECT_TIMEOUT {
			fail(l, "no answer from the server")
		} else if time.tick_diff(l.last_try, now) >= CONNECT_RETRY {
			send_handshake(l, now)
		}
	case .Connected:
		if conn_timed_out(&l.conn, now) {fail(l, "the server stopped answering")}
	case .Failed:
	}
}

link_send :: proc(l: ^Link, data: []u8, reliable: bool) {
	if l.state == .Connected {conn_send(&l.conn, data, reliable)}
}

// link_receive moves arrived messages to out; free each with link_free.
link_receive :: proc(l: ^Link, out: ^[dynamic][]u8) {
	if l.state == .Connected {conn_receive(&l.conn, out)}
}

link_free :: proc(l: ^Link, m: []u8) {
	delete(m, l.allocator)
}

link_flush :: proc(l: ^Link, now: time.Tick) {
	if l.state != .Connected {return}
	conn_flush(&l.conn, now, &l.buffer, &l.packets)
	for p in l.packets {socket_send(&l.socket, l.server, p, now)}
}

@(private = "file")
send_handshake :: proc(l: ^Link, now: time.Tick) {
	l.last_try = now
	buf: [CONNECT_SIZE]u8
	w := writer(buf[:])
	put_u32(&w, MAGIC)
	if l.state == .Connecting {
		put_u8(&w, u8(Packet_Kind.Connect))
		put_u64(&w, l.salt)
		w.n = CONNECT_SIZE // padded: answering costs the server less than asking costs us
	} else {
		put_u8(&w, u8(Packet_Kind.Response))
		put_u64(&w, l.salt)
		put_bytes(&w, l.cookie[:])
		proof: [COOKIE_SIZE]u8
		if l.password != "" {proof = password_proof(l.password, l.cookie[:])}
		put_bytes(&w, proof[:])
	}
	socket_send(&l.socket, l.server, buf[:w.n], now)
}

@(private = "file")
handle_reply :: proc(l: ^Link, data: []u8, now: time.Tick) {
	r := reader(data)
	if get_u32(&r) != MAGIC {return}
	kind := Packet_Kind(get_u8(&r))
	if !r.ok {return}
	#partial switch kind {
	case .Challenge:
		salt := get_u64(&r)
		cookie := get_bytes(&r, COOKIE_SIZE)
		if !r.ok || salt != l.salt || l.state != .Connecting {return}
		copy(l.cookie[:], cookie)
		l.state = .Responding
		send_handshake(l, now)
	case .Accept:
		salt := get_u64(&r)
		token := get_u32(&r)
		if !r.ok || salt != l.salt || l.state != .Responding {return}
		conn_init(&l.conn, token, now, l.allocator)
		l.state = .Connected
	case .Deny:
		salt := get_u64(&r)
		reason := get_blob(&r, MAX_REASON)
		if !r.ok || salt != l.salt || l.state == .Connected {return}
		fail(l, string(reason))
	case .Data:
		if l.state == .Connected {conn_packet(&l.conn, data, now)}
	case .Disconnect:
		token := get_u32(&r)
		reason := get_blob(&r, MAX_REASON)
		if !r.ok || l.state != .Connected || token != l.conn.token {return}
		fail(l, string(reason) if len(reason) > 0 else "the server closed the connection")
	}
}

@(private = "file")
fail :: proc(l: ^Link, reason: string) {
	if l.state == .Connected {conn_destroy(&l.conn)}
	l.state = .Failed
	delete(l.reason, l.allocator)
	l.reason = strings.clone(reason, l.allocator)
}

// LAN discovery: a Discover to the default ports, sent to this machine, to
// the global broadcast address and to each network's own broadcast address
// (Windows sends the global one out of a single interface); servers answer
// with their info (the game's bytes).

Discovery :: struct {
	socket:    Socket,
	nonce:     u32,
	last_ask:  time.Tick,
	found:     [dynamic]Found_Server,
	targets:   [dynamic]net.Address, // where to ask
	allocator: mem.Allocator,
}

Found_Server :: struct {
	instance: u64,
	address:  net.Endpoint, // the first answer's (a server on this machine: localhost)
	info:     []u8, // (allocated)
	seen:     time.Tick,
}

DISCOVER_EVERY :: 1 * time.Second
DISCOVER_FORGET :: 4 * time.Second // not heard from this long: gone from the list

discovery_open :: proc(d: ^Discovery, allocator := context.allocator) -> net.Network_Error {
	d^ = {
		allocator = allocator,
	}
	socket_open(&d.socket, 0, broadcast = true) or_return
	crypto.rand_bytes(mem.ptr_to_bytes(&d.nonce))
	d.found = make([dynamic]Found_Server, allocator)
	d.targets = make([dynamic]net.Address, allocator)
	append(&d.targets, net.IP4_Loopback, net.IP4_Address{255, 255, 255, 255})
	if interfaces, err := net.enumerate_interfaces(context.temp_allocator); err == nil {
		for iface in interfaces {
			for lease in iface.unicast {
				a, is4 := lease.address.(net.IP4_Address)
				m, mask4 := net.Address(lease.netmask).(net.IP4_Address)
				if !is4 || !mask4 || a == net.IP4_Loopback {continue}
				b: net.IP4_Address
				for i in 0 ..< 4 {b[i] = a[i] | ~m[i]}
				if b != a {append(&d.targets, b)}
			}
		}
	}
	return nil
}

discovery_close :: proc(d: ^Discovery) {
	socket_close(&d.socket)
	for f in d.found {delete(f.info, d.allocator)}
	delete(d.found)
	delete(d.targets)
	d^ = {}
}

// discovery_update asks again every DISCOVER_EVERY and collects answers in
// d.found (forgetting servers that stopped answering).
discovery_update :: proc(d: ^Discovery, now: time.Tick) {
	if d.last_ask == {} || time.tick_diff(d.last_ask, now) >= DISCOVER_EVERY {
		d.last_ask = now
		buf: [DISCOVER_SIZE]u8
		w := writer(buf[:])
		put_u32(&w, MAGIC)
		put_u8(&w, u8(Packet_Kind.Discover))
		put_u32(&w, d.nonce)
		for to in d.targets {
			for port in DEFAULT_PORT ..< DEFAULT_PORT + DISCOVERY_PORTS {
				socket_send(&d.socket, {to, port}, buf[:], now)
			}
		}
	}
	for {
		data, from, ok := socket_receive(&d.socket)
		if !ok {break}
		r := reader(data)
		if get_u32(&r) != MAGIC || Packet_Kind(get_u8(&r)) != .Discover_Reply {continue}
		nonce := get_u32(&r)
		instance := get_u64(&r)
		info := get_blob(&r, MAX_INFO)
		if !r.ok || nonce != d.nonce {continue}
		entry: ^Found_Server
		for &f in d.found {if f.instance == instance {entry = &f}}
		if entry == nil {
			append(&d.found, Found_Server{instance = instance, address = from})
			entry = &d.found[len(d.found) - 1]
		}
		delete(entry.info, d.allocator)
		entry.info = make([]u8, len(info), d.allocator)
		copy(entry.info, info)
		entry.seen = now
	}
	for i := 0; i < len(d.found); {
		if time.tick_diff(d.found[i].seen, now) > DISCOVER_FORGET {
			delete(d.found[i].info, d.allocator)
			ordered_remove(&d.found, i)
		} else {
			i += 1
		}
	}
}
