package game

import "core:mem"
import "core:sync"

import "../base"

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

Packet :: []u8

Side :: enum {
	Client,
	Server,
}

Pipe :: struct {
	queues:    [Side]base.Queue(Packet), // queues[s]: packets for side s
	closed:    bool, // (atomic)
	allocator: mem.Allocator, // thread-safe: both sides allocate and free
	sent:      [Side]int, // bytes sent by each side (atomic)
}

Endpoint :: struct {
	pipe: ^Pipe,
	side: Side,
}

pipe_init :: proc(p: ^Pipe, allocator := context.allocator, loc := #caller_location) {
	p^ = {
		allocator = allocator,
	}
	for &q in p.queues {base.queue_init(&q, allocator, loc)}
}

// pipe_destroy frees packets nobody received.
pipe_destroy :: proc(p: ^Pipe) {
	left := make([dynamic]Packet, context.temp_allocator)
	for &q in p.queues {
		base.queue_drain(&q, &left)
		base.queue_destroy(&q)
	}
	for packet in left {delete(packet, p.allocator)}
}

// send queues a copy of data for the other side; false once the pipe is
// closed.
send :: proc(e: Endpoint, data: []u8) -> bool {
	if sync.atomic_load(&e.pipe.closed) {return false}
	assert(len(data) <= MAX_MESSAGE_SIZE)
	packet := make(Packet, len(data), e.pipe.allocator)
	copy(packet, data)
	if !base.queue_push(&e.pipe.queues[other(e.side)], packet) {
		delete(packet, e.pipe.allocator)
		return false
	}
	sync.atomic_add(&e.pipe.sent[e.side], len(data))
	return true
}

// receive appends every packet that has arrived, in order.
receive :: proc(e: Endpoint, out: ^[dynamic]Packet) -> int {
	return base.queue_drain(&e.pipe.queues[e.side], out)
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

@(private = "file")
other :: proc(s: Side) -> Side {
	return .Server if s == .Client else .Client
}
