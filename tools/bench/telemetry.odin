package bench

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

import "common:base"
import "common:telemetry"

// The `telemetry` benchmark scenario (`build bench telemetry`):
// what an event costs the server on its tick. Emitting is a lock and a copy;
// the writer, drained as the ring half fills (a server's writer drains as it
// goes), formats and writes every event and loses none. Each is a metric (µs
// an event), the whole done -repetitions times. The budgets are generous
// (several times a fast desktop's), to catch a regression to a syscall or an
// allocation per event on a slow CI runner without flaking.

TELEMETRY_VERSION :: 1
TELEMETRY_EVENTS :: 50_000

Telemetry_Options :: struct {
	repetitions: int `usage:"times the whole is done (default 3, 5 with -check)"`,
	check:       bool `usage:"fail unless nothing is dropped and the means are within budget (CI)"`,
}

TELEMETRY_BUDGET_US := [2]struct {
	metric: base.Metric,
	us:     f64,
}{{.Telemetry_Emit, 5}, {.Telemetry_Write, 50}}

telemetry_main :: proc(args: []string) {
	opts: Telemetry_Options
	argv := make([]string, len(args) + 1, context.temp_allocator)
	copy(argv[1:], args)
	flags.parse_or_exit(&opts, argv, .Odin)
	runs := judge_runs(opts.repetitions, opts.check)
	result := base.Bench_Result {
		scenario = "telemetry",
		version  = TELEMETRY_VERSION,
	}
	broken := make([dynamic]string, context.temp_allocator)
	over := make([dynamic]string, context.temp_allocator)
	dir := filepath.join({"build", "tmp", "bench_telemetry"}, context.temp_allocator) or_else ""
	for _ in 0 ..< runs {
		written, dropped := telemetry_run(dir)
		if dropped != 0 || written != TELEMETRY_EVENTS {
			append(
				&broken,
				fmt.tprintf(
					"%d events written, %d dropped, of %d",
					written,
					dropped,
					TELEMETRY_EVENTS,
				),
			)
		}
		base.bench_repetition_end(&result)
		if len(broken) > 0 {break}
	}
	os.remove_all(dir)
	append(&result.counts, base.Bench_Count{"events", TELEMETRY_EVENTS})
	fmt.printfln(
		"%-16s %8s %8s %8s %8s  %s",
		"per event (us)",
		"calls",
		"mean",
		"median",
		"p99",
		"each run's mean",
	)
	for b in TELEMETRY_BUDGET_US {
		means, medians, p99s := make([dynamic]f64), make([dynamic]f64), make([dynamic]f64)
		defer delete(means)
		defer delete(medians)
		defer delete(p99s)
		calls := 0
		for r in result.repetitions {
			append(&means, r[b.metric].mean)
			append(&medians, r[b.metric].median)
			append(&p99s, r[b.metric].p99)
			calls = r[b.metric].count
		}
		runs_means := make([dynamic]f64, context.temp_allocator)
		append(&runs_means, ..means[:])
		mean := base.median_of(means[:])
		fmt.printfln(
			"%-16s %8s %8s %8s %8s  %s",
			base.METRIC_INFO[b.metric].name,
			fmt.tprint(calls),
			fmt.tprintf("%.3f", mean),
			fmt.tprintf("%.3f", base.median_of(medians[:])),
			fmt.tprintf("%.3f", base.median_of(p99s[:])),
			judge_runs_text(runs_means[:], 3),
		)
		if opts.check && len(broken) == 0 && mean > b.us {
			append(
				&over,
				fmt.tprintf(
					"%s %.3f us an event, over its %.3f",
					base.METRIC_INFO[b.metric].name,
					mean,
					b.us,
				),
			)
		}
	}
	if path := base.bench_result_write(&result); path != "" {fmt.printfln("result %s", path)}
	base.bench_result_destroy(&result)
	judge_end(broken[:], over[:], opts.check)
}

// telemetry_run emits TELEMETRY_EVENTS into a stepped sink writing to dir,
// draining as the ring half fills; what was written and dropped.
telemetry_run :: proc(dir: string) -> (written, dropped: u64) {
	os.remove_all(dir)
	s: telemetry.Sink
	telemetry.sink_start(&s, dir, 9, stepped = true)
	e := telemetry.Event {
		time_ms = 1_700_000_000_000,
		kind    = .Block_Placed,
		actor   = 3,
		text    = telemetry.short("stone"),
		n       = {1, 2, 3},
	}
	base.metrics_start()
	for _ in 0 ..< TELEMETRY_EVENTS {
		if s.head - s.tail > telemetry.RING_SIZE / 2 {
			queued := s.head - s.tail
			t0 := time.tick_now()
			telemetry.sink_drain(&s)
			us := time.duration_microseconds(time.tick_since(t0))
			base.metric_add(.Telemetry_Write, f32(us / f64(queued)))
		}
		t0 := time.tick_now()
		telemetry.emit(&s, e)
		base.metric_add(.Telemetry_Emit, f32(time.duration_microseconds(time.tick_since(t0))))
	}
	queued := s.head - s.tail
	t0 := time.tick_now()
	telemetry.sink_drain(&s)
	if queued > 0 {
		us := time.duration_microseconds(time.tick_since(t0))
		base.metric_add(.Telemetry_Write, f32(us / f64(queued)))
	}
	stats := telemetry.sink_stats(&s)
	telemetry.sink_stop(&s)
	return stats.written, stats.dropped
}
