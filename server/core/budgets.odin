package core

import "base:runtime"
import "core:fmt"
import "core:strings"

import "common:base"
import "common:game"

// The server's timed scenes (`build bench budgets`). A test
// never asserts a time: the tests call these for what the scene does (a save
// that commits, 10 000 blocks flowing, an audit with no lines) and
// tools/bench/budgets.odin judges what they cost, in a release build, against
// the budgets beside it. Every scene is headless (no player, nothing in the
// network) and reads the thread's CPU time, so the work is measured, not
// the scheduler or the other threads of a test run. The scenes that need a
// loaded world put one in with `chunks_insert` and run the world's part of a
// tick themselves (`budget_world_tick`): a world nobody stands in would be
// unloaded by the server's own sweep.

// ---- the save ----

Budget_Save :: struct {
	capture_us:     i64, // `save_begin`: what the tick pays to start a save
	slice_worst_us: i64, // the largest slice the save is cut into
	ticks:          int, // ticks until it committed
	committed:      bool,
	blocking_ms:    i64, // a full blocking save of everything changed again
	blocking_ok:    bool,
}

// budget_save_scene: 200 characters (a full inventory and 300 counters each)
// not playing, one world with 512 chunks of seeded mixed blocks over 16
// regions, all loaded, 100 chests, 400 entities.
@(private = "file")
budget_save_scene :: proc(s: ^Server) {
	w := s.home
	planks := game.item_of_block(s.registry, .Planks)
	name: [32]u8
	for i in 0 ..< 200 {
		rec := Player_Record {
			dirty = true,
		}
		for &st in rec.inventory.slots {st = {planks, 7, 0}}
		for k in 0 ..< 300 {
			counter_set(&rec.stats, fmt.bprintf(name[:], "budget.%d", k), u64(i * k))
		}
		s.store.players[fmt.aprintf("budget%03d", i)] = rec
	}
	rng := base.rng_make(0xb0d6e7)
	palette := [?]game.Block{.Stone, .Dirt, .Grass, .Sand, .Planks, .Cobblestone, .Leaves, .Air}
	array := new(game.Block_Array, context.temp_allocator)
	for n in 0 ..< 512 {
		region := n / 32
		k := n % 32
		pos := game.Chunk_Pos {
			(i32(region % 4) + 8) * game.REGION_SIZE + i32(k % 16),
			0,
			(i32(region / 4) + 8) * game.REGION_SIZE + i32(k / 16),
		}
		i := 0
		for i < len(array) { 	// runs of 1 to 16 blocks
			block := palette[base.rng_u32(&rng) % len(palette)]
			for _ in 0 ..< 1 + base.rng_u32(&rng) % 16 {
				if i < len(array) {array[i] = block; i += 1}
			}
		}
		held: [1]game.Block_Entity
		if n < 100 { 	// a chest in it
			array[game.local_index({5, 5, 5})] = .Chest
			chest := game.Block_Entity {
				local = u16(game.local_index({5, 5, 5})),
				kind  = .Container,
			}
			for &st in chest.slots {st = {planks, 3, 0}}
			held = {chest}
		}
		chunks_insert(&w.chunks, pos, .Air, array, held[:] if n < 100 else nil)
		mark_edited(w, pos)
	}
	for n in 0 ..< 400 {
		e := entity_spawn(w, .Item, {f64(1000 + n), 200, 1000}, false)
		if e != nil {e.stack = {planks, 5, 0}}
	}
}

// budget_save: the scene saved as a running server saves, then once more
// blocking. dir is the world's directory (the caller removes it). ok is false
// when the server would not start or the capture failed; a save that never
// commits is `committed = false` after max_ticks.
budget_save :: proc(dir: string, max_ticks: int) -> (r: Budget_Save, ok: bool) {
	h := new(Harness)
	defer free(h)
	config := harness_world()
	config.save_dir = dir
	config.view_radius, config.view_height = 7, 2
	if !harness_start(h, config) {return}
	defer harness_stop(h)
	s := &h.srv
	st := &s.store
	budget_save_scene(s)
	// (the world sweeps what nobody wants every 10 s: begin just after one)
	for s.tick % UNLOAD_SWEEP_TICKS != 1 {harness_step(h)}
	// The save worker, as a real server has it.
	base.jobs_init(&st.jobs, "save", 1, context.allocator)
	st.jobs_ready = true
	generation := st.generation

	start := base.thread_cpu_us()
	if !save_begin(s) {return}
	r.capture_us = base.thread_cpu_us() - start
	for st.job != nil || st.inflight != nil {
		if r.ticks >= max_ticks {return r, true}
		harness_step(h)
		r.ticks += 1
	}
	r.committed = st.generation == generation + 1
	r.slice_worst_us = st.slice_worst_us

	// A full blocking save: everything changed again.
	for pos in s.home.chunks.by_pos {mark_edited(s.home, pos)}
	for _, &rec in st.players {rec.dirty = true}
	from := base.thread_cpu_us()
	r.blocking_ok = save(s)
	r.blocking_ms = (base.thread_cpu_us() - from) / 1000
	return r, true
}

// ---- the audit ----

// budget_audit: 200 players with full inventories and 3000 item entities;
// how many lines the audit gave (none: it balances) and its CPU time.
budget_audit :: proc(reg: ^game.Registry) -> (lines: int, us: i64) {
	s := new(Server)
	defer free(s)
	s.clients = make([]Client, 200)
	defer delete(s.clients)
	w := new(World)
	defer free(w)
	defer delete(w.entities.list)
	w.server = s
	append(&s.worlds, w)
	defer delete(s.worlds)
	defer ledger_destroy(&s.ledger)
	given :: proc(s: ^Server, st: game.Stack) {
		row := s.ledger.entries[st.item]
		row[.Give] += i64(st.count)
		s.ledger.entries[st.item] = row
	}
	items := game.every_item(reg, context.temp_allocator)
	for &c, i in s.clients {
		c.state = .Playing
		for &st, k in c.inventory.slots {
			st = {items[(i + k) % len(items)], 1 + k % 5, 0}
			given(s, st)
		}
	}
	for i in 0 ..< 3000 {
		st := game.Stack{items[i % len(items)], 1 + i % 7, 0}
		append(&w.entities.list, Entity{kind = .Item, stack = st})
		given(s, st)
	}
	start := base.thread_cpu_us()
	found := audit(s)
	us = base.thread_cpu_us() - start
	free_all(context.temp_allocator)
	return len(found), us
}

// ---- the counters ----

BUDGET_PLAYERS :: 200
BUDGET_COUNTERS :: 3000

// budget_counters: BUDGET_PLAYERS players of BUDGET_COUNTERS counters each,
// written as a player file and read back. building_us is what making the
// counters cost on this thread in this run (the same hashing, copying and
// allocating), the reference the work is judged against: a fixed number of
// seconds would measure the machine. bad: players that did not read back
// whole.
budget_counters :: proc(reg: ^game.Registry) -> (building_us, work_us: i64, bytes, bad: int) {
	records := make([]Player_Record, BUDGET_PLAYERS)
	defer {
		for &r in records {counters_free(&r.stats)}
		delete(records)
	}
	built := base.thread_cpu_us()
	name: [64]u8
	for &r, i in records {
		for k in 0 ..< BUDGET_COUNTERS {
			counter_add(
				&r.stats,
				fmt.bprintf(name[:], "blocks.mined.block_%d_%d", i % 7, k),
				u64(k + 1),
			)
		}
	}
	start := base.thread_cpu_us()
	for &r in records {
		json := player_json(reg, &r)
		bytes += len(json)
		back, ok := player_parse(reg, json)
		if !ok || len(back.stats) != BUDGET_COUNTERS {bad += 1}
		counters_free(&back.stats)
		free_all(context.temp_allocator) // (a server's tick does the same: the cost is the work, not a heap grown to hold every player's text)
	}
	return start - built, base.thread_cpu_us() - start, bytes, bad
}

// ---- the world's tick ----

// budget_world: a headless server whose home world holds air in 8 x 5 x 8
// chunks round the origin (blocks -64 to 63 sideways and 0 to 79 up), room for
// the scenes' platform, pool and fills.
@(private = "file")
budget_world :: proc(h: ^Harness, extra: []game.Pack_Source = nil) -> (w: ^World, ok: bool) {
	config := harness_world()
	config.extra_packs = extra
	config.journal_timed = true
	config.view_radius, config.view_height = 7, 2 // (the pool's size: every chunk the scenes hold)
	if !harness_start(h, config) {return}
	w = h.srv.home
	for y in i32(0) ..< 5 {
		for z in i32(-4) ..< 4 {
			for x in i32(-4) ..< 4 {chunks_insert(&w.chunks, {x, y, z}, .Air, nil)}
		}
	}
	return w, true
}

// budget_world_tick: what a server's tick does to a world with changes and
// flowing water and nobody in it: the clock, the block updates, the changes'
// flush and the journal.
budget_world_tick :: proc(s: ^Server, w: ^World) {
	s.tick += 1
	sim_run_scheduled(w)
	changes_flush(w)
	journal_tick(w)
	free_all(context.temp_allocator)
}

// budget_platform: the stone platform two blocks thick with a pool's worth of
// room above it, the flood's and the journal's first change.
@(private = "file")
budget_platform :: proc(w: ^World) {
	act := world_act(w, .Command)
	stone := Bulk_Edit {
		shape = Box{{-51, 60, -51}, {50, 61, 50}},
		op    = .Set,
		block = .Stone,
	}
	bulk_edit(w, stone, act)
	air := stone
	air.shape, air.block = Box{{-50, 61, -50}, {49, 61, 49}}, .Air
	bulk_edit(w, air, act)
}

// ---- the flood ----

Budget_Flood :: struct {
	worst_us: i64, // the slowest world tick
	most:     int, // the most block updates waiting
}

// budget_flood: the flood: a 100 x 100 sheet of water 8 blocks over a
// platform with a hole in it, 8 seconds of ticks.
budget_flood :: proc() -> (r: Budget_Flood, ok: bool) {
	h := new(Harness)
	defer free(h)
	w := budget_world(h) or_return
	defer harness_stop(h)
	s := &h.srv
	budget_platform(w)
	water := Bulk_Edit {
		shape = Box{{-50, 68, -50}, {49, 68, 49}},
		op    = .Set,
		block = .Water,
	}
	bulk_edit(w, water, world_act(w, .Command))
	for _ in 0 ..< 8 * game.TICK_RATE {
		start := base.thread_cpu_us()
		budget_world_tick(s, w)
		r.worst_us = max(r.worst_us, base.thread_cpu_us() - start)
		r.most = max(r.most, w.updates.count)
	}
	return r, true
}

// ---- the journal ----

Budget_Journal :: struct {
	share:       f64, // the journal's ticks over all the ticks'
	per_tick_us: f64, // its mean cost in a tick, on the thread's CPU time
	head:        u64, // entries written
}

// budget_journal: the journal's cost under the flood (10 000 flowing
// blocks), 20 blasts of radius 6 and ten 32 x 32 x 32 fills over 600 ticks.
budget_journal :: proc() -> (r: Budget_Journal, ok: bool) {
	h := new(Harness)
	defer free(h)
	w := budget_world(h) or_return
	defer harness_stop(h)
	s := &h.srv
	total: i64
	cpu_us: i64
	measure :: proc(
		total, cpu_us: ^i64,
		body: proc(s: ^Server, w: ^World, n: int),
		s: ^Server,
		w: ^World,
		n: int,
	) {
		from := base.ticks()
		cpu := base.thread_cpu_us()
		body(s, w, n)
		total^ += i64(base.ticks() - from)
		cpu_us^ += base.thread_cpu_us() - cpu
	}
	measure(&total, &cpu_us, proc(s: ^Server, w: ^World, _: int) {
			budget_platform(w)
			water := Bulk_Edit {
				shape = Box{{-50, 68, -50}, {49, 68, 49}},
				op    = .Set,
				block = .Water,
			}
			bulk_edit(w, water, world_act(w, .Command))
		}, s, w, 0)
	for tick in 0 ..< 600 {
		measure(&total, &cpu_us, proc(s: ^Server, w: ^World, tick: int) {
				switch {
				case tick % 30 == 10:
					n := tick / 30
					if n < 20 {
						at := [3]f64{f64(-40 + (n % 5) * 20), 42, f64(-40 + (n / 5) * 20)}
						explode(w, at, 6, action_begin(w, {.World, "", false}, .Explosion))
					}
				case tick % 60 == 20:
					n := i32(tick / 60)
					fill := Bulk_Edit {
						shape = Box{{n * 3 - 20, 8, -20}, {n * 3 + 11, 39, 11}},
						op    = .Set,
						block = .Stone if n % 2 == 0 else .Dirt,
					}
					bulk_edit(w, fill, world_act(w, .Command))
				}
				budget_world_tick(s, w)
			}, s, w, tick)
	}
	r.share = f64(w.journal.cost_ticks) / f64(total)
	r.per_tick_us = r.share * f64(cpu_us) / 600
	r.head = w.journal.head
	return r, true
}

// ---- the rules ----

Budget_Rules :: struct {
	worst_us:   i64, // the slowest world tick
	most:       int, // the most cells waiting at once
	runs:       int, // rule runs
	run_ns:     f64, // the ticks' CPU time over the runs, ns
	max_reads:  i32, // the most one run read (within the rule's cost)
	compile_us: i64, // compiling the test pack and 500 rules near the limits
}

// budget_rule_text: n rules near the limits (cost 3 000 to 4 000): a box of 9 x 9 x 9 read
// once or twice, picks, chances and writes, each with its own numbers.
budget_rule_text :: proc(n: int, allocator: runtime.Allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "{")
	for i in 0 ..< n {
		if i > 0 {strings.write_string(&sb, ",")}
		fmt.sbprintf(
			&sb,
			`"gen%d": {{"blocks": ["sim_test:creep"], "trigger": "random", "do": [
  "require count box(-4..4, -4..4, -4..4) is @opaque >= %d",
  {{"repeat": 4, "do": ["pick t -%d..%d -1..1 -%d..%d", "require t is #sim_test:flammable", "chance %d", "set t sim_test:fire", "set t.potency self.potency + 1"]}},
  {{"if": "any box(-4..4, 0..0, -4..4) is voxiverse:air and self.light >= %d", "then": ["set above voxiverse:air"], "else": ["schedule self %d"]}}
]}}`,
			i,
			i % 300,
			1 + i % 4,
			1 + i % 4,
			1 + i % 4,
			1 + i % 4,
			2 + i % 7,
			i % 15,
			1 + i % 1200,
		)
	}
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// budget_rules: 10 000 creep cells scheduled at once (a 100 x 100 layer at potency 15 on a
// stone slab), 300 ticks; and the time to compile the test pack with 500 more rules.
budget_rules :: proc() -> (r: Budget_Rules, ok: bool) {
	a := runtime.default_allocator()
	packs := make([]game.Pack_Source, 1, a)
	defer delete(packs, a)
	packs[0] = game.sim_test_pack(allocator = a)
	h := new(Harness)
	defer free(h)
	w := budget_world(h, packs) or_return
	defer harness_stop(h)
	s := &h.srv
	creep, _ := game.registry_block(s.registry, "sim_test:creep")
	potency, _ := game.registry_channel(s.registry, "sim_test:potency")
	act := world_act(w, .Command)
	bulk_edit(w, {shape = Box{{-50, 58, -50}, {49, 61, 49}}, op = .Set, block = .Stone}, act)
	bulk_edit(w, {shape = Box{{-50, 62, -50}, {49, 62, 49}}, op = .Set, block = creep}, act)
	for z in i32(-50) ..< 50 {
		for x in i32(-50) ..< 50 {set_channel(w, {x, 62, z}, potency, 15, act)}
	}
	runs_before := w.updates.run
	total := i64(0)
	for _ in 0 ..< 300 {
		start := base.thread_cpu_us()
		budget_world_tick(s, w)
		took := base.thread_cpu_us() - start
		total += took
		r.worst_us = max(r.worst_us, took)
		r.most = max(r.most, w.updates.count)
	}
	r.runs = w.updates.run - runs_before
	r.run_ns = f64(total) * 1000 / f64(max(r.runs, 1))
	// Compiling: the registry with and without 500 rules near the limits.
	build :: proc(extra: []game.Pack_File, a: runtime.Allocator) -> (us: i64, built: bool) {
		sources := []game.Pack_Source {
			game.base_pack_source(context.temp_allocator),
			game.sim_test_pack(extra, allocator = context.temp_allocator),
		}
		start := base.thread_cpu_us()
		reg, errs := game.registry_build(sources, .Server, a)
		us = base.thread_cpu_us() - start
		if reg == nil {
			for e in errs {fmt.eprintln(game.pack_error_text(e))}
			return us, false
		}
		game.registry_destroy(reg)
		return us, true
	}
	plain := build(nil, a) or_return
	text := budget_rule_text(500, a)
	defer delete(text, a)
	with := build([]game.Pack_File{{"data/sim/gen.json", transmute([]u8)text}}, a) or_return
	r.compile_us = max(with - plain, 0)
	return r, true
}

// ---- random ticks ----

Budget_Random :: struct {
	worst_us: i64, // the slowest random_ticks call
	runs:     int, // random rules run
	run_ns:   f64, // the calls' CPU time over the runs, ns
}

// budget_random_ticks: 512 ready, non-uniform chunks (a seeded mix of grass, dirt, farmland,
// wheat stages, water and lamps), random_tick_speed 3, 600 calls of random_ticks alone.
budget_random_ticks :: proc() -> (r: Budget_Random, ok: bool) {
	h := new(Harness)
	defer free(h)
	w := budget_world(h) or_return
	defer harness_stop(h)
	for y in i32(5) ..< 8 {
		for z in i32(-4) ..< 4 {
			for x in i32(-4) ..< 4 {chunks_insert(&w.chunks, {x, y, z}, .Air, nil)}
		}
	}
	mix := [?]game.Block {
		.Grass,
		.Grass,
		.Grass,
		.Dirt,
		.Dirt,
		.Farmland,
		.Farmland_Moist,
		.Wheat_0,
		.Wheat_3,
		.Wheat_5,
		.Wheat_7,
		.Water,
		.Lamp,
		.Stone,
		.Air,
		.Air,
	}
	gen := base.rng_make(49)
	act := world_act(w, .Command)
	for y in i32(0) ..< 8 {
		for z in i32(-4) ..< 4 {
			for x in i32(-4) ..< 4 {
				origin := game.chunk_origin({x, y, z})
				for _ in 0 ..< 400 {
					i := int(base.rng_u32(&gen)) & (game.CHUNK_VOLUME - 1)
					b := mix[base.rng_int_max(&gen, len(mix))]
					set_block(w, origin + game.local_from_index(i), b, act)
				}
			}
		}
	}
	w.rules.random_tick_speed = 3
	total := i64(0)
	for _ in 0 ..< 600 {
		start := base.thread_cpu_us()
		random_ticks(w)
		took := base.thread_cpu_us() - start
		total += took
		r.worst_us = max(r.worst_us, took)
		free_all(context.temp_allocator)
	}
	r.runs = w.random_runs
	r.run_ns = f64(total) * 1000 / f64(max(r.runs, 1))
	return r, true
}
