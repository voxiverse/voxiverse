package telemetry

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
read_dir :: proc(dir: string) -> (names: []string, contents: []string) {
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	n := make([dynamic]string, context.temp_allocator)
	c := make([dynamic]string, context.temp_allocator)
	for info in infos {
		data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		append(&n, info.name)
		append(&c, string(data))
	}
	return n[:], c[:]
}

// Events are JSON lines in the day's file by the UTC date of their time, in
// the order emitted, each kind with its own field names.
@(test)
test_events_become_json_lines :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "telemetry_lines"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	s: Sink
	sink_start(&s, dir, 7)
	day1 := i64(1_700_000_000_000) // 2023-11-14
	day2 := day1 + 86_400_000
	emit(
		&s,
		{
			time_ms = day1,
			tick = 5,
			actor = 3,
			kind = .Block_Mined,
			text = short("stone"),
			has_pos = true,
			pos = {1, -2, 3},
			world = short("abc"),
		},
	)
	emit(
		&s,
		{time_ms = day1 + 1, kind = .Item_Picked, actor = 3, text = short("dirt"), n = {4, 0, 0}},
	)
	emit(&s, {time_ms = day2, kind = .Tick_Summary, actor = NO_ACTOR, n = {2, 1500, 9000}})
	emit(&s, {time_ms = day2 + 1, kind = .Command, actor = 1, text = short(`say "hi"\`)})
	sink_flush(&s)
	sink_stop(&s)
	names, contents := read_dir(dir)
	testing.expect_value(t, len(names), 2)
	for name, i in names {
		switch name {
		case "2023-11-14.jsonl":
			lines := strings.split_lines(strings.trim_space(contents[i]), context.temp_allocator)
			testing.expect_value(t, len(lines), 2)
			testing.expect_value(
				t,
				lines[0],
				`{"t":1700000000000,"tick":5,"sid":7,"actor":3,"k":"block_mined","world":"abc","pos":[1,-2,3],"block":"stone"}`,
			)
			testing.expect_value(
				t,
				lines[1],
				`{"t":1700000000001,"tick":0,"sid":7,"actor":3,"k":"item_picked","item":"dirt","count":4}`,
			)
		case "2023-11-15.jsonl":
			lines := strings.split_lines(strings.trim_space(contents[i]), context.temp_allocator)
			testing.expect_value(t, len(lines), 2)
			testing.expect_value(
				t,
				lines[0],
				`{"t":1700086400000,"tick":0,"sid":7,"actor":null,"k":"tick_summary","online":2,"p50_us":1500,"worst_us":9000}`,
			)
			testing.expect_value(
				t,
				lines[1],
				`{"t":1700086400001,"tick":0,"sid":7,"actor":1,"k":"command","name":"say \"hi\"\\"}`,
			)
		case:
			testing.expectf(t, false, "unexpected file %s", name)
		}
	}
	free_all(context.temp_allocator)
}

// A burst never blocks the emitter: with the writer held up, the ring fills,
// later events are dropped and counted, and the count is itself written.
@(test)
test_a_burst_never_blocks_and_counts_its_losses :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "telemetry_burst"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	s: Sink
	sink_start(&s, dir, 1)
	N :: 200_000
	start := time.tick_now()
	for i in 0 ..< N {emit(&s, {kind = .Block_Placed, actor = 1, text = short("stone"), n = {i64(i), 0, 0}})}
	elapsed := time.duration_seconds(time.tick_since(start))
	testing.expectf(t, elapsed / N < 20e-6, "an emit took %.1f us on average", elapsed / N * 1e6)
	sink_flush(&s)
	stats := sink_stats(&s)
	testing.expect_value(t, stats.written + stats.dropped, N + (1 if stats.dropped > 0 else 0))
	sink_stop(&s)
	_, contents := read_dir(dir)
	text := strings.concatenate(contents, context.temp_allocator)
	lines := strings.count(text, "\n")
	if stats.dropped > 0 {
		testing.expect(
			t,
			strings.contains(text, `"k":"events_dropped"`),
			"the loss was not written",
		)
	}
	testing.expectf(t, u64(lines) == stats.written, "%d lines, %d written", lines, stats.written)
	free_all(context.temp_allocator)
}

// The day cap holds: past it, events are counted as capped, not written.
@(test)
test_the_day_cap_holds :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "telemetry_cap"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	s: Sink
	sink_start(&s, dir, 1, day_cap = 2000)
	for i in 0 ..< 100 {emit(&s, {time_ms = 1_700_000_000_000 + i64(i), kind = .Block_Mined, text = short("stone")})}
	sink_flush(&s)
	stats := sink_stats(&s)
	sink_stop(&s)
	names, contents := read_dir(dir)
	testing.expect_value(t, len(names), 1)
	testing.expect(t, len(contents[0]) <= 2000, "the file passed the cap")
	testing.expect(
		t,
		stats.capped > 0 && stats.written + stats.capped == 100,
		"the cap's refusals were not counted",
	)
	free_all(context.temp_allocator)
}

@(test)
test_day_names :: proc(t: ^testing.T) {
	testing.expect_value(t, day_name(0), "1970-01-01")
	testing.expect_value(t, day_name(19_675), "2023-11-14")
	testing.expect_value(t, day_name(11_016), "2000-02-29")
	for info, k in KIND_INFO {testing.expectf(t, info.name != "", "kind %v has no name", k)}
	free_all(context.temp_allocator)
}
