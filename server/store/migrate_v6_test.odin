package store

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:base"

// copy_dir copies the directory from into to (made), files and directories.
@(private = "file")
copy_dir :: proc(from, to: string) {
	os.make_directory_all(to)
	entries, _ := os.read_all_directory_by_path(from, context.temp_allocator)
	for e in entries {
		src, dst := fmt.tprintf("%s/%s", from, e.name), fmt.tprintf("%s/%s", to, e.name)
		if e.type == .Directory {
			copy_dir(src, dst)
		} else if data, err := os.read_entire_file_from_path(src, context.temp_allocator);
		   err == nil {
			_ = os.write_entire_file(dst, data)
		}
	}
}

// The universe of format 6 (assets/fixtures/save-v6: written by the server of that format,
// a sandbox world with a shorn black sheep, a spotted one in love, a lamb and a dropped
// stack of wool) comes to the current format: its entities' fields by name, the rest as it
// was, in one transaction after a backup.
@(test)
test_migrate_v6 :: proc(t: ^testing.T) {
	dir :: "build/tmp/test_migrate_v6"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_dir("assets/fixtures/save-v6", dir)
	disk: base.Disk
	res := migrate_universe(dir, &disk, 6, 1)
	if !testing.expectf(t, res.ok, "the migration failed: %s", res.why) {return}
	testing.expect(t, migrations_reach(6))
	testing.expect(t, !migrations_reach(5), "a format before the chain is reached")
	world :: "worlds/011f27002221130f-0f18141d071e19"
	entities, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s/entities.cfg", dir, world),
		context.temp_allocator,
	)
	want := []string {
		"voxiverse:sheep 3.5000 1.2743 0.4706 1.5072 4 false shorn=true genes=3 growth=18000 love=0 wait=0",
		"voxiverse:sheep -2.5000 1.0000 0.5000 -2.5633 4 true shorn=false genes=4 growth=18000 love=298 wait=0",
		"voxiverse:sheep 0.5000 1.0000 3.5000 0.9994 4 false shorn=false genes=12 growth=102 love=0 wait=48",
		"voxiverse:item 0.5000 2.1289 -2.5000 1.3438 1 false item=voxiverse:wool count=2 stack_data=7",
	}
	for line in want {
		testing.expectf(
			t,
			strings.contains(string(entities), line),
			"no line %q in\n%s",
			line,
			entities,
		)
	}
	universe, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/universe.cfg", dir),
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(string(universe), fmt.tprintf("format = %d", SAVE_FORMAT)))
	testing.expect(t, strings.contains(string(universe), "generation = 2"))
	testing.expect(t, os.exists(fmt.tprintf("%s/backups/pre-migration-6/universe.cfg", dir)))
}
