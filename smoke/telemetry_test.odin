package smoke

import "core:os"
import "core:strings"
import "core:testing"

import "../common/telemetry"

// The sink's writer thread drains the ring to the day's file (sink_flush
// waits for it); the lines and the counts are tested on a stepped sink in
// common/telemetry.
@(test)
test_the_writer_thread_drains_the_ring :: proc(t: ^testing.T) {
	dir := "build/tmp/smoke_telemetry"
	os.remove_all(dir)
	defer os.remove_all(dir)
	s: telemetry.Sink
	telemetry.sink_start(&s, dir, 7)
	N :: 1000
	for i in 0 ..< N {
		telemetry.emit(
			&s,
			{
				time_ms = 1_700_000_000_000 + i64(i),
				kind = .Block_Mined,
				actor = 1,
				text = telemetry.short("stone"),
			},
		)
	}
	telemetry.sink_flush(&s)
	stats := telemetry.sink_stats(&s)
	telemetry.sink_stop(&s)
	testing.expect_value(t, stats.written, N)
	testing.expect_value(t, stats.dropped, 0)
	data, err := os.read_entire_file_from_path(
		"build/tmp/smoke_telemetry/2023-11-14.jsonl",
		context.temp_allocator,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, strings.count(string(data), "\n"), N)
	free_all(context.temp_allocator)
}
