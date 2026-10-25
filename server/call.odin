package server

import "core:sync"

import "../base"
import "../game"

// call runs procedure(s, data) on the server's thread at the start of its
// next tick, and waits for it: how code beside an in-process server (the
// game hosting its own world: checks, benchmarks) reaches into it safely.
// Never over the network; never from the server's own thread.
call :: proc(s: ^Server, procedure: proc(s: ^Server, data: rawptr), data: rawptr) {
	c := Server_Call {
		procedure = procedure,
		data      = data,
	}
	base.queue_push(&s.calls, &c)
	sync.sema_wait(&c.done)
}

Server_Call :: struct {
	procedure: proc(s: ^Server, data: rawptr),
	data:      rawptr,
	done:      sync.Sema,
}

// calls_run runs the calls waiting (the server's thread, each tick).
@(private)
calls_run :: proc(s: ^Server) {
	pending := make([dynamic]^Server_Call, context.temp_allocator)
	base.queue_drain(&s.calls, &pending)
	for c in pending {
		c.procedure(s, c.data)
		sync.sema_post(&c.done)
	}
}

// What calls do (the server's thread only).

// explode_by: an explosion of radius in the world of the player called
// name (or the in-process host's, name ""), centred on the block p.
explode_by :: proc(s: ^Server, name: string, p: game.Block_Pos, radius: f64) {
	c, playing := seat(s, name)
	if !playing {return}
	explode(c.world, {f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5}, radius)
}

// chunks_hash_of: a hash of every chunk the server has sent the player
// called name (or the in-process host, name ""), from the server's side
// (the client hashes its own to compare), and how many there are.
chunks_hash_of :: proc(s: ^Server, name: string) -> (count: int, sum: u64) {
	c, playing := seat(s, name)
	if !playing {return}
	for pos in c.has {
		if chunk := chunks_get(&c.world.chunks, pos); chunk != nil && chunk.state == .Ready {
			game.chunks_hash_add(&sum, pos, &chunk.blocks)
		}
	}
	return len(c.has), sum
}

// seat: the playing client called name ("": the in-process host's seat).
@(private = "file")
seat :: proc(s: ^Server, name: string) -> (^Client, bool) {
	c := &s.clients[0] if name == "" else client_by_name(s, name)
	if c == nil || c.state != .Playing {return nil, false}
	return c, true
}
