package store

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:base"

// The universe of format 7 (assets/fixtures/save-v7: written by the server of that format,
// the commit before the sheep left the engine: a sandbox world with a shorn black sheep, a
// spotted one in love that came by itself, a lamb and a stack of black wool) comes to the
// current format: the base pack's sheep are the sandbox's, what the engine kept of each
// now the sandbox's record on it (a lamb's growth as the ticks before it is grown), the
// rest as it was.
@(test)
test_migrate_v7 :: proc(t: ^testing.T) {
	dir :: "build/tmp/test_migrate_v7"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_fixture("assets/fixtures/save-v7", dir)
	disk: base.Disk
	res := migrate_universe(dir, &disk, 7, 1)
	if !testing.expectf(t, res.ok, "the migration failed: %s", res.why) {return}
	world :: "worlds/09180a2606240d00-030c231f211b1a"
	entities, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s/entities.cfg", dir, world),
		context.temp_allocator,
	)
	want := []string {
		"sandbox:sheep 3.5208 1.0000 0.4792 -0.6896 4 false data.shorn=true data.genes=3",
		"sandbox:sheep -2.5208 1.0000 0.4792 -0.5745 4 true data.genes=4 data.love=298",
		"sandbox:sheep 0.5000 1.0000 3.5000 1.9156 4 false data.genes=12 data.grows=17898 data.wait=48",
		"voxiverse:item 0.5000 2.1289 -2.5000 1.3117 1 false item=voxiverse:black_wool count=3",
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
	testing.expect(
		t,
		!strings.contains(string(entities), "voxiverse:sheep"),
		"a sheep stayed the engine's",
	)
	stats, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s/stats.json", dir, world),
		context.temp_allocator,
	)
	testing.expect(
		t,
		strings.contains(string(stats), `"sheep.born": 1`),
		"the world's counters changed",
	)
}

// copy_fixture copies the directory from into to (made), files and directories.
copy_fixture :: proc(from, to: string) {
	os.make_directory_all(to)
	entries, _ := os.read_all_directory_by_path(from, context.temp_allocator)
	for e in entries {
		src, dst := fmt.tprintf("%s/%s", from, e.name), fmt.tprintf("%s/%s", to, e.name)
		if e.type == .Directory {
			copy_fixture(src, dst)
		} else if data, err := os.read_entire_file_from_path(src, context.temp_allocator);
		   err == nil {
			_ = os.write_entire_file(dst, data)
		}
	}
}
