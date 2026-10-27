package server

import "core:fmt"
import "core:slice"
import "core:strings"

import "../base"
import "../common/game"

// The server's state hash (docs/determinism.md): what a tick left behind, in
// sections, so a divergence names where it began. Hashing runs only on
// stepped servers: a live tick costs nothing more.

Hash_Section :: enum u8 {
	Clock,
	Rules,
	Players,
	Inventories,
	Entities,
	Chunks,
	Liquids,
	Containers,
	Gates,
	Random,
	Ledger,
}

Hash_Sections :: bit_set[Hash_Section]

State_Hash :: struct {
	tick:     u64,
	root:     u64,
	sections: [Hash_Section]u64,
}

// Perturb is tests only: into the state tick `tick` leaves, it puts one ulp more
// in a value, the deliberately introduced nondeterminism.
Perturb :: struct {
	tick: u64,
	what: Perturb_Kind,
}

Perturb_Kind :: enum u8 {
	None,
	Entity_Yaw,
	Player_Velocity,
}

@(private = "file")
Sink :: struct {
	h: game.Hasher,
	b: ^strings.Builder, // set: dump lines instead of a hash (and every loaded chunk)
}

@(private = "file")
fold :: proc(k: ^Sink, path: string, v: any) {
	if k.b != nil {
		game.dump_value(k.b, path, v)
	} else {
		game.hash_value(&k.h, v, path)
	}
}

// wpath names a field of world i: the home world's are bare, the others' are
// under worlds[i].
@(private = "file")
wpath :: proc(i: int, field: string) -> string {
	return field if i == 0 else fmt.tprintf("worlds[%d].%s", i, field)
}

@(private = "file")
section :: proc(s: ^Server, sec: Hash_Section, k: ^Sink) {
	switch sec {
	case .Clock:
		tick := s.tick
		fold(k, "tick", tick)
		for w, i in s.worlds {fold(k, wpath(i, "clock"), w.clock)}
	case .Rules:
		for w, i in s.worlds {fold(k, wpath(i, "rules"), w.rules)}
	case .Players:
		for &c, i in s.clients {
			if c.state != .Playing {continue}
			path := fmt.tprintf("players[%d]", i)
			fold(k, fmt.tprintf("%s.world", path), c.world.address)
			fold(k, fmt.tprintf("%s.player", path), c.player)
			fold(k, fmt.tprintf("%s.look", path), c.look)
			fold(k, fmt.tprintf("%s.health", path), c.health)
			fold(k, fmt.tprintf("%s.max_health", path), c.max_health)
			fold(k, fmt.tprintf("%s.teleported", path), c.teleported)
		}
	case .Inventories:
		for &c, i in s.clients {
			if c.state != .Playing {continue}
			fold(k, fmt.tprintf("inventories[%d]", i), c.inventory)
		}
	case .Entities:
		for w, i in s.worlds {
			fold(k, wpath(i, "next_id"), w.entities.next_id)
			fold(k, wpath(i, "entities"), w.entities.list[:])
		}
	case .Chunks:
		for w, i in s.worlds {
			if k.b != nil { 	// a dump names every loaded chunk
				for pos in loaded_chunks(w) {chunk_line(k, i, pos, &chunks_get(&w.chunks, pos).blocks)}
				continue
			}
			slice.sort_by(w.touched[:], game.chunk_pos_less)
			last: Maybe(game.Chunk_Pos)
			for pos in w.touched {
				if last == pos {continue}
				last = pos
				chunk := chunks_get(&w.chunks, pos)
				if chunk == nil || chunk.state != .Ready {continue}
				chunk_line(k, i, pos, &chunk.blocks)
			}
			clear(&w.touched)
		}
	case .Liquids:
		for w, i in s.worlds {
			fold(k, wpath(i, "updates"), w.updates.heap[:w.updates.count])
		}
	case .Containers:
		for w, i in s.worlds {
			for pos in base.keys_sorted(w.containers, game.block_pos_less, context.temp_allocator) {
				path := wpath(i, fmt.tprintf("containers[%v]", pos))
				fold(k, path, pos)
				fold(k, path, w.containers[pos])
			}
		}
	case .Gates:
		for w, i in s.worlds {fold(k, wpath(i, "gates"), w.gates[:])}
	case .Random:
		for w, i in s.worlds {
			fold(k, wpath(i, "tick_rng"), w.tick_rng)
			fold(k, wpath(i, "command_rng"), w.command_rng)
			fold(k, wpath(i, "entities.rng"), w.entities.rng)
		}
	case .Ledger:
		item_less :: proc(a, b: game.Item) -> bool {return a < b}
		for item in base.keys_sorted(s.ledger.entries, item_less, context.temp_allocator) {
			fold(k, fmt.tprintf("ledger.entries[%d]", item), s.ledger.entries[item])
		}
		for item in base.keys_sorted(s.ledger.baseline, item_less, context.temp_allocator) {
			fold(k, fmt.tprintf("ledger.baseline[%d]", item), s.ledger.baseline[item])
		}
	}
}

// chunk_line folds a chunk by its blocks' hash: a dump names the chunk.
@(private = "file")
chunk_line :: proc(k: ^Sink, world: int, pos: game.Chunk_Pos, blocks: ^game.Chunk_Blocks) {
	h := game.hasher_make()
	game.hash_chunk_blocks(&h, blocks)
	hash := game.hasher_finish(h)
	fold(k, wpath(world, fmt.tprintf("chunks[(%d, %d, %d)]", pos.x, pos.y, pos.z)), hash)
}

// state_hash hashes the state a tick left, and chains it to the ticks before.
// It clears what the chunks section collects: call it once per tick.
state_hash :: proc(s: ^Server) -> (r: State_Hash) {
	r.tick = s.tick
	chain := game.hasher_make()
	game.hasher_mix(&chain, s.hash_root)
	game.hasher_mix(&chain, s.tick)
	for sec in Hash_Section {
		k := Sink {
			h = game.hasher_make(),
		}
		section(s, sec, &k)
		r.sections[sec] = game.hasher_finish(k.h)
		game.hasher_mix(&chain, r.sections[sec])
	}
	r.root = game.hasher_finish(chain)
	s.hash_root = r.root
	return
}

// loaded_chunks: the ready chunks of w, sorted.
@(private = "file")
loaded_chunks :: proc(w: ^World) -> []game.Chunk_Pos {
	positions := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in w.chunks.by_pos {
		if chunk := chunks_get(&w.chunks, pos); chunk.state == .Ready {append(&positions, pos)}
	}
	slice.sort_by(positions[:], game.chunk_pos_less)
	return positions[:]
}

// hash_chunks folds the blocks of these chunks of w (all loaded), in the order
// given: sorted, so a client hashing its own copies of the same chunks gets the
// same value (a checkpoint).
hash_chunks :: proc(w: ^World, positions: []game.Chunk_Pos) -> u64 {
	h := game.hasher_make()
	for pos in positions {
		game.hash_chunk(&h, pos, &chunks_get(&w.chunks, pos).blocks)
	}
	return game.hasher_finish(h)
}

// world_hash hashes every loaded chunk of the home world, sorted.
world_hash :: proc(s: ^Server) -> u64 {
	return hash_chunks(s.home, loaded_chunks(s.home))
}

// state_dump writes the dump lines of the sections asked for. (The chunks
// section's list is consumed by state_hash: dump before hashing, or ask for
// the other sections.)
state_dump :: proc(s: ^Server, sections: Hash_Sections, b: ^strings.Builder) {
	for sec in sections {
		fmt.sbprintfln(b, "section %v", sec)
		k := Sink {
			b = b,
		}
		section(s, sec, &k)
	}
}
