package server

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

import "../base"
import "../common/game"

// M46: the crash harness. Faults injected into the disk layer (not real kills),
// so every point is reproducible: a save is run with the "process" dying at one
// operation, then the universe is recovered and checked, and must be exactly
// the generation before the save or the one it wrote, never a mix.

CRASH_POINTS :: #config(VX_CRASH_POINTS, 1000)

// state_digest: a hash of every file of a universe (relative path and bytes),
// without backups/, telemetry/ and analytics/; journal segments only up to where the
// save's world.cfg says they end.
state_digest :: proc(dir: string) -> u64 {
	files := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &files)
	slice.sort(files[:])
	h := u64(0xcbf29ce484222325)
	for rel in files {
		data, err := os.read_entire_file_from_path(full_path(dir, rel), context.temp_allocator)
		if err != nil {continue}
		if i := strings.index(rel, "/journal/"); i > 0 && strings.has_suffix(rel, ".vxj") {
			cfg, _ := os.read_entire_file_from_path(
				full_path(dir, fmt.tprintf("%s/%s", rel[:i], WORLD_FILE)),
				context.temp_allocator,
			)
			seq, _ := strconv.parse_int(rel[i + len("/journal/"):][:8])
			seg_text, _ := text_value(string(cfg), "journal.segment")
			off_text, _ := text_value(string(cfg), "journal.offset")
			recorded, _ := strconv.parse_int(seg_text)
			offset, _ := strconv.parse_int(off_text)
			if seq > recorded {continue}
			if seq == recorded && offset < len(data) {data = data[:offset]}
		}
		h = hash.fnv64a(transmute([]u8)rel, h)
		h = hash.fnv64a(data, h)
	}
	return h
}

// far_edit: a block changed in a region away from the player (and back).
far_edit :: proc(g: ^Grief, dx, dz: i32) {
	home := g.f
	cmd(g, "tp %d %d %d", home.x + dx, home.y, home.z + dz)
	run(g, 300)
	p := grief_client(g).player.position
	cmd(g, "setblock %d %d %d stone", i32(p.x), i32(p.y) - 1, i32(p.z))
	run(g, 30)
	cmd(g, "tp %d %d %d", home.x, home.y, home.z)
	run(g, 300)
}

// planks_total: the planks in the character's inventory and the chests.
planks_total :: proc(g: ^Grief) -> (total: int) {
	for line in fixture_lines(fixture_expect(g), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		n := len(f)
		if (f[0] == "inventory" || f[0] == "chest") && f[n - 2] == "planks" {
			v, _ := strconv.parse_int(f[n - 1])
			total += v
		}
	}
	return
}

Crash_Setup :: struct {
	base:   string, // the universe at generation 1
	run:    string, // where a run happens
	src:    string,
	batch:  ^Save_Batch, // the second save
	d1, d2: u64,
	ops:    int, // of a clean run of the batch
}


// crash_setup: a stepped server plays, saves (generation 1), plays on and builds
// the second save's batch without running it.
crash_setup :: proc(t: ^testing.T, tag: string) -> (cs: Crash_Setup, ok: bool) {
	// (tests run side by side: each has its own directories)
	cs.src = fmt.aprintf("build/test_%s_src", tag)
	cs.base = fmt.aprintf("build/test_%s_base", tag)
	cs.run = fmt.aprintf("build/test_%s_run", tag)
	src := cs.src
	os.remove_all(src)
	os.remove_all(cs.base)
	g, opened := grief_open(t, src)
	if !opened {grief_close(g); return}
	defer grief_close(g)
	s := grief_srv(g)
	grief_build(g)
	far_edit(g, 600, 0)
	if !testing.expect(t, save(s), "the first save failed") {return}
	testing.expect_value(t, s.store.generation, u64(1))
	// More play: edits in an old region and a new one, a stack out of the chest,
	// the character moved, a protection.
	cmd(g, "fill %s stone", box(g, {0, 3, 4}, {1, 4, 5}))
	far_edit(g, 600, 0)
	far_edit(g, 0, 600)
	chest := at(g, -3, 0, 2)
	m := &g.sess.mirror
	mirror_send(m, game.Use_Block{chest, m.prediction.next_sequence - 1})
	run(g, 3)
	inventory(m, .Click, game.CHEST_BASE)
	inventory(m, .Click, 20)
	run(g, 3)
	testing.expect_value(t, planks_total(g), 10)
	cmd(g, "protect add yard %s", box(g, {0, -1, 4}, {2, 3, 6}))
	cmd(g, "tp %d %d %d", g.f.x + 2, g.f.y, g.f.z + 3)
	run(g, 20)
	if !testing.expect(t, save_collect(s), "the second save could not be collected") {return}
	cs.batch = s.store.staging
	s.store.staging = nil
	copy_tree(src, cs.base)
	cs.d1 = state_digest(cs.base)
	// A clean run: the second generation's digest and the number of operations.
	os.remove_all(cs.run)
	copy_tree(cs.base, cs.run)
	faults := base.Disk_Faults{}
	d := base.Disk {
		faults = &faults,
	}
	rb := cs.batch^
	rb.dir, rb.disk = cs.run, &d
	batch_run(&rb)
	delete(rb.problem, runtime.heap_allocator())
	testing.expect_value(t, rb.problem, "")
	cs.ops = faults.ops
	cs.d2 = state_digest(cs.run)
	testing.expect(t, cs.d1 != cs.d2, "the second save changed nothing")
	for dir in ([]string{cs.base, cs.run}) {
		rep := universe_check(dir)
		testing.expectf(t, rep.ok, "%s does not check: %v", dir, rep.problems[:])
	}
	return cs, true
}

crash_teardown :: proc(cs: ^Crash_Setup) {
	if cs.batch != nil {batch_free(cs.batch)}
	os.remove_all(cs.base)
	os.remove_all(cs.run)
	os.remove_all(cs.src)
	delete(cs.base)
	delete(cs.run)
	delete(cs.src)
}

// crash_run: the second save with the process dying at operation `countdown`;
// then recovery. The digest that is left.
crash_run :: proc(
	t: ^testing.T,
	cs: ^Crash_Setup,
	countdown: int,
	seed: u64,
	power_loss: bool,
) -> u64 {
	os.remove_all(cs.run)
	copy_tree(cs.base, cs.run)
	faults := base.Disk_Faults {
		countdown  = countdown,
		rng        = base.rng_make(seed),
		power_loss = power_loss,
	}
	defer base.disk_faults_destroy(&faults)
	d := base.Disk {
		faults = &faults,
	}
	rb := cs.batch^
	rb.dir, rb.disk = cs.run, &d
	batch_run(&rb)
	delete(rb.problem, runtime.heap_allocator())
	clean := base.Disk{}
	why := store_recover(cs.run, &clean)
	testing.expectf(t, why == "", "countdown %d seed %d: recovery says %s", countdown, seed, why)
	rep := universe_check(cs.run)
	testing.expectf(
		t,
		rep.ok,
		"countdown %d seed %d power %v: the universe does not check: %v",
		countdown,
		seed,
		power_loss,
		rep.problems[:],
	)
	return state_digest(cs.run)
}

// The crash points in CRASH_SHARDS tests, so the runner's threads share them: shard k
// takes the points i with i % CRASH_SHARDS == k (the same countdowns and seeds as one
// test taking them all), in a universe of its own, and must see both outcomes itself.
CRASH_SHARDS :: 4

@(test)
test_save_survives_crashes_0 :: proc(t: ^testing.T) {save_crash_shard(t, 0)}
@(test)
test_save_survives_crashes_1 :: proc(t: ^testing.T) {save_crash_shard(t, 1)}
@(test)
test_save_survives_crashes_2 :: proc(t: ^testing.T) {save_crash_shard(t, 2)}
@(test)
test_save_survives_crashes_3 :: proc(t: ^testing.T) {save_crash_shard(t, 3)}

save_crash_shard :: proc(t: ^testing.T, shard: int) {
	cs, ok := crash_setup(t, fmt.tprintf("crash%d", shard))
	defer crash_teardown(&cs)
	if !ok {return}
	seen: [2]int
	for i := shard; i < CRASH_POINTS; i += CRASH_SHARDS {
		countdown := 1 + (i * 7919) % cs.ops
		dig := crash_run(t, &cs, countdown, u64(i), i % 2 == 1)
		switch dig {
		case cs.d1:
			seen[0] += 1
		case cs.d2:
			seen[1] += 1
		case:
			testing.expectf(
				t,
				false,
				"run %d (operation %d of %d): the universe is neither generation (digest %016x)",
				i,
				countdown,
				cs.ops,
				dig,
			)
		}
		if i % 100 == 0 {
			// It opens, and what the character and the chest hold is one generation's.
			g, opened := grief_open(t, cs.run)
			if opened {
				testing.expectf(
					t,
					planks_total(g) == 10,
					"run %d: planks %d, want 10",
					i,
					planks_total(g),
				)
			}
			grief_close(g)
		}
	}
	testing.expectf(t, seen[0] > 0 && seen[1] > 0, "outcomes: old %d, new %d", seen[0], seen[1])
	fmt.printfln(
		"save crash points, shard %d of %d: %d ops, %d runs: old %d, new %d",
		shard,
		CRASH_SHARDS,
		cs.ops,
		seen[0] + seen[1],
		seen[0],
		seen[1],
	)
}

// All of an operation's points for runs that are short, else every stride-th.
fault_points :: proc(ops: int) -> (n, stride: int) {
	return ops, max(1, ops / 400)
}

// A backup never affects the save; a restore ends as the old state or the
// restored one.
@(test)
test_backup_and_restore_survive_crashes :: proc(t: ^testing.T) {
	cs, ok := crash_setup(t, "crash_br")
	defer crash_teardown(&cs)
	if !ok {return}
	run_dir := fmt.tprintf("%s_br", cs.run)
	defer os.remove_all(run_dir)
	clean := base.Disk{}
	// Backups: the generation-1 state, backed up with the process dying.
	counter := base.Disk_Faults{}
	cd := base.Disk {
		faults = &counter,
	}
	os.remove_all(run_dir)
	copy_tree(cs.base, run_dir)
	testing.expect_value(t, backup_make(run_dir, "g00000001-t", &cd), "")
	n, stride := fault_points(counter.ops)
	for i in 1 ..= n {
		if i % stride != 0 && i != 1 {continue}
		os.remove_all(run_dir)
		copy_tree(cs.base, run_dir)
		faults := base.Disk_Faults {
			countdown  = i,
			rng        = base.rng_make(u64(i)),
			power_loss = i % 2 == 1,
		}
		d := base.Disk {
			faults = &faults,
		}
		backup_make(run_dir, "g00000001-t", &d)
		base.disk_faults_destroy(&faults)
		store_recover(run_dir, &clean)
		testing.expectf(t, state_digest(run_dir) == cs.d1, "backup point %d changed the save", i)
		backup_rotate(run_dir, 5) // (clears what a crash left)
		testing.expectf(t, universe_check(run_dir).ok, "backup point %d: does not check", i)
	}
	// Restores: gen 1 backed up, gen 2 saved, then restore the backup.
	prepare := proc(dir: string, cs: ^Crash_Setup) {
		os.remove_all(dir)
		copy_tree(cs.base, dir)
		c := base.Disk{}
		backup_make(dir, "g00000001-t", &c)
		rb := cs.batch^
		rb.dir, rb.disk = dir, &c
		batch_run(&rb)
		delete(rb.problem, runtime.heap_allocator())
	}
	prepare(run_dir, &cs)
	old := state_digest(run_dir)
	counter = base.Disk_Faults{}
	testing.expect_value(t, universe_restore(run_dir, "latest", &cd), "")
	restored := state_digest(run_dir)
	testing.expect(t, restored != old, "the restore changed nothing")
	n, stride = fault_points(counter.ops)
	seen: [2]int
	for i := 1; i <= n; i += stride {
		prepare(run_dir, &cs)
		faults := base.Disk_Faults {
			countdown  = i,
			rng        = base.rng_make(u64(i)),
			power_loss = i % 2 == 1,
		}
		d := base.Disk {
			faults = &faults,
		}
		universe_restore(run_dir, "latest", &d)
		base.disk_faults_destroy(&faults)
		testing.expectf(
			t,
			store_recover(run_dir, &clean) == "",
			"restore point %d: recovery failed",
			i,
		)
		dig := state_digest(run_dir)
		switch dig {
		case old:
			seen[0] += 1
		case restored:
			seen[1] += 1
		case:
			testing.expectf(
				t,
				false,
				"restore point %d: neither the old state nor the restored one",
				i,
			)
		}
		testing.expectf(t, universe_check(run_dir).ok, "restore point %d: does not check", i)
	}
	testing.expectf(t, seen[0] > 0 && seen[1] > 0, "restore outcomes: %d, %d", seen[0], seen[1])
}

// What a journal appended after a save (the process died before the next one)
// leaves is cut back to the save's end when the universe opens.
@(test)
test_journal_tail_is_cut :: proc(t: ^testing.T) {
	cs, ok := crash_setup(t, "crash_tail")
	defer crash_teardown(&cs)
	if !ok {return}
	files := make([dynamic]string, context.temp_allocator)
	walk_files(cs.base, "", &files)
	os.remove_all(cs.run)
	copy_tree(cs.base, cs.run)
	for rel in files {
		if !strings.has_suffix(rel, ".vxj") {continue}
		f, _ := os.open(full_path(cs.run, rel), {.Write, .Append})
		os.write(f, transmute([]u8)string("torn tail after the save"))
		os.close(f)
	}
	testing.expect_value(t, state_digest(cs.run), cs.d1)
	testing.expect(t, universe_check(cs.run).ok, "the tail broke the check")
	g, opened := grief_open(t, cs.run)
	defer grief_close(g)
	if !opened {return}
	testing.expect(t, save(grief_srv(g)), "the save after the tail failed")
	testing.expect(t, universe_check(cs.run).ok, "the universe does not check after")
}
