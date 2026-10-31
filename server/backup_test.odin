package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "common:base"
import "common:game"

// edit_and_save: a block set at (x, 4, 0) from the player's spot, then a save.
edit_and_save :: proc(g: ^Grief, x: i32) -> game.Block_Pos {
	pos := at(g, x, 4, 0)
	cmd(g, "setblock %d %d %d stone", pos.x, pos.y, pos.z)
	run(g, 30)
	save(grief_srv(g))
	return pos
}

region_file_of :: proc(dir: string) -> string {
	files := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &files)
	for rel in files {
		if strings.has_suffix(rel, ".vxr") {return full_path(dir, rel)}
	}
	return ""
}

// Seven backups due: the newest five stay, pre-* stay, and a backup holds the
// files of its generation.
@(test)
test_backups_rotate :: proc(t: ^testing.T) {
	dir := scratch_dir("backups")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	s := grief_srv(g)
	disk := base.Disk{}
	testing.expect_value(t, backup_make(dir, "pre-migration-4", &disk), "")
	names: [dynamic]string
	defer delete(names)
	for i in 0 ..< 7 {
		edit_and_save(g, i32(i))
		backup_run(dir, s.store.generation, 5, &disk)
		all := backup_names(dir)
		newest := all[len(all) - 1]
		root := full_path(dir, fmt.tprintf("%s/%s", BACKUPS_DIR, newest))
		testing.expectf(
			t,
			state_digest(root) == state_digest(dir),
			"backup %s differs from its generation",
			newest,
		)
		append(&names, strings.clone(newest))
	}
	left := backup_names(dir)
	// (the first save made one, too: eight in all, five kept)
	testing.expect_value(t, len(left), 5)
	testing.expect_value(t, left[len(left) - 1], names[len(names) - 1])
	testing.expect(
		t,
		os.exists(full_path(dir, "backups/pre-migration-4/universe.cfg")),
		"pre-migration was removed",
	)
	for n in names {delete(n)}
	clear(&names)
}

// A restore gives the backup's files, after a backup of what it replaced.
@(test)
test_restore :: proc(t: ^testing.T) {
	dir := scratch_dir("restore")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	s := grief_srv(g)
	first := edit_and_save(g, 1) // (the first save of a run makes a backup)
	second := edit_and_save(g, 3)
	testing.expect_value(t, s.store.generation, u64(2))
	grief_close(g) // (saves once more)
	testing.expect_value(t, len(backup_names(dir)), 1)
	before := read_generation(dir)

	disk := base.Disk{}
	testing.expect_value(t, universe_restore(dir, "latest", &disk), "")
	testing.expect(
		t,
		os.exists(full_path(dir, fmt.tprintf("backups/pre-restore-g%d/universe.cfg", before))),
		"no pre-restore backup",
	)
	rep := universe_check(dir)
	testing.expectf(t, rep.ok, "the restored universe does not check: %v", rep.problems[:])
	testing.expect_value(t, rep.generation, before + 1)
	testing.expect(t, universe_restore(dir, "nope", &disk) != "", "a missing backup restored")

	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	testing.expect_value(t, block_at_pos(grief_world(g2), first), game.Block.Stone)
	testing.expect(
		t,
		block_at_pos(grief_world(g2), second) != game.Block.Stone,
		"the later edit survived the restore",
	)
}

// A region whose header is damaged loads from the newest backup.
@(test)
test_damaged_region_loads_from_backup :: proc(t: ^testing.T) {
	dir := scratch_dir("backup_region")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	pos := edit_and_save(g, 2)
	edit_and_save(g, 3) // (the region is written again: the backup has the first)
	grief_close(g)
	path := region_file_of(dir)
	testing.expect(t, path != "", "no region was saved")
	data, _ := os.read_entire_file_from_path(path, context.allocator)
	defer delete(data)
	data[24] ~= 0xff // (in the header)
	_ = os.write_entire_file(path, data)
	// (the damage is logged as an error, which the test runner counts as a failure)
	context.logger = log.create_console_logger(.Fatal)
	defer log.destroy_console_logger(context.logger)
	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	testing.expect_value(t, block_at_pos(grief_world(g2), pos), game.Block.Stone)
}

read_generation :: proc(dir: string) -> u64 {
	return universe_check(dir).generation
}
