package server

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../base"
import "../game"
import "../worldgen"

// Worlds: a universe (the server) has worlds, each a voxel space of its own:
// its generator and parameters, rules, clock, chunks, entities, liquids,
// spawn, and save. A world's memory is an arena of its own, freed whole
// when it unloads.

World :: struct {
	server:       ^Server,
	address:      game.Address,
	arena:        virtual.Arena,
	dir:          string, // its save directory ("": not saved)
	generator:    worldgen.Kind,
	seed:         i64,
	params:       worldgen.Params, // the Earth generator's (worldgen.*; chunks.gen has a copy)
	rules:        game.Rules,
	clock:        f64, // world time (game/time.odin)
	spawn:        World_Spawn, // where arrivals land (spawn.odin)
	chunks:       Chunk_Store,
	tops:         map[[2]i32]i32, // edited column tops (columns.odin)
	natural:      []Natural_Slot, // natural column tops (columns.odin)
	entities:     Entities, // (entities.odin)
	changes:      Changes, // blocks changed this tick (changes.odin)
	stats:        Counters, // the world's totals (stats.odin; <world>/stats.json)
	tick_rng:     base.Rng, // which blocks get random ticks (random_ticks.odin)
	command_rng:  base.Rng, // @r (commands_world.odin)
	updates:      Updates, // scheduled block updates: flowing water (liquids.odin)
	saved:        map[game.Chunk_Pos][]u8, // edited chunks not loaded: encoded blocks (save.odin)
	regions:      map[game.Region_Pos]bool, // read from disk; true = changed since written
	started:      bool, // world_start ran (its chunks and the rest exist)
	idle_since:   u64, // the last tick someone was in it
	touched:      [dynamic]game.Chunk_Pos, // chunks changed this tick (a stepped server's hash; heap)
	gates:        [dynamic]Gate, // active: dialing or open (gates.odin)
	containers:   map[game.Block_Pos]Container, // chests' contents, by position (containers.odin; heap)
	tops_pending: map[[2]i32]struct{}, // columns whose natural tops a worker is working out (heap)
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
	gen := worldgen.generator_make(w.generator, w.seed, w.params)
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
	w.tick_rng = base.rng_make(u64(w.seed) ~ 0x71c4_0001)
	w.command_rng = base.rng_make(u64(w.seed) ~ 0xc0de_0001)
	w.started = true
	spawn_choose(w)
	load_entities(w)
	load_containers(w)
	load_stats(w)
	ledger_world_scope(w, .Scope_In)
	return true
}

// world_close frees everything the world has (its save written first by
// the caller).
world_close :: proc(w: ^World) {
	if w.started {
		ledger_world_scope(w, .Scope_Out)
		chunks_destroy(&w.chunks)
		entities_destroy(&w.entities)
		virtual.arena_destroy(&w.arena)
	}
	delete(w.tops)
	delete(w.gates)
	delete(w.touched)
	delete(w.containers)
	delete(w.tops_pending)
	for _, bytes in w.saved {delete(bytes)}
	delete(w.saved)
	delete(w.regions)
	counters_free(&w.stats)
	delete(w.dir)
	free(w)
}

// WORLD_IDLE_SECONDS: how long a world (not the home world) stays loaded
// with nobody in it (Config.world_idle overrides: tests).
WORLD_IDLE_SECONDS :: 10

// world_kind: what kind of world an address is: its generator parameters
// and rules, from the address alone (so it is the same kind of world in any
// universe), each within its range; the terrain's seed mixes in the
// universe's. The home world is Earth's, unchanged.
world_kind :: proc(w: ^World) {
	s := w.server
	a := w.address
	if w == s.home {return}
	h := game.address_hash(a)
	w.seed = i64(u64(s.config.seed) ~ h * 0x9e37_79b9_7f4a_7c15)
	w.generator = .Earth
	n := h
	pick :: proc(n: ^u64, lo, hi: f32) -> f32 {
		n^ = n^ * 6364136223846793005 + 1442695040888963407
		return lo + f32(n^ >> 40) / f32(1 << 24) * (hi - lo)
	}
	p := &w.params
	p^ = worldgen.PARAMS_DEFAULTS
	p.sea_level = i32(pick(&n, -16, 24))
	p.continent_scale = pick(&n, 800, 4000)
	p.climate_scale = pick(&n, 800, 4000)
	p.mountain_height = pick(&n, 30, 200)
	p.hill_height = pick(&n, 4, 30)
	p.ocean_depth = pick(&n, 10, 80)
	p.overhang = pick(&n, 0, 20)
	p.river_width = pick(&n, 0, 0.12)
	p.cave_size = pick(&n, 0.04, 0.2)
	p.tree_density = pick(&n, 0, 2)
	p.plant_density = pick(&n, 0, 2)
	p.warmth = pick(&n, -1, 1)
	p.wetness = pick(&n, -1, 1)
	p.palette = f32(int(pick(&n, 0, f32(len(worldgen.PALETTES)) - 0.001)))
	r := &w.rules
	r^ = game.RULES_DEFAULTS
	r.gravity = pick(&n, 16, 48)
	r.day_length = f32(int(pick(&n, 600, 2400)) / 60 * 60)
}

// world_find: the loaded world at address, if any.
world_find :: proc(s: ^Server, a: game.Address) -> ^World {
	for w in s.worlds {if w.address == a {return w}}
	return nil
}

// world_load: the world at address, loaded (from its save, or new) if it
// was not; nil (logged) if it cannot be.
world_load :: proc(s: ^Server, a: game.Address) -> ^World {
	if w := world_find(s, a); w != nil {return w}
	if !game.address_valid(a) {return nil}
	w := world_make(s)
	w.address = a
	world_kind(w)
	if !world_dir_open(w) || !world_start(w) {
		world_close(w)
		return nil
	}
	w.idle_since = s.tick
	append(&s.worlds, w)
	log.infof("server world loaded address=%s worlds=%d", game.address_dir(a), len(s.worlds))
	return w
}

// worlds_unload_idle saves and frees the worlds nobody has been in for a
// while (never the home world).
worlds_unload_idle :: proc(s: ^Server) {
	idle :=
		u64(s.config.world_idle * game.TICK_RATE) if s.config.world_idle > 0 else WORLD_IDLE_SECONDS * game.TICK_RATE
	for i := len(s.worlds) - 1; i >= 1; i -= 1 {
		w := s.worlds[i]
		occupied := false
		for &c in s.clients {occupied ||= c.state == .Playing && c.world == w}
		if occupied || len(w.gates) > 0 {w.idle_since = max(w.idle_since, s.tick)}
		if s.tick < w.idle_since + idle {continue}
		world_save(w)
		log.infof("server world unloaded address=%s", game.address_dir(w.address))
		world_close(w)
		ordered_remove(&s.worlds, i)
	}
}

// travel takes c to the world at address (its spawn, or there: a place in
// it); "" or why not.
travel :: proc(s: ^Server, c: ^Client, a: game.Address, there: Maybe(Place) = nil) -> string {
	to := world_load(s, a)
	if to == nil {return "that world cannot be reached"}
	from := c.world
	back := Place{from.address, c.player.position, c.look}
	if to != from {
		// The client drops everything of the world it leaves.
		clear(&c.has)
		clear(&c.columns)
		replica_flush(s, c) // (what the last world said, before it is dropped)
		c.cursor = 0
		c.landing = nil
		c.action_count = 0 // (edits and shots were for the last world)
		c.world = to
		send_message(s, c, game.World_Changed{to.address, to.rules})
		game.sender_reset(&c.tx) // (the client drops its keyed records and snapshots)
		replica_seed(s, c)
		c.clock_pending = true
		selection_set(s, c, {}) // (it was in the last world)
		if m, ok := worldgen_variables(to); ok {state_put(s, c, .Variables, &m)}
		log.infof(
			"server travel name=%s from=%s to=%s",
			client_name(c),
			game.address_dir(from.address),
			game.address_dir(a),
		)
	}
	if p, ok := there.?; ok {
		land(s, c, p.position, p.look, .Exact)
	} else {
		land_at_spawn(s, c)
	}
	c.back = back
	return ""
}

// go_to takes c to place, travelling first if it is in another world.
go_to :: proc(s: ^Server, c: ^Client, p: Place, mode := game.Landing_Mode.Exact) -> string {
	if p.world != c.world.address {return travel(s, c, p.world, p)}
	land(s, c, p.position, p.look, mode)
	return ""
}

// --- Commands ---

// admin_travel: travel <address> [character] (another's: world.travel.others).
@(private)
admin_travel :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	// The address may be two words (a world, its galaxy): all of them, else
	// all but the last, which is then a character.
	here := c.world.address.galaxy
	a, ok := game.address_parse(strings.join(args, " ", context.temp_allocator), here)
	who := c
	if !ok && len(args) > 1 {
		a, ok = game.address_parse(
			strings.join(args[:len(args) - 1], " ", context.temp_allocator),
			here,
		)
		if !ok {return false}
		if !allowed(s, c, "world.travel.others") {
			notice(s, c, "You may not send others here (world.travel.others)")
			return true
		}
		who = client_by_name(s, args[len(args) - 1])
		if who == nil {
			notice(s, c, fmt.tprintf("&c%s is not here", args[len(args) - 1]))
			return true
		}
	}
	if !ok {
		notice(
			s,
			c,
			"&cNot an address: seven symbols (a world in this galaxy), fifteen, or the directory form",
		)
		return true
	}
	notice_if(s, c, travel(s, who, a))
	return true
}

// admin_address: this world's address, as shared and as a directory.
@(private)
admin_address :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	a := c.world.address
	home := " (the home world)" if c.world == s.home else ""
	notice(s, c, fmt.tprintf("%s%s  %s", game.address_text(a), home, game.address_dir(a)))
	return true
}

// admin_worlds: the loaded worlds and who is in each; how many are saved.
@(private)
admin_worlds :: proc(s: ^Server, c: ^Client, args: []string) -> bool {
	for w in s.worlds {
		players := 0
		for &other in s.clients {if other.state == .Playing && other.world == w {players += 1}}
		home := " home" if w == s.home else ""
		notice(s, c, fmt.tprintf("%s%s: %d here", game.address_text(w.address), home, players))
	}
	saved := 0
	if s.store.dir != "" {
		dir := filepath.join({s.store.dir, WORLDS_DIR}, context.temp_allocator) or_else WORLDS_DIR
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries {if e.type == .Directory {saved += 1}}
	}
	notice(s, c, fmt.tprintf("%d loaded, %d saved", len(s.worlds), saved))
	return true
}
