package netcode

import "core:net"
import "core:slice"
import "core:time"

import "../../base"

// A non-blocking UDP socket, with bad network conditions simulated on the
// way out (for tests and the debug variables): loss, duplication, delay
// and jitter (which reorders packets).

Socket :: struct {
	socket:     net.UDP_Socket,
	port:       int, // bound
	conditions: Conditions,
	rng:        base.Rng, // the simulation's draws (Conditions.seed)
	rng_seed:   u64, // the seed rng was made from (0: not yet)
	held:       [dynamic]Held, // delayed by the simulation, not yet sent
	capture:    ^Capture, // records every packet sent and received (nil: none)
	recv_buf:   [MTU + 1]u8, // one byte more: anything that fills it is too long
}

Conditions :: struct {
	loss:       f32, // 0..1: chance a packet is dropped
	duplicate:  f32, // 0..1: chance it is sent twice
	latency_ms: f32, // added on the way out
	jitter_ms:  f32, // plus up to this much more at random (reorders)
	seed:       u64, // the draws are a stream made from this: the same seed, the same losses (0: the clock's)
}

@(private)
Held :: struct {
	due:  time.Tick,
	to:   net.Endpoint,
	data: []u8,
}

// socket_open binds a UDP socket to port (0: any free one) on all
// interfaces. broadcast: allowed to send to broadcast addresses (LAN
// discovery).
socket_open :: proc(s: ^Socket, port: int, broadcast := false) -> (err: net.Network_Error) {
	s^ = {}
	s.socket = net.make_bound_udp_socket(net.IP4_Any, port) or_return
	if e := net.set_blocking(s.socket, false); e != nil {
		net.close(s.socket)
		return e
	}
	if broadcast {
		if e := net.set_option(s.socket, .Broadcast, true); e != nil {
			net.close(s.socket)
			return e
		}
	}
	bound, e := net.bound_endpoint(s.socket)
	if e != nil {
		net.close(s.socket)
		return e
	}
	s.port = bound.port
	return nil
}

socket_close :: proc(s: ^Socket) {
	if s.socket != 0 {net.close(s.socket)}
	for h in s.held {delete(h.data)}
	delete(s.held)
	s^ = {}
}

// socket_send sends (or, under simulated conditions, may drop, repeat or
// hold back) one packet.
socket_send :: proc(s: ^Socket, to: net.Endpoint, data: []u8, now: time.Tick) {
	c := s.conditions
	if c == {} {
		send_now(s, to, data) // a full buffer drops it: UDP may
		return
	}
	seed := c.seed if c.seed != 0 else s.rng_seed
	if seed == 0 {seed = u64(time.tick_now()._nsec) | 1} 	// (unseeded: whatever the clock says)
	if s.rng_seed != seed {
		s.rng, s.rng_seed = base.rng_make(seed), seed
	}
	if base.rng_f32(&s.rng) < c.loss {return}
	copies := 2 if base.rng_f32(&s.rng) < c.duplicate else 1
	for _ in 0 ..< copies {
		delay := c.latency_ms + c.jitter_ms * base.rng_f32(&s.rng)
		due := time.tick_add(now, time.Duration(f64(delay) * f64(time.Millisecond)))
		append(&s.held, Held{due, to, slice.clone(data)})
	}
	socket_pump(s, now)
}

// socket_pump sends held packets that are due.
socket_pump :: proc(s: ^Socket, now: time.Tick) {
	for i := 0; i < len(s.held); {
		h := s.held[i]
		if time.tick_diff(h.due, now) < 0 {
			i += 1
			continue
		}
		send_now(s, h.to, h.data)
		delete(h.data)
		unordered_remove(&s.held, i)
	}
}

// socket_receive returns the next packet that arrived (a view of the
// socket's buffer, valid until the next call), or ok = false when there are
// none. Packets longer than MTU are skipped.
socket_receive :: proc(s: ^Socket) -> (data: []u8, from: net.Endpoint, ok: bool) {
	// Errors other than "nothing more" are skipped: Windows reports an
	// earlier packet's ICMP "port unreachable" here, as a receive error.
	for _ in 0 ..< 64 {
		n, src, err := net.recv_udp(s.socket, s.recv_buf[:])
		if err == .Would_Block {return nil, {}, false}
		if err != nil || n <= 0 || n > MTU {continue}
		if s.capture != nil {capture_packet(s.capture, src, local(s, src), s.recv_buf[:n])}
		return s.recv_buf[:n], src, true
	}
	return nil, {}, false
}

@(private = "file")
send_now :: proc(s: ^Socket, to: net.Endpoint, data: []u8) {
	if s.capture != nil {capture_packet(s.capture, local(s, to), to, data)}
	net.send_udp(s.socket, data, to)
}

// local: this socket's address as seen by peer (bound to every interface,
// it has no single one; loopback peers see loopback).
@(private = "file")
local :: proc(s: ^Socket, peer: net.Endpoint) -> net.Endpoint {
	if a, ok := peer.address.(net.IP4_Address);
	   ok && a[0] == 127 {return {net.IP4_Loopback, s.port}}
	return {net.IP4_Any, s.port}
}
