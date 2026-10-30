package server

import "core:sync"

import "../base"
import "../common/game"

// call runs procedure(s, data) on the server's thread at the start of its
// next tick, and waits for it (a stepped server runs it at once): how code
// beside an in-process server (the game hosting its own world: checks,
// benchmarks) reaches into it safely.
// Never over the network; never from the server's own thread.
call :: proc(s: ^Server, procedure: proc(s: ^Server, data: rawptr), data: rawptr) {
	if s.config.stepped {
		// (no thread: the caller is between two steps, as the server's thread is between ticks)
		procedure(s, data)
		return
	}
	done: sync.Sema
	base.queue_push(&s.calls, Server_Call{procedure = procedure, data = data, done = &done})
	sync.sema_wait(&done)
}

// CALL_DATA_MAX: the most data call_async copies (bytes).
CALL_DATA_MAX :: 64

// call_async queues procedure(s, a copy of data) to run on the server's
// thread at the start of its next tick (a stepped server's next step), and
// returns at once: what a caller that must not wait for a tick uses (the
// benchmark's explosions). data is copied, so it may be the caller's own
// stack; at most CALL_DATA_MAX bytes.
call_async :: proc(s: ^Server, procedure: proc(s: ^Server, data: rawptr), data: []byte) {
	assert(len(data) <= CALL_DATA_MAX, "call_async: more data than CALL_DATA_MAX")
	c := Server_Call {
		procedure = procedure,
		size      = len(data),
	}
	copy(c.copied[:], data)
	base.queue_push(&s.calls, c)
}

// Server_Call: a call waiting for the server's next tick. A waiting caller's
// (call) has its data and done on the caller's stack; an async one
// (call_async) carries a copy of its data.
Server_Call :: struct {
	procedure: proc(s: ^Server, data: rawptr),
	data:      rawptr, // the waiting caller's (an async call's is copied[:size])
	done:      ^sync.Sema, // posted once it has run (nil: nobody waits)
	copied:    [CALL_DATA_MAX]byte,
	size:      int,
}

// calls_run runs the calls waiting (the server's thread, each tick).
@(private)
calls_run :: proc(s: ^Server) {
	pending := make([dynamic]Server_Call, context.temp_allocator)
	base.queue_drain(&s.calls, &pending)
	for &c in pending {
		c.procedure(s, c.data if c.done != nil else raw_data(c.copied[:c.size]))
		if c.done != nil {sync.sema_post(c.done)}
	}
}

// What calls do (the server's thread only).

// explode_by: an explosion of radius in the world of the player called
// name (or the in-process host's, name ""), centred on the block p.
explode_by :: proc(s: ^Server, name: string, p: game.Block_Pos, radius: f64) {
	c, playing := seat(s, name)
	if !playing {return}
	action := action_begin(c.world, actor_of(s, c), .Explosion)
	explode(c.world, {f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5}, radius, action)
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
