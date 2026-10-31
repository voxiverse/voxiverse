package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import "common:base"
import "common:game"

// A small universe by hand: a.txt and sub/b.txt exist, d.txt is to go; the
// save changes a, creates sub/c.txt and deletes d.
tx_world :: proc(dir: string) -> ^Save_Batch {
	os.remove_all(dir)
	os.make_directory_all(fmt.tprintf("%s/sub", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", dir), transmute([]u8)string("a1"))
	_ = os.write_entire_file(fmt.tprintf("%s/sub/b.txt", dir), transmute([]u8)string("b1"))
	_ = os.write_entire_file(fmt.tprintf("%s/d.txt", dir), transmute([]u8)string("d1"))
	b := batch_make(dir, 2, 100, nil)
	batch_stage(b, "a.txt", transmute([]u8)string("a2"))
	batch_stage(b, "sub/c.txt", transmute([]u8)string("c2"))
	batch_delete(b, "d.txt")
	return b
}

// Recovery from every point of a save: the old files or the new, whole, and a
// second recovery changes nothing.
@(test)
test_recovery_finishes_or_undoes :: proc(t: ^testing.T) {
	dir := "build/test_tx_recover"
	defer os.remove_all(dir)
	probe := tx_world(dir)
	faults := base.Disk_Faults{}
	pd := base.Disk {
		faults = &faults,
	}
	probe.disk = &pd
	batch_run(probe)
	ops := faults.ops
	batch_free(probe)
	old_digest, new_digest := u64(0), state_digest(dir)
	seen: [2]int
	for countdown in 1 ..= ops {
		b := tx_world(dir)
		if old_digest == 0 {old_digest = state_digest(dir)}
		f := base.Disk_Faults {
			countdown = countdown,
			rng       = base.rng_make(u64(countdown)),
		}
		d := base.Disk {
			faults = &f,
		}
		b.disk = &d
		batch_run(b)
		batch_free(b)
		clean := base.Disk{}
		testing.expect_value(t, store_recover(dir, &clean), "")
		first := state_digest(dir)
		testing.expect_value(t, store_recover(dir, &clean), "")
		testing.expect_value(t, state_digest(dir), first)
		files := make([dynamic]string, context.temp_allocator)
		walk_files(dir, "", &files)
		for rel in files {
			testing.expectf(
				t,
				rel != TX_FILE && rel != "a.txt.new",
				"countdown %d left %s",
				countdown,
				rel,
			)
		}
		switch first {
		case old_digest:
			seen[0] += 1
		case new_digest:
			seen[1] += 1
		case:
			testing.expectf(t, false, "countdown %d: neither generation", countdown)
		}
		base.disk_faults_destroy(&f)
	}
	testing.expect(t, seen[0] > 0 && seen[1] > 0, "both outcomes should occur")
}

// A save that fails (the disk dies in the worker) writes its files again with
// the next one.
@(test)
test_failed_save_is_retried :: proc(t: ^testing.T) {
	dir := scratch_dir("tx_retry")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	s := grief_srv(g)
	pos := at(g, 5, 4, 0)
	cmd(g, "setblock %d %d %d stone", pos.x, pos.y, pos.z)
	faults := base.Disk_Faults {
		countdown = 4,
	}
	s.store.disk.faults = &faults
	{
		// (the failure is logged as an error, which the test runner counts as a failure)
		context.logger = log.create_console_logger(.Fatal)
		defer log.destroy_console_logger(context.logger)
		testing.expect(t, !save(s), "a save on a dead disk reported success")
	}
	testing.expect_value(t, s.store.generation, u64(0))
	s.store.disk.faults = nil
	// (a dead process leaves files behind: the next save replaces them)
	testing.expect(t, save(s), "the retry failed")
	testing.expect_value(t, s.store.generation, u64(1))
	rep := universe_check(dir)
	testing.expectf(t, rep.ok, "the universe does not check: %v", rep.problems[:])
	grief_close(g)
	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	testing.expect_value(t, block_at_pos(grief_world(g2), pos), game.Block.Stone)
}

@(test)
test_relative_path_follows_full_path :: proc(t: ^testing.T) {
	// Whatever separators the OS joins with, a path made by full_path comes
	// back to the name it was made from (Windows missed this once).
	for dir in ([]string{"build/test_rel", "build/test_rel/", "world"}) {
		testing.expect_value(
			t,
			relative_path(dir, full_path(dir, "regions/r.0.0.vxr")),
			"regions/r.0.0.vxr",
		)
	}
}
