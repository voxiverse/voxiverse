package bench

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

import "common:base"
import "common:game"
import "common:planet"
import "server:core"

// The `budgets` benchmark scenario (`build bench budgets`):
// what the server's heavy work costs, each scene of server/core/budgets.odin once a
// repetition, in CPU time of this thread: a save (what the tick pays to start
// it, its largest slice, a blocking one), the item audit, saving and loading
// many counters, the journal under a flood and blasts, 10 000 blocks of water
// flowing, building the planet's climate. No test judges any of these: the tests call the scenes for what
// they do. The budgets sit here beside the scenario, like `chunks`'s CHECK,
// and are the ones the tests held, several times a fast
// desktop's so a slow runner does not flake. The counters are a multiple of
// what building them cost in the same run, not a number of seconds (#43).

BUDGETS_VERSION :: 6

Budgets_Options :: struct {
	repetitions: int `usage:"times the whole is done (default 3, 5 with -check)"`,
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
	// Measured on CI: 0.8 % on Windows, 3.7 to 5.1 % on the macOS runner (main read
	// 4.5 % there with one repetition at 4.9 %), so a limit of 5 failed by chance.
	{.Journal_Share, 10},
	{.Journal_Tick, 500},
	{.Flood_Tick, 33_000}, // a tick
	{.Rules_Tick, 16_000}, // half the tick: the old test's 8 ms, doubled for slow runners as the flood's is
	{.Rule_Run, 3000},
	{.Rules_Compile, 50_000},
	{.Random_Ticks, 2000},
	{.Random_Rule_Run, 4000}, // (the grass rule may read light: 377 cells)
	{.Store_Op, 600},
	{.Store_Iterate, 15},
	{.Spatial_Move, 250},
	{.Spatial_Sphere, 3000},
	{.Island_Tick, 200}, // the issue's 0.2 ms a tick, 64 observers moving
	{.Collide_Move, 2000},
	{.Planet_Build, 2000}, // the issue's 2 s on a CI runner; measured at about 0.8 s
	{.Planet_Placement, 300}, // the issue's 300 ms for a world of 10 peoples
	{.Planet_History, 200}, // the issue's 200 ms for 6 000 years; measured at about 20 ms
}

budgets_main :: proc(args: []string) {
	opts: Budgets_Options
	argv := make([]string, len(args) + 1, context.temp_allocator)
	copy(argv[1:], args)
	result := base.Bench_Result {
		scenario = "budgets",
		version  = BUDGETS_VERSION,
	}
	flags.parse_or_exit(&opts, argv, .Odin)
	runs := judge_runs(opts.repetitions, opts.check)
	broken := make([dynamic]string) // (not the temp allocator: the scenes free it)
	over := make([dynamic]string)
	// (on the heap too: the scenes free the temp allocator, and a path in it is
	// garbage from the second repetition on)
	dir := filepath.join({"build", "tmp", "bench_budgets"}) or_else ""
	defer delete(dir)
	reg := game.registry_base(context.allocator)
	defer game.registry_destroy(reg)
	for _ in 0 ..< runs {
		base.metrics_start()
		budgets_run(dir, reg, &broken)
		base.bench_repetition_end(&result)
		if len(broken) > 0 {break} 	// broken at once: more runs would only repeat it
	}
	os.remove_all(dir)
	fmt.printfln("%-16s %14s %14s  %s", "scene", "median", "budget", "each run")
	for b in BUDGET_LIMITS {
		values := judge_metric_runs(&result, b.metric)
		runs_text := judge_runs_text(values[:], 2)
		median := base.median_of(values[:])
		info := base.METRIC_INFO[b.metric]
		fmt.printfln(
			"%-16s %14s %14s  %s",
			info.name,
			fmt.tprintf("%.2f %s", median, info.unit),
			fmt.tprintf("%.2f %s", b.limit, info.unit),
			runs_text,
		)
		if opts.check {
			judge_report(
				"budgets",
				budget_scene(b.metric),
				info.name,
				median,
				info.unit,
				true,
				b.limit,
				values[:],
			)
		}
		if opts.check && len(broken) == 0 && median > b.limit {
			append(
				&over,
				fmt.tprintf("%s %.2f %s, over its %.2f", info.name, median, info.unit, b.limit),
			)
		}
	}
	if path := base.bench_result_write(&result); path != "" {fmt.printfln("result %s", path)}
	base.bench_result_destroy(&result)
	judge_end(broken[:], over[:], opts.check)
}

@(private = "file")
budgets_run :: proc(dir: string, reg: ^game.Registry, broken: ^[dynamic]string) {
	os.remove_all(dir)
	fmt.printfln("scene: %s", "the save")
	save, saved := core.budget_save(dir, core.BUDGET_COMMIT_SECONDS)
	os.remove_all(dir)
	if !saved || !save.committed || !save.blocking_ok {
		append(broken, fmt.aprintf("the save: %v", save))
	}
	base.metric_add(.Save_Capture, f32(save.capture_us))
	base.metric_add(.Save_Slice, f32(save.slice_worst_us))
	base.metric_add(.Save_Blocking, f32(save.blocking_ms))

	fmt.printfln("scene: %s", "the audit")
	lines, audit_us := core.budget_audit(reg)
	if lines != 0 {append(broken, fmt.aprintf("the audit gave %d lines", lines))}
	base.metric_add(.Audit, f32(audit_us))

	fmt.printfln("scene: %s", "the counters")
	building, work, _, bad := core.budget_counters(reg)
	if bad != 0 {append(broken, fmt.aprintf("%d players did not read back", bad))}
	base.metric_add(.Counters_Ratio, f32(work) / f32(max(building, 1)))

	fmt.printfln("scene: %s", "the journal")
	journal, journaled := core.budget_journal()
	if !journaled || journal.head <= 20_000 {
		append(broken, fmt.aprintf("the journal scene changed %d blocks", journal.head))
	}
	base.metric_add(.Journal_Share, f32(journal.share * 100))
	base.metric_add(.Journal_Tick, f32(journal.per_tick_us))

	fmt.printfln("scene: %s", "the flood")
	flood, flooded := core.budget_flood()
	if !flooded || flood.most < 10_000 {
		append(broken, fmt.aprintf("only %d block updates flowing", flood.most))
	}
	base.metric_add(.Flood_Tick, f32(flood.worst_us))

	fmt.printfln("scene: %s", "the rules")
	rules, ruled := core.budget_rules()
	if !ruled || rules.most < 10_000 {
		append(broken, fmt.aprintf("only %d rule cells waiting", rules.most))
	}
	base.metric_add(.Rules_Tick, f32(rules.worst_us))
	base.metric_add(.Rule_Run, f32(rules.run_ns))
	base.metric_add(.Rules_Compile, f32(rules.compile_us))

	fmt.printfln("scene: %s", "the random ticks")
	random, randomed := core.budget_random_ticks()
	if !randomed || random.runs < 10_000 {
		append(broken, fmt.aprintf("only %d random rule runs", random.runs))
	}
	base.metric_add(.Random_Ticks, f32(random.worst_us))
	base.metric_add(.Random_Rule_Run, f32(random.run_ns))

	fmt.printfln("scene: %s", "the planet")
	build_ms, history_ms, place_ms := budget_planet(broken)
	base.metric_add(.Planet_Build, f32(build_ms))
	base.metric_add(.Planet_History, f32(history_ms))
	base.metric_add(.Planet_Placement, f32(place_ms))

	budget_entities(reg, broken)
}

// budget_planet builds the planet from the committed relief, then its peoples' 6 000
// years, and says how many ms each took.
@(private = "file")
budget_planet :: proc(broken: ^[dynamic]string) -> (build_ms, history_ms, place_ms: f64) {
	relief, ok := planet.relief_decode(#load("../../assets/planet/earth_relief.bin"))
	if !ok {
		append(broken, "the relief file does not load")
		return 0, 0, 0
	}
	defer planet.relief_destroy(&relief)
	start := time.tick_now()
	p := planet.planet_build(relief)
	build_ms = time.duration_milliseconds(time.tick_since(start))
	defer planet.planet_destroy(&p)
	free_all(context.temp_allocator)
	start = time.tick_now()
	h := planet.history(p, 7, 3, 6000 * planet.DAYS_PER_YEAR, nil)
	history_ms = time.duration_milliseconds(time.tick_since(start))
	if len(h.peoples) == 0 {append(broken, "the planet's history has no peoples")}
	// A world of 10 or more peoples (the seeds are searched; the first such one is placed).
	for seed in u64(3) ..= 40 {
		w := planet.history(p, 11, seed, 6000 * planet.DAYS_PER_YEAR, nil)
		defer planet.history_destroy(&w)
		if len(w.peoples) < 10 {continue}
		start = time.tick_now()
		pl := planet.place(p, w)
		place_ms = time.duration_milliseconds(time.tick_since(start))
		planet.placement_destroy(&pl)
		break
	}
	if place_ms == 0 {append(broken, "no world with 10 peoples to place")}
	planet.history_destroy(&h)
	free_all(context.temp_allocator)
	return
}

@(private = "file")
budget_entities :: proc(reg: ^game.Registry, broken: ^[dynamic]string) {
	check :: proc(broken: ^[dynamic]string, what: string, r: core.Budget_Scene) {
		if r.done != r.want {
			append(broken, fmt.aprintf("%s did %d of the %d asked", what, r.done, r.want))
		}
	}
	fmt.printfln("scene: %s", "the store")
	store := core.budget_store()
	// (an operation that is refused or finds nothing to do is not counted: most are applied)
	if store.done < store.want / 2 {
		append(
			broken,
			fmt.aprintf("the store applied %d of %d operations", store.done, store.want),
		)
	}
	base.metric_add(.Store_Op, f32(store.ns))
	iterate := core.budget_store_iterate()
	check(broken, "the store's query", iterate)
	base.metric_add(.Store_Iterate, f32(iterate.ns))

	fmt.printfln("scene: %s", "the spatial service")
	move := core.budget_spatial_move()
	check(broken, "the spatial moves", move)
	base.metric_add(.Spatial_Move, f32(move.ns))
	sphere := core.budget_spatial_sphere()
	check(broken, "the sphere queries", sphere)
	base.metric_add(.Spatial_Sphere, f32(sphere.ns))

	fmt.printfln("scene: %s", "the islands")
	islands := core.budget_islands()
	check(broken, "the island ticks", islands)
	base.metric_add(.Island_Tick, f32(islands.ns / 1000))

	fmt.printfln("scene: %s", "the collision")
	collide := core.budget_collide(reg)
	check(broken, "the collide moves", collide)
	base.metric_add(.Collide_Move, f32(collide.ns))
}
