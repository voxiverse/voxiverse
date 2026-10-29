package netcode

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:mem"
import "core:net"
import "core:time"

// The server's side: one socket, many peers. A peer gets in only by
// answering a challenge: the server sends a cookie (a keyed hash of the
// peer's address, its salt and the time) and keeps no state until the
// cookie comes back, so forged source addresses can neither fill the
// server with half-open connections nor make it send much to a victim
// (requests are padded to be larger than the answers). With a password,
// the response proves it (a keyed hash of the cookie) without sending it.
//
//	host_open(&h, port, max_peers = 8, password = "")
//	every tick:
//		host_update(&h, now)                // packets in: events
//		for e in h.events {...}             // connected / message / disconnected
//		host_send(&h, peer, bytes, reliable)
//		host_flush(&h, now)                 // packets out
//	host_close(&h, "server stopping")

Peer_Id :: distinct u32 // index + 1; 0 = none

Host :: struct {
	socket:     Socket,
	allocator:  mem.Allocator,
	secret:     [32]u8, // cookie key, random per run
	instance:   u64, // random per run: discovery tells one server's several answers apart
	password:   string,
	peers:      []Peer, // index = id - 1
	info:       [dynamic]u8, // what Discover gets back (host_set_info)
	events:     [dynamic]Host_Event,
	handshakes: int, // answered this second (rate limit)
	second:     time.Tick,
	buffer:     [dynamic]u8,
	packets:    [dynamic][]u8,
	received:   [dynamic][]u8,
}

Peer :: struct {
	active:  bool,
	address: net.Endpoint,
	salt:    u64, // the client's, from its handshake
	conn:    Conn,
}

Host_Event :: union {
	Peer_Connected,
	Peer_Message,
	Peer_Disconnected,
}

Peer_Connected :: struct {
	peer:    Peer_Id,
	address: net.Endpoint,
}

// Peer_Message: data is owned by the host until the next host_update.
Peer_Message :: struct {
	peer: Peer_Id,
	data: []u8,
}

Peer_Disconnected :: struct {
	peer:   Peer_Id,
	reason: Disconnect_Reason,
}

Disconnect_Reason :: enum u8 {
	Left, // said goodbye
	Timed_Out,
	Kicked, // host_kick / host_close
}

CONNECT_SIZE :: 300 // a Connect is padded to this: more than any answer
DISCOVER_SIZE :: 512
MAX_INFO :: 400 // discovery info (less than DISCOVER_SIZE minus headers)
MAX_REASON :: 200
COOKIE_SIZE :: 16
COOKIE_WINDOW :: 10 // seconds a cookie stays good (and one window more)
HANDSHAKES_PER_SECOND :: 200
DISCOVERY_PORTS :: 10 // LAN servers are looked for on DEFAULT_PORT and the next ones
DEFAULT_PORT :: 27315

host_open :: proc(
	h: ^Host,
	port: int,
	max_peers: int,
	password := "",
	allocator := context.allocator,
	sim: ^Simnet = nil,
) -> net.Network_Error {
	h^ = {
		allocator = allocator,
		password  = password,
	}
	socket_open(&h.socket, port, sim = sim) or_return
	crypto.rand_bytes(h.secret[:])
	crypto.rand_bytes(mem.ptr_to_bytes(&h.instance))
	h.peers = make([]Peer, max_peers, allocator)
	h.info = make([dynamic]u8, allocator)
	h.events = make([dynamic]Host_Event, allocator)
	h.buffer = make([dynamic]u8, allocator)
	h.packets = make([dynamic][]u8, allocator)
	h.received = make([dynamic][]u8, allocator)
	return nil
}

// host_now: the time on the host's network (the OS's, or a simulated one's).
host_now :: proc(h: ^Host) -> time.Tick {return socket_now(&h.socket)}

// host_close says goodbye to every peer (reason shown to them) and closes.
host_close :: proc(h: ^Host, reason: string) {
	now := host_now(h)
	for &p, i in h.peers {
		if p.active {host_kick(h, Peer_Id(i + 1), reason, now)}
	}
	socket_pump(&h.socket, time.tick_add(now, time.Hour)) // anything held back goes now
	socket_close(&h.socket)
	free_received(h)
	delete(h.peers, h.allocator)
	delete(h.info)
	delete(h.events)
	delete(h.buffer)
	delete(h.packets)
	delete(h.received)
	h^ = {}
}

// host_set_info sets what LAN discovery answers (at most MAX_INFO bytes).
host_set_info :: proc(h: ^Host, info: []u8) {
	clear(&h.info)
	append(&h.info, ..info[:min(len(info), MAX_INFO)])
}

host_update :: proc(h: ^Host, now: time.Tick) {
	free_received(h)
	clear(&h.events)
	if time.tick_diff(h.second, now) >= time.Second {
		h.second, h.handshakes = now, 0
	}
	socket_pump(&h.socket, now)
	for {
		data, from, ok := socket_receive(&h.socket)
		if !ok {break}
		handle(h, data, from, now)
	}
	for &p, i in h.peers {
		if p.active && conn_timed_out(&p.conn, now) {drop(h, Peer_Id(i + 1), .Timed_Out)}
	}
}

// host_send queues a message for a peer (ignored if it is gone).
host_send :: proc(h: ^Host, id: Peer_Id, data: []u8, reliable: bool) {
	if p := peer(h, id); p != nil {conn_send(&p.conn, data, reliable)}
}

// host_backlog: reliable bytes a peer has not acknowledged yet.
host_backlog :: proc(h: ^Host, id: Peer_Id) -> int {
	if p := peer(h, id); p != nil {return conn_backlog(&p.conn)}
	return 0
}

host_conn :: proc(h: ^Host, id: Peer_Id) -> ^Conn {
	if p := peer(h, id); p != nil {return &p.conn}
	return nil
}

// host_flush sends every peer what is due.
host_flush :: proc(h: ^Host, now: time.Tick) {
	for &p in h.peers {
		if !p.active {continue}
		conn_flush(&p.conn, now, &h.buffer, &h.packets)
		for packet in h.packets {socket_send(&h.socket, p.address, packet, now)}
	}
}

// host_kick disconnects a peer, telling it why (a Disconnect, sent three
// times since it may be lost). No event follows: the caller knows.
host_kick :: proc(h: ^Host, id: Peer_Id, reason: string, now: time.Tick) {
	p := peer(h, id)
	if p == nil {return}
	buf: [64 + MAX_REASON]u8
	w := writer(buf[:])
	put_u32(&w, MAGIC)
	put_u8(&w, u8(Packet_Kind.Disconnect))
	put_u32(&w, p.conn.token)
	put_blob(&w, transmute([]u8)reason[:min(len(reason), MAX_REASON)])
	for _ in 0 ..< 3 {socket_send(&h.socket, p.address, buf[:w.n], now)}
	conn_destroy(&p.conn)
	p^ = {}
}

@(private = "file")
peer :: proc(h: ^Host, id: Peer_Id) -> ^Peer {
	i := int(id) - 1
	if i < 0 || i >= len(h.peers) || !h.peers[i].active {return nil}
	return &h.peers[i]
}

@(private = "file")
drop :: proc(h: ^Host, id: Peer_Id, reason: Disconnect_Reason) {
	p := peer(h, id)
	conn_destroy(&p.conn)
	p^ = {}
	append(&h.events, Peer_Disconnected{id, reason})
}

@(private = "file")
free_received :: proc(h: ^Host) {
	for m in h.received {delete(m, h.allocator)}
	clear(&h.received)
}

@(private = "file")
find :: proc(h: ^Host, from: net.Endpoint) -> Peer_Id {
	for p, i in h.peers {
		if p.active && p.address == from {return Peer_Id(i + 1)}
	}
	return 0
}

@(private = "file")
handle :: proc(h: ^Host, data: []u8, from: net.Endpoint, now: time.Tick) {
	r := reader(data)
	if get_u32(&r) != MAGIC {return}
	kind := Packet_Kind(get_u8(&r))
	if !r.ok {return}
	#partial switch kind {
	case .Data:
		id := find(h, from)
		p := peer(h, id)
		if p == nil || !conn_packet(&p.conn, data, now) {return}
		before := len(h.received)
		conn_receive(&p.conn, &h.received)
		for m in h.received[before:] {append(&h.events, Peer_Message{id, m})}
	case .Connect:
		salt := get_u64(&r)
		if !r.ok || len(data) < CONNECT_SIZE || !handshake_allowed(h) {return}
		cookie := make_cookie(h, from, salt, window())
		reply: [64]u8
		w := writer(reply[:])
		put_u32(&w, MAGIC)
		put_u8(&w, u8(Packet_Kind.Challenge))
		put_u64(&w, salt)
		put_bytes(&w, cookie[:])
		socket_send(&h.socket, from, reply[:w.n], now)
	case .Response:
		salt := get_u64(&r)
		cookie := get_bytes(&r, COOKIE_SIZE)
		proof := get_bytes(&r, COOKIE_SIZE)
		if !r.ok || !handshake_allowed(h) {return}
		good := false
		for wnd in ([]i64{window(), window() - 1}) {
			want := make_cookie(h, from, salt, wnd)
			if crypto.compare_constant_time(want[:], cookie) == 1 {good = true}
		}
		if !good {return} 	// forged, or too old: no answer
		if existing := find(h, from); existing != 0 {
			p := peer(h, existing)
			if p.salt == salt {
				send_accept(h, from, salt, p.conn.token, now) // our Accept was lost
				return
			}
			drop(h, existing, .Left) // the same address starting over
		}
		if h.password != "" {
			want := password_proof(h.password, cookie)
			if crypto.compare_constant_time(want[:], proof) != 1 {
				send_deny(h, from, salt, "wrong password", now)
				return
			}
		}
		slot := -1
		for p, i in h.peers {
			if !p.active {
				slot = i
				break
			}
		}
		if slot < 0 {
			send_deny(h, from, salt, "the server is full", now)
			return
		}
		token: u32
		crypto.rand_bytes(mem.ptr_to_bytes(&token))
		p := &h.peers[slot]
		p^ = {
			active  = true,
			address = from,
			salt    = salt,
		}
		conn_init(&p.conn, token, now, h.allocator)
		send_accept(h, from, salt, token, now)
		append(&h.events, Peer_Connected{Peer_Id(slot + 1), from})
	case .Disconnect:
		token := get_u32(&r)
		id := find(h, from)
		if p := peer(h, id); p != nil && r.ok && token == p.conn.token {drop(h, id, .Left)}
	case .Discover:
		nonce := get_u32(&r)
		if !r.ok || len(data) < DISCOVER_SIZE || !handshake_allowed(h) {return}
		reply: [DISCOVER_SIZE]u8
		w := writer(reply[:])
		put_u32(&w, MAGIC)
		put_u8(&w, u8(Packet_Kind.Discover_Reply))
		put_u32(&w, nonce)
		put_u64(&w, h.instance)
		put_blob(&w, h.info[:])
		socket_send(&h.socket, from, reply[:w.n], now)
	}
}

@(private = "file")
handshake_allowed :: proc(h: ^Host) -> bool {
	h.handshakes += 1
	return h.handshakes <= HANDSHAKES_PER_SECOND
}

// window: which cookie window it is (wall clock: cookies outlive no restart
// anyway, as the secret is new each run).
@(private = "file")
window :: proc() -> i64 {
	return time.time_to_unix(time.now()) / COOKIE_WINDOW
}

@(private = "file")
make_cookie :: proc(
	h: ^Host,
	from: net.Endpoint,
	salt: u64,
	wnd: i64,
) -> (
	cookie: [COOKIE_SIZE]u8,
) {
	msg: [64]u8
	w := writer(msg[:])
	switch a in from.address {
	case net.IP4_Address:
		put_u8(&w, 4)
		b := a
		put_bytes(&w, b[:])
	case net.IP6_Address:
		put_u8(&w, 6)
		b := transmute([16]u8)a
		put_bytes(&w, b[:])
	}
	put_u16(&w, u16(from.port))
	put_u64(&w, salt)
	put_u64(&w, u64(wnd))
	tag: [32]u8
	hmac.sum(hash.Algorithm.SHA256, tag[:], msg[:w.n], h.secret[:])
	copy(cookie[:], tag[:COOKIE_SIZE])
	return
}

// password_proof: what a client sends to show it knows the password.
password_proof :: proc(password: string, cookie: []u8) -> (proof: [COOKIE_SIZE]u8) {
	tag: [32]u8
	hmac.sum(hash.Algorithm.SHA256, tag[:], cookie, transmute([]u8)password)
	copy(proof[:], tag[:COOKIE_SIZE])
	return
}

@(private = "file")
send_accept :: proc(h: ^Host, to: net.Endpoint, salt: u64, token: u32, now: time.Tick) {
	reply: [32]u8
	w := writer(reply[:])
	put_u32(&w, MAGIC)
	put_u8(&w, u8(Packet_Kind.Accept))
	put_u64(&w, salt)
	put_u32(&w, token)
	socket_send(&h.socket, to, reply[:w.n], now)
}

@(private = "file")
send_deny :: proc(h: ^Host, to: net.Endpoint, salt: u64, reason: string, now: time.Tick) {
	reply: [32 + MAX_REASON]u8
	w := writer(reply[:])
	put_u32(&w, MAGIC)
	put_u8(&w, u8(Packet_Kind.Deny))
	put_u64(&w, salt)
	put_blob(&w, transmute([]u8)reason)
	socket_send(&h.socket, to, reply[:w.n], now)
}
