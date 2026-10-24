package server

import "core:log"
import "core:mem/virtual"

import "../game"
import "../worldgen"

// Worlds: a universe (the server) has worlds, each a voxel space of its own:
// its generator and parameters, rules, clock, chunks, entities, liquids,
// spawn, and save. A world's memory is an arena of its own, freed whole
// when it unloads.

World :: struct {
	server:    ^Server,
	address:   game.Address,
	arena:     virtual.Arena,
	dir:       string, // its save directory ("": not saved)
	generator: worldgen.Kind,
	seed:      i64,
	params:    worldgen.Params, // the Earth generator's (worldgen.*; chunks.gen has a copy)
	rules:     game.Rules,
	clock:     f64, // world time (game/time.odin)
	spawn:     World_Spawn, // where arrivals land (spawn.odin)
	chunks:    Chunk_Store,
	tops:      map[[2]i32]i32, // edited column tops (columns.odin)
	natural:   []Natural_Slot, // natural column tops (columns.odin)
	entities:  Entities, // (entities.odin)
	changes:   Changes, // blocks changed this tick (changes.odin)
	updates:   Updates, // scheduled block updates: flowing water (liquids.odin)
	saved:     map[game.Chunk_Pos][]u8, // edited chunks not loaded: encoded blocks (save.odin)
	regions:   map[game.Region_Pos]bool, // read from disk; true = changed since written
	started:   bool, // world_start ran (its chunks and the rest exist)
}

// world_make: a world of the server's with its defaults, not yet started
// (its settings may be read from its save first).
world_make :: proc(s: ^Server) -> ^World {
	w := new(World)
	w^ = {
		server    = s,
		generator = s.config.generator,
		seed      = s.config.seed,
		params    = worldgen.PARAMS_DEFAULTS,
		rules     = s.config.rules if s.config.rules != {} else game.RULES_DEFAULTS,
		clock     = game.NEW_WORLD_TIME,
	}
	return w
}

// world_start: its memory, chunks, entities, spawn; false (logged) if it
// cannot have them.
world_start :: proc(w: ^World) -> bool {
	s := w.server
	if err := virtual.arena_init_growing(&w.arena); err != nil {
		log.errorf("server cannot reserve a world's memory: %v", err)
		return false
	}
	arena := virtual.arena_allocator(&w.arena)
	gen := worldgen.Generator{w.generator, w.seed, w.params}
	if err := chunks_init(&w.chunks, gen, s.capacity, s.config.workers, arena); err != nil {
		log.errorf("server cannot allocate a world: %v", err)
		virtual.arena_destroy(&w.arena)
		return false
	}
	w.natural = make([]Natural_Slot, NATURAL_CACHE, arena)
	if err := updates_init(&w.updates, arena); err != nil {
		log.errorf("server cannot allocate a world's block updates: %v", err)
		chunks_destroy(&w.chunks)
		virtual.arena_destroy(&w.arena)
		return false
	}
	entities_init(&w.entities, w.seed)
	w.started = true
	spawn_choose(w)
	load_entities(w)
	return true
}

// world_close frees everything the world has (its save written first by
// the caller).
world_close :: proc(w: ^World) {
	if w.started {
		chunks_destroy(&w.chunks)
		entities_destroy(&w.entities)
		virtual.arena_destroy(&w.arena)
	}
	delete(w.tops)
	for _, bytes in w.saved {delete(bytes)}
	delete(w.saved)
	delete(w.regions)
	delete(w.dir)
	free(w)
}
