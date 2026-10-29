package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import "../base"
import "../common/game"

// M46b's budget: what a save costs the tick on a server holding a lot, and how
// long it takes to land. Budgets are for the CI runner: judged in optimized
// builds only (`base.budget_applies`).

SLICE_BUDGET_US :: 3000
CAPTURE_BUDGET_US :: 4000
COMMIT_BUDGET_TICKS :: 150
BLOCKING_BUDGET_MS :: 1500

// The scene: 200 characters (a full inventory and 300 counters each) not playing,
// one world with 512 chunks of seeded mixed blocks over 16 regions, all loaded,
// 100 chests, 400 entities.
@(private = "file")
budget_scene :: proc(g: ^Grief) {
	s := grief_srv(g)
	w := grief_world(g)
	planks := game.item_of_block(test_reg(), .Planks)
	for i in 0 ..< 200 {
		rec := Player_Record {
			dirty = true,
		}
		for &st in rec.inventory.slots {st = {planks, 7, 0}}
		for k in 0 ..< 300 {counter_set(&rec.stats, fmt.tprintf("budget.%d", k), u64(i * k))}
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

@(test)
test_save_200_characters :: proc(t: ^testing.T) {
	dir := scratch_dir("budget")
	defer delete(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.max_players = 2
	g, ok := grief_open(t, dir, cfg)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	st := &s.store
	w := grief_world(g)
	budget_scene(g)
	// (the world sweeps what nobody wants every 10 s: begin just after one)
	for s.tick % UNLOAD_SWEEP_TICKS != 1 {run(g, 1)}
	// The save worker, as a real server has it.
	base.jobs_init(&st.jobs, "save", 1, context.allocator)
	st.jobs_ready = true
	generation := st.generation

	// Capture.
	// (the thread's CPU time: the suite runs other tests on other threads, and
	// a core taken from this one is not the capture's cost)
	start := base.thread_cpu_us()
	testing.expect(t, save_begin(s), "the capture failed")
	capture := base.thread_cpu_us() - start
	if base.budget_applies() {
		testing.expectf(t, capture <= CAPTURE_BUDGET_US, "capture took %d us", capture)
	}

	// Slices, a tick each; then the worker, a tick at a time.
	ticks := 0
	for st.job != nil || st.inflight != nil {
		run(g, 1)
		ticks += 1
		if !testing.expect(
			t,
			ticks <= 10 * COMMIT_BUDGET_TICKS,
			"the save never committed",
		) {return}
	}
	testing.expect_value(t, st.generation, generation + 1)
	if base.budget_applies() {
		testing.expectf(t, ticks <= COMMIT_BUDGET_TICKS, "the save took %d ticks", ticks)
		testing.expectf(
			t,
			st.slice_worst_us <= SLICE_BUDGET_US,
			"the largest slice took %d us",
			st.slice_worst_us,
		)
	}
	log.infof(
		"save budget: capture %d us, largest slice %d us, %d ticks",
		capture,
		st.slice_worst_us,
		ticks,
	)

	// A full blocking save: everything changed again.
	for pos in w.chunks.by_pos {mark_edited(w, pos)}
	for _, &r in st.players {r.dirty = true}
	from := base.thread_cpu_us() // (the thread's CPU time, as for the capture)
	testing.expect(t, save(s), "the blocking save failed")
	blocking := (base.thread_cpu_us() - from) / 1000
	if base.budget_applies() {
		testing.expectf(
			t,
			blocking <= BLOCKING_BUDGET_MS,
			"the blocking save took %d ms",
			blocking,
		)
	}
	log.infof("save budget: blocking save %d ms", blocking)
}
