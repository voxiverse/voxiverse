package game

import "core:math/rand"
import "core:mem"
import "core:sync"
import "core:time"

import "../../base"

// Pipe connects a client and a server in one process: a queue of packets in
// each direction. Packets are owned byte copies; whoever receives one frees
// it with packet_free. The client session owns the Pipe and destroys it after
// the server thread has stopped. (Remote connections later implement the
// same procedures over UDP.)
//
//	pipe_init(&pipe)
//	client := Endpoint{&pipe, .Client}
//	send(client, bytes)
//	received: [dynamic]Packet
//	receive(client, &received)
//	for p in received {...; packet_free(client, p)}
//
// Development tools built in:
// - Conditions: simulated latency, jitter and bandwidth (pipe_set_conditions).
//   The stream stays reliable and ordered, as the protocol requires; packet
//   loss, duplication and reordering belong to the UDP transport, where the
//   reliability layer they exercise lives.
// - Traffic counters per sender and message kind (pipe_traffic).
// - A trace of every message sent (pipe_trace_start; see trace.odin).

Packet :: []u8

Side :: enum {
	Client,
	Server,
}

Conditions :: struct {
	latency_ms:     f32, // one way
	jitter_ms:      f32, // added at random, 0..jitter (order is kept)
	bandwidth_kbps: f32, // per direction, kilobytes per second; 0 = unlimited
	// Over UDP only (netcode.Conditions; the pipe is reliable and ordered,
	// as the in-process protocol requires):
	loss_percent:   f32,
	dup_percent:    f32,
}

// Traffic counts what one side sent, by message kind (the first byte).
Traffic :: struct {
	messages: [256]int,
	bytes:    [256]int,
}

Pipe :: struct {
	queues:     [Side]base.Queue(In_Flight), // queues[s]: packets for side s
	held:       [Side][dynamic]In_Flight, // arrived but not yet due; owned by the receiving side
	due:        [Side]time.Tick, // latest delivery time given so far, per receiver (sender's thread)
	closed:     bool, // (atomic)
	allocator:  mem.Allocator, // thread-safe: both sides allocate and free
	start:      time.Tick,
	mutex:      sync.Mutex, // conditions, traffic, trace
	conditions: Conditions,
	traffic:    [Side]Traffic, // by sender
	trace:      Trace_Writer,
	clock:      ^time.Tick, // the time the pipe reads (nil: the OS's; the harness gives its tick clock)
	rng:        base.Rng, // the jitter's draws, once seeded (pipe_seed)
	seeded:     bool,
}

@(private)
In_Flight :: struct {
	packet: Packet,
	due:    time.Tick, // deliver at or after
}

Endpoint :: struct {
	pipe: ^Pipe,
	side: Side,
}

pipe_init :: proc(p: ^Pipe, allocator := context.allocator, loc := #caller_location) {
	p^ = {
		allocator = allocator,
		start     = time.tick_now(), // (the trace's zero: wall time, never read by a test)
	}
	for &q in p.queues {base.queue_init(&q, allocator, loc)}
	for &h in p.held {h = make([dynamic]In_Flight, allocator, loc)}
}

// pipe_destroy frees packets nobody received and closes the trace.
pipe_destroy :: proc(p: ^Pipe) {
	left := make([dynamic]In_Flight, context.temp_allocator)
	for &q in p.queues {
		base.queue_drain(&q, &left)
		base.queue_destroy(&q)
	}
	for &h in p.held {
		append(&left, ..h[:])
		delete(h)
	}
	for f in left {delete(f.packet, p.allocator)}
	trace_close(&p.trace)
}

// pipe_seed makes the jitter a seeded sequence, the same on every run.
pipe_seed :: proc(p: ^Pipe, seed: u64) {
	sync.guard(&p.mutex)
	p.rng, p.seeded = base.rng_make(seed), true
}

@(private)
pipe_now :: proc(p: ^Pipe) -> time.Tick {
	return p.clock^ if p.clock != nil else time.tick_now()
}

pipe_set_conditions :: proc(p: ^Pipe, c: Conditions) {
	sync.guard(&p.mutex)
	p.conditions = c
}

// pipe_traffic copies the traffic counters (by sender).
pipe_traffic :: proc(p: ^Pipe) -> [Side]Traffic {
	sync.guard(&p.mutex)
	return p.traffic
}

// send queues a copy of data for the other side; false once the pipe is
// closed.
send :: proc(e: Endpoint, data: []u8) -> bool {
	p := e.pipe
	if sync.atomic_load(&p.closed) {return false}
	assert(len(data) > 0 && len(data) <= MAX_MESSAGE_SIZE)
	packet := make(Packet, len(data), p.allocator)
	copy(packet, data)
	to := other(e.side)
	now := pipe_now(p)
	due := now
	{
		sync.guard(&p.mutex)
		c := p.conditions
		draw := base.rng_f32(&p.rng) if p.seeded else rand.float32() // numbers: the pipe's simulated jitter
		delay := c.latency_ms + c.jitter_ms * draw // numbers: the pipe's simulated jitter
		due = time.tick_add(due, time.Duration(f64(delay) * f64(time.Millisecond)))
		// Bandwidth: a packet cannot arrive before the previous one plus its
		// own transmission time. Never earlier than the previous: in order.
		if c.bandwidth_kbps > 0 {
			transmit := time.Duration(
				f64(len(data)) / (f64(c.bandwidth_kbps) * 1000) * f64(time.Second),
			)
			due = max_tick(due, time.tick_add(p.due[to], transmit))
		}
		due = max_tick(due, p.due[to])
		p.due[to] = due
		p.traffic[e.side].messages[data[0]] += 1
		p.traffic[e.side].bytes[data[0]] += len(data)
		if p.trace.file != nil {trace_write(&p.trace, time.tick_diff(p.start, now), e.side, data)}
	}
	if !base.queue_push(&p.queues[to], In_Flight{packet, due}) {
		delete(packet, p.allocator)
		return false
	}
	return true
}

// receive appends every packet that has arrived and is due, in order.
receive :: proc(e: Endpoint, out: ^[dynamic]Packet) -> int {
	p := e.pipe
	held := &p.held[e.side]
	base.queue_drain(&p.queues[e.side], held)
	now := pipe_now(p)
	n := 0
	for n < len(held) && time.tick_diff(held[n].due, now) >= 0 {
		append(out, held[n].packet)
		n += 1
	}
	remove_range(held, 0, n)
	return n
}

packet_free :: proc(e: Endpoint, p: Packet) {
	delete(p, e.pipe.allocator)
}

// close ends the connection for both sides; packets already queued can
// still be received.
close :: proc(e: Endpoint) {
	sync.atomic_store(&e.pipe.closed, true)
	for &q in e.pipe.queues {base.queue_close(&q)}
}

is_closed :: proc(e: Endpoint) -> bool {
	return sync.atomic_load(&e.pipe.closed)
}

// pipe_trace_start records every message from now on to path, with header
// describing the session (for netdump and replay). False if the file
// cannot be written.
pipe_trace_start :: proc(p: ^Pipe, path: string, header: Trace_Header) -> bool {
	sync.guard(&p.mutex)
	if p.trace.file != nil {return true}
	return trace_open(&p.trace, path, header)
}

pipe_tracing :: proc(p: ^Pipe) -> bool {
	sync.guard(&p.mutex)
	return p.trace.file != nil
}

@(private = "file")
other :: proc(s: Side) -> Side {
	return .Server if s == .Client else .Client
}

@(private = "file")
max_tick :: proc(a, b: time.Tick) -> time.Tick {
	return b if time.tick_diff(a, b) > 0 else a
}
