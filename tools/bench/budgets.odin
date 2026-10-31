package bench

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import "common:base"
import "common:game"
import "server:."

// The `budgets` benchmark scenario (docs/plan.md, T5; `build bench budgets`):
// what the server's heavy work costs, each scene of server/budgets.odin once a
// repetition, in CPU time of this thread: a save (what the tick pays to start
// it, its largest slice, a blocking one), the item audit, saving and loading
// many counters, the journal under a flood and blasts, 10 000 blocks of water
// flowing. No test judges any of these: the tests call the scenes for what
// they do. The budgets sit here beside the scenario, like `chunks`'s CHECK,
// and are the ones the tests held (M11, M43, M45, M46b), several times a fast
// desktop's so a slow runner does not flake. The counters are a multiple of
// what building them cost in the same run, not a number of seconds (#43).

BUDGETS_VERSION :: 1

Budgets_Options :: struct {
	repetitions: int `usage:"times the whole is done (default 3)"`,
	check:       bool `usage:"fail unless every scene works and every median is within its budget (CI)"`,
}

BUDGET_LIMITS := [?]struct {
	metric: base.Metric,
	limit:  f64,
} {
	{.Save_Capture, 4000},
	{.Save_Slice, 3000},
	{.Save_Blocking, 1500},
	{.Audit, 10_000},
	{.Counters_Ratio, 6}, // measured at 2 to 3
	{.Journal_Share, 5},
	{.Journal_Tick, 500},
	{.Flood_Tick, 33_000}, // a tick
}

// The save is given this many ticks to commit before the scene gives up (the
// worker is a real thread and the stepped ticks are fast, so the ticks it
// took is no unit of time and no budget: what the save costs the tick is the
// capture and the slices).
BUDGET_COMMIT_TICKS :: 1500

budgets_main :: proc(args: []string) {
	opts := Budgets_Options {
		repetitions = 3,
	}
	argv := make([]string, len(args) + 1, context.temp_allocator)
	copy(argv[1:], args)
	flags.parse_or_exit(&opts, argv, .Odin)
	result := base.Bench_Result {
		scenario = "budgets",
		version  = BUDGETS_VERSION,
	}
	failures := make([dynamic]string) // (not the temp allocator: the scenes free it)
	// (on the heap too: the scenes free the temp allocator, and a path in it is
	// garbage from the second repetition on)
	dir := filepath.join({"build", "tmp", "bench_budgets"}) or_else ""
	defer delete(dir)
	reg := game.registry_base(context.allocator)
	defer game.registry_destroy(reg)
	for _ in 0 ..< max(opts.repetitions, 1) {
		base.metrics_start()
		budgets_run(dir, reg, &failures)
		base.bench_repetition_end(&result)
	}
	os.remove_all(dir)
	fmt.printfln("%-16s %14s %14s", "scene", "median", "budget")
	for b in BUDGET_LIMITS {
		values := make([dynamic]f64, context.temp_allocator)
		for r in result.repetitions {append(&values, r[b.metric].median)}
		median := base.median_of(values[:])
		info := base.METRIC_INFO[b.metric]
		fmt.printfln(
			"%-16s %14s %14s",
			info.name,
			fmt.tprintf("%.2f %s", median, info.unit),
			fmt.tprintf("%.2f %s", b.limit, info.unit),
		)
		if opts.check && median > b.limit {
			append(
				&failures,
				fmt.tprintf("%s %.2f %s, over its %.2f", info.name, median, info.unit, b.limit),
			)
		}
	}
	if path := base.bench_result_write(&result); path != "" {fmt.printfln("result %s", path)}
	base.bench_result_destroy(&result)
	for f in failures {fmt.eprintfln("bench failed: %s", f)}
	if len(failures) > 0 {os.exit(1)}
	if opts.check {fmt.println("bench check passed")}
}

@(private = "file")
budgets_run :: proc(dir: string, reg: ^game.Registry, failures: ^[dynamic]string) {
	os.remove_all(dir)
	save, saved := server.budget_save(dir, BUDGET_COMMIT_TICKS)
	os.remove_all(dir)
	if !saved || !save.committed || !save.blocking_ok {
		append(failures, fmt.aprintf("the save: %v", save))
	}
	base.metric_add(.Save_Capture, f32(save.capture_us))
	base.metric_add(.Save_Slice, f32(save.slice_worst_us))
	base.metric_add(.Save_Blocking, f32(save.blocking_ms))

	lines, audit_us := server.budget_audit(reg)
	if lines != 0 {append(failures, fmt.aprintf("the audit gave %d lines", lines))}
	base.metric_add(.Audit, f32(audit_us))

	building, work, _, bad := server.budget_counters(reg)
	if bad != 0 {append(failures, fmt.aprintf("%d players did not read back", bad))}
	base.metric_add(.Counters_Ratio, f32(work) / f32(max(building, 1)))

	journal, journaled := server.budget_journal()
	if !journaled || journal.head <= 20_000 {
		append(failures, fmt.aprintf("the journal scene changed %d blocks", journal.head))
	}
	base.metric_add(.Journal_Share, f32(journal.share * 100))
	base.metric_add(.Journal_Tick, f32(journal.per_tick_us))

	flood, flooded := server.budget_flood()
	if !flooded || flood.most < 10_000 {
		append(failures, fmt.aprintf("only %d block updates flowing", flood.most))
	}
	base.metric_add(.Flood_Tick, f32(flood.worst_us))
}
