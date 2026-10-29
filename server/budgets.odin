package server

import "core:fmt"

import "../base"
import "../common/game"

// The server's timed scenes (docs/plan.md, T5; `build bench budgets`). A test
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
budget_world :: proc(h: ^Harness) -> (w: ^World, ok: bool) {
	config := harness_world()
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
	updates_run(w)
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

// budget_flood: M11's flood: a 100 x 100 sheet of water 8 blocks over a
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

// budget_journal: the journal's cost under M11's flood (10 000 flowing
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
