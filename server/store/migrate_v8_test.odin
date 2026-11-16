package store

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:base"

// The universe of format 8 (assets/fixtures/save-v8: written by the server of that format,
// the commit before the markets left the engine: a planet world with its economy file and
// two interventions, and a trader who bought grain and saw a town's prices) comes to the
// current format: the world's files are the sandbox's, their bytes as they were, and the
// trader is the sandbox's record on the character.
@(test)
test_migrate_v8 :: proc(t: ^testing.T) {
	dir :: "build/tmp/test_migrate_v8"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_fixture("assets/fixtures/save-v8", dir)
	world :: "worlds/111a140f0413180e-14040022162710"
	before := [2][]u8{}
	for name, i in ([]string{"economy.vxe", "interventions.vxi"}) {
		before[i], _ = os.read_entire_file_from_path(
			fmt.tprintf("%s/%s/%s", dir, world, name),
			context.temp_allocator,
		)
	}
	disk: base.Disk
	res := migrate_universe(dir, &disk, 8, 1)
	if !testing.expectf(t, res.ok, "the migration failed: %s", res.why) {return}
	for name, i in ([]string{"economy.vxe", "interventions.vxi"}) {
		testing.expectf(
			t,
			!os.exists(fmt.tprintf("%s/%s/%s", dir, world, name)),
			"%s stayed",
			name,
		)
		after, _ := os.read_entire_file_from_path(
			fmt.tprintf("%s/%s/sandbox.%s", dir, world, name),
			context.temp_allocator,
		)
		testing.expectf(
			t,
			len(before[i]) > 0 && string(after) == string(before[i]),
			"%s moved changed",
			name,
		)
	}
	character :: "characters/01ff5021b7bbecff5ed759200066950cd0ffd9cf7734206027c3588a8d6f6d0a/trader.json"
	data, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s", dir, character),
		context.temp_allocator,
	)
	value, err := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if !testing.expect_value(t, err, json.Error.None) {return}
	file := value.(json.Object)
	_, has_trader := file["trader"]
	testing.expect(t, !has_trader, "the trader stayed the engine's")
	testing.expect_value(t, file["format"].(json.Integer), 5)
	record := file["game"].(json.Object)
	testing.expect_value(t, record["cash"].(json.Float), 9897.249825109646)
	testing.expect_value(t, record["cargo.0"].(json.Float), 217.4607)
	testing.expect_value(t, record["count"].(json.Integer), 8)
	testing.expect_value(t, record["seen.0.cell"].(json.Integer), 82623)
	testing.expect_value(t, record["seen.0.price"].(json.Float), 0.45)
	testing.expect_value(t, record["seen.3.good"].(json.String), "Salt")
	testing.expect_value(t, record["given"].(json.Boolean), true)
	stats, has_stats := file["stats"].(json.Object)
	testing.expect(
		t,
		has_stats && stats["sessions"].(json.Integer) == 1,
		"the character's counters were lost",
	)
	testing.expect(
		t,
		strings.has_suffix(strings.trim_space(string(data)), "}\n}"),
		"the counters are not last",
	)
	cfg, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/universe.cfg", dir),
		context.temp_allocator,
	)
	value_text, _ := text_value(string(cfg), "format")
	testing.expect_value(t, value_text, "9")
}
