package store

import "core:fmt"
import "core:os"
import "core:testing"

import "common:base"

// The universe of format 9 (assets/fixtures/save-v9: written by the dedicated server of
// that format, a new sandbox universe saved as it stopped) comes to the current format
// with its files as they were.
@(test)
test_migrate_v9 :: proc(t: ^testing.T) {
	dir :: "build/tmp/test_migrate_v9"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_fixture("assets/fixtures/save-v9", dir)
	world :: "worlds/2202051d0f201024-021a220c110a0e"
	before, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s/entities.cfg", dir, world),
		context.temp_allocator,
	)
	disk: base.Disk
	res := migrate_universe(dir, &disk, 9, 1)
	if !testing.expectf(t, res.ok, "the migration failed: %s", res.why) {return}
	after, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s/entities.cfg", dir, world),
		context.temp_allocator,
	)
	testing.expect(t, len(before) > 0 && string(after) == string(before), "a file changed")
	cfg, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/universe.cfg", dir),
		context.temp_allocator,
	)
	format, _ := text_value(string(cfg), "format")
	testing.expect_value(t, format, fmt.tprint(SAVE_FORMAT))
}
