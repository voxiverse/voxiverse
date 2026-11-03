package bench

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "common:base"
import "common:script"

// The `script` benchmark scenario (`build bench script`, also
// `build script bench`): the programs of common/script/testdata/bench, each run
// -repetitions times in our VM (CPU time of this thread) and, with --lua <exe>, under
// that interpreter (the child's user time); each side's time is its least. Each program's time is a metric and the
// instruction units it used a count: exact on every OS, so `-check` holds them to the
// budgets in budgets.txt beside the programs everywhere, and, with --lua, holds the
// ratios to ours over Lua's to at most SCRIPT_MAX_RATIO each and SCRIPT_MAX_GEOMEAN in
// geometric mean (both on the same machine, so its speed cancels). With --lua the
// conformance files marked `--! lua` are also run under both and must print the same
// (`build script conform --lua <exe>` runs only that part: -conform).

SCRIPT_VERSION :: 1
SCRIPT_MAX_RATIO :: 4.0
SCRIPT_MAX_GEOMEAN :: 2.5
SCRIPT_BENCH_DIR :: "common/script/testdata/bench"
SCRIPT_CONFORMANCE_DIR :: "common/script/testdata/conformance"
SCRIPT_BUDGETS :: "common/script/testdata/bench/budgets.txt"
// SCRIPT_SNAPSHOT_MAX_MS: -check fails a snapshot or a restore (with its validation) of a
// VM with a full 16 MiB heap over this, CPU time of the thread.
SCRIPT_SNAPSHOT_MAX_MS :: 100.0

SCRIPT_PROGRAMS := [?]struct {
	name:   string,
	metric: base.Metric,
} {
	{"array", .Script_Array},
	{"closure", .Script_Closure},
	{"fib", .Script_Fib},
	{"float", .Script_Float},
	{"hash", .Script_Hash},
	{"loop", .Script_Loop},
	{"method", .Script_Method},
	{"string", .Script_String},
}

@(private = "file")
Script_Options :: struct {
	repetitions: int,
	check:       bool,
	conform:     bool, // the conformance comparison only
	lua:         string,
}

@(private = "file")
script_usage :: proc() -> ! {
	fmt.eprintln(
		"usage: bench script [-check] [--smoke] [-repetitions N] [--lua <exe>]\n       bench script -conform --lua <exe>",
	)
	os.exit(2)
}

script_main :: proc(args: []string) {
	opts: Script_Options
	for i := 0; i < len(args); i += 1 {
		a := strings.trim_left(args[i], "-")
		switch a {
		case "check":
			opts.check = true
		case "smoke":
			opts.repetitions = 1
		case "conform":
			opts.conform = true
		case "lua", "repetitions":
			if i + 1 >= len(args) {script_usage()}
			i += 1
			if a == "lua" {
				opts.lua = args[i]
			} else {
				n, ok := strconv.parse_int(args[i])
				if !ok || n < 1 {script_usage()}
				opts.repetitions = n
			}
		case:
			script_usage()
		}
	}
	opts.repetitions = judge_runs(opts.repetitions, opts.check)
	broken, over := make([dynamic]string), make([dynamic]string)
	if opts.conform {
		if opts.lua == "" {script_usage()}
		script_conform(opts.lua, &broken)
	} else {
		script_bench(opts, &broken, &over)
		if opts.lua != "" {script_conform(opts.lua, &broken)}
	}
	judge_end(broken[:], over[:], opts.check)
}

@(private = "file")
script_bench :: proc(opts: Script_Options, broken, over: ^[dynamic]string) {
	budgets := script_read_budgets()
	result := base.Bench_Result {
		scenario = "script",
		version  = SCRIPT_VERSION,
	}
	N :: len(SCRIPT_PROGRAMS)
	ours, luas: [N][dynamic]f64
	counts: [N]u64
	outputs: [N]string
	snaps, restores: [dynamic]f64
	for rep in 0 ..< opts.repetitions {
		base.metrics_start()
		for p, i in SCRIPT_PROGRAMS {
			path :=
				filepath.join({SCRIPT_BENCH_DIR, strings.concatenate({p.name, ".vxs"})}) or_else ""
			out, failure, units, ms, ok := script_run_ours(path)
			if !ok {
				append(broken, fmt.aprintf("%s: %s", p.name, failure))
				continue
			}
			base.metric_add(p.metric, f32(ms))
			append(&ours[i], ms)
			if rep == 0 {
				counts[i] = units
				outputs[i] = out
			} else if units != counts[i] || out != outputs[i] {
				append(broken, fmt.aprintf("%s: a repetition gave other output or units", p.name))
			}
			if opts.lua != "" {
				lua_out, lua_err, lua_ms, lua_ok := script_run_lua(opts.lua, path)
				if !lua_ok {
					append(
						broken,
						fmt.aprintf("%s: %s failed: %s", p.name, opts.lua, script_clip(lua_err)),
					)
				} else if lua_out != out {
					append(
						broken,
						fmt.aprintf("%s: %s", p.name, script_first_difference(out, lua_out)),
					)
				}
				append(&luas[i], lua_ms)
			}
		}
		snap, rest, sok := script_snapshot_times(broken)
		if sok {
			base.metric_add(.Script_Snapshot, f32(snap))
			base.metric_add(.Script_Restore, f32(rest))
			append(&snaps, snap)
			append(&restores, rest)
		}
		base.bench_repetition_end(&result)
		free_all(context.temp_allocator)
		if len(broken) > 0 {break} 	// broken at once: more runs would only repeat it
	}
	for p, i in SCRIPT_PROGRAMS {append(&result.counts, base.Bench_Count{p.name, int(counts[i])})}

	fmt.printfln(
		"%-10s %14s %14s %10s %10s %8s  %s",
		"program",
		"units",
		"budget",
		"ours ms",
		"lua ms",
		"ratio",
		"each run: ours ms (ratio)",
	)
	log_sum := 0.0
	for p, i in SCRIPT_PROGRAMS {
		// The median of the runs, for each side and for the ratio, which is
		// taken within a run (both sides measured together, so the machine's speed
		// at that moment cancels).
		runs := slice.clone(ours[i][:], context.temp_allocator)
		ms := base.median_of(runs) if len(runs) > 0 else 0
		budget, has_budget := budgets[p.name]
		lua_ms, ratio, each := "", "", judge_runs_text(ours[i][:], 1)
		if opts.lua != "" && len(luas[i]) > 0 {
			ratios := make([dynamic]f64, context.temp_allocator)
			for o, k in ours[i] {
				if k < len(luas[i]) {append(&ratios, o / max(luas[i][k], 0.001))}
			}
			each = fmt.tprintf("%s (%s)", each, judge_runs_text(ratios[:], 2))
			l := base.median_of(slice.clone(luas[i][:], context.temp_allocator))
			r := base.median_of(ratios[:])
			log_sum += math.ln(r)
			lua_ms, ratio = fmt.tprintf("%.1f", l), fmt.tprintf("%.2f", r)
			if opts.check {
				judge_report(
					"script",
					p.name,
					"lua_ratio",
					r,
					"x",
					true,
					SCRIPT_MAX_RATIO,
					ratios[:],
				)
			}
			if opts.check && len(broken) == 0 && r > SCRIPT_MAX_RATIO {
				append(
					over,
					fmt.aprintf("%s %.2fx Lua's time, over %.1fx", p.name, r, SCRIPT_MAX_RATIO),
				)
			}
		}
		fmt.printfln(
			"%-10s %14s %14s %10s %10s %8s  %s",
			p.name,
			fmt.tprint(counts[i]),
			fmt.tprint(budget) if has_budget else "-",
			fmt.tprintf("%.1f", ms),
			lua_ms,
			ratio,
			each,
		)
		if opts.check {
			if has_budget {
				judge_report(
					"script",
					p.name,
					"units",
					f64(counts[i]),
					"units",
					true,
					f64(budget),
					{f64(counts[i])},
				)
			}
			if !has_budget {
				append(broken, fmt.aprintf("%s has no budget in %s", p.name, SCRIPT_BUDGETS))
			} else if counts[i] > budget {
				append(
					over,
					fmt.aprintf(
						"%s used %d instruction units, over its budget of %d (%s)",
						p.name,
						counts[i],
						budget,
						SCRIPT_BUDGETS,
					),
				)
			} else if counts[i] < budget {
				fmt.printfln(
					"  %s now uses fewer units than its budget: lower it in %s",
					p.name,
					SCRIPT_BUDGETS,
				)
			}
		}
	}
	if opts.lua != "" {
		g := math.exp(log_sum / f64(N))
		fmt.printfln("geometric mean of the ratios: %.2f", g)
		if opts.check {
			judge_report(
				"script",
				"all programs",
				"lua_geomean",
				g,
				"x",
				true,
				SCRIPT_MAX_GEOMEAN,
				{g},
			)
		}
		if opts.check && len(broken) == 0 && g > SCRIPT_MAX_GEOMEAN {
			append(
				over,
				fmt.aprintf("geometric mean %.2fx Lua's time, over %.1fx", g, SCRIPT_MAX_GEOMEAN),
			)
		}
	}
	if len(snaps) > 0 {
		snap_runs, restore_runs := judge_runs_text(snaps[:], 1), judge_runs_text(restores[:], 1)
		sm, rm := base.median_of(snaps[:]), base.median_of(restores[:])
		fmt.printfln(
			"snapshot of a full 16 MiB heap: %.1f ms, restore with validation: %.1f ms (the median of %d; runs: %s | %s)",
			sm,
			rm,
			len(snaps),
			snap_runs,
			restore_runs,
		)
		if opts.check {
			judge_report(
				"script",
				"snapshot",
				"snapshot",
				sm,
				"ms",
				true,
				SCRIPT_SNAPSHOT_MAX_MS,
				snaps[:],
			)
			judge_report(
				"script",
				"snapshot",
				"restore",
				rm,
				"ms",
				true,
				SCRIPT_SNAPSHOT_MAX_MS,
				restores[:],
			)
		}
		if opts.check &&
		   len(broken) == 0 &&
		   (sm > SCRIPT_SNAPSHOT_MAX_MS || rm > SCRIPT_SNAPSHOT_MAX_MS) {
			append(
				over,
				fmt.aprintf(
					"snapshot %.1f ms, restore %.1f ms: over %.0f ms",
					sm,
					rm,
					SCRIPT_SNAPSHOT_MAX_MS,
				),
			)
		}
	}
	if path := base.bench_result_write(&result); path != "" {fmt.printfln("result %s", path)}
	base.bench_result_destroy(&result)
}

// script_snapshot_times: a VM's 16 MiB heap filled with live strings, snapshotted and
// restored (validation included); CPU time of this thread, ms.
@(private = "file")
script_snapshot_times :: proc(broken: ^[dynamic]string) -> (snap, rest: f64, ok: bool) {
	vm, e := script.vm_create(script.default_config())
	if e.kind != .None {
		append(broken, fmt.aprintf("snapshot: vm_create: %s", e.message))
		return
	}
	defer script.vm_destroy(vm)
	fn, ce := script.compile(vm, script.SNAPSHOT_FILL, "fill", allocator = context.temp_allocator)
	if ce.kind != .None {
		append(broken, fmt.aprintf("snapshot: compile: %s", ce.message))
		return
	}
	r := script.call(vm, fn, nil, max(i64), context.temp_allocator)
	if r.status != .Done {
		append(broken, fmt.aprintf("snapshot: the fill ended %v", r.status))
		return
	}
	script.collect(vm)
	t0 := base.thread_cpu_us()
	bytes := script.snapshot(vm)
	t1 := base.thread_cpu_us()
	defer delete(bytes)
	vm2, re := script.restore(bytes, script.default_config())
	t2 := base.thread_cpu_us()
	if re.kind != .None {
		append(broken, fmt.aprintf("snapshot: restore: %s", re.message))
		return
	}
	script.vm_destroy(vm2)
	return f64(t1 - t0) / 1000, f64(t2 - t1) / 1000, true
}

// script_read_budgets: lines "<program> <units>"; '#' starts a comment.
@(private = "file")
script_read_budgets :: proc() -> map[string]u64 {
	budgets := make(map[string]u64)
	data, err := os.read_entire_file_from_path(SCRIPT_BUDGETS, context.allocator)
	if err != nil {return budgets}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		fields := strings.fields(l, context.temp_allocator)
		if len(fields) != 2 {continue}
		if n, ok := strconv.parse_u64(fields[1]); ok {budgets[fields[0]] = n}
	}
	return budgets
}

// script_run_ours runs a file to its end in a fresh VM: what it printed (or the error),
// the instruction units it used and the CPU time of the run.
// (failure: the error, when it did not end well)
@(private = "file")
script_run_ours :: proc(path: string) -> (out, failure: string, units: u64, ms: f64, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return "", fmt.aprintf("cannot read %s: %v", path, err), 0, 0, false}
	defer delete(data)
	config := script.default_config()
	config.limits.memory = 1 << 30
	config.limits.run_instructions = 0
	vm, verr := script.vm_create(config)
	if verr.kind != .None {return "", script.error_string(verr), 0, 0, false}
	defer script.vm_destroy(vm)
	fn, cerr := script.compile(vm, string(data), path, allocator = context.temp_allocator)
	if cerr.kind != .None {return "", script.error_string(cerr), 0, 0, false}
	start := base.thread_cpu_us()
	r := script.call(vm, fn, nil, max(i64), context.temp_allocator)
	ms = f64(base.thread_cpu_us() - start) / 1000
	out = script.output_take(vm)
	if r.status != .Done {return out, script.error_string(r.error), 0, ms, false}
	return out, "", script.vm_stats(vm).run_units, ms, true
}

// script_run_lua runs a file under the reference interpreter: what it printed, what
// it said on stderr, its user time, and whether it ended well.
@(private = "file")
script_run_lua :: proc(lua, path: string) -> (out, errors: string, ms: f64, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = {lua, path}}, context.allocator)
	if err != nil {return "", fmt.aprintf("cannot start %s: %v", lua, err), 0, false}
	ms = f64(state.user_time) / f64(time.Millisecond)
	return string(stdout), string(stderr), ms, state.exited && state.exit_code == 0
}

// script_first_difference: the first line where two outputs differ, each clipped.
@(private = "file")
script_first_difference :: proc(a, b: string) -> string {
	x, y := a, b
	line := 1
	for {
		la, oka := strings.split_lines_iterator(&x)
		lb, okb := strings.split_lines_iterator(&y)
		if !oka && !okb {return "the same output"}
		if la != lb || oka != okb {
			return fmt.tprintf(
				"line %d: ours %s, theirs %s",
				line,
				script_clip(la) if oka else "(none)",
				script_clip(lb) if okb else "(none)",
			)
		}
		line += 1
	}
}

@(private = "file")
script_clip :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if len(t) > 200 {return fmt.tprintf("%q...", t[:200])}
	return fmt.tprintf("%q", t)
}

// script_conform: every conformance file marked `--! lua` prints the same in ours and
// under the reference interpreter.
@(private = "file")
script_conform :: proc(lua: string, broken: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(SCRIPT_CONFORMANCE_DIR, context.allocator)
	if err != nil {
		append(broken, fmt.aprintf("cannot read %s: %v", SCRIPT_CONFORMANCE_DIR, err))
		return
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	compared := 0
	for e in entries {
		if !strings.has_suffix(e.name, ".vxs") {continue}
		data, rerr := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
		if rerr != nil {continue}
		marked := false
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.trim_space(line) == "--! lua" {marked = true}
		}
		if !marked {continue}
		compared += 1
		// What each printed must be the same; a file may end in an error under both
		// (its message is each one's own).
		ours, _, _, _, ours_ok := script_run_ours(e.fullpath)
		theirs, lua_stderr, _, lua_ok := script_run_lua(lua, e.fullpath)
		if ours_ok != lua_ok || ours != theirs {
			append(
				broken,
				fmt.aprintf(
					"conformance %s: ours %s, %s %s; %s%s",
					e.name,
					"ran" if ours_ok else "failed",
					lua,
					"ran" if lua_ok else "failed",
					script_first_difference(ours, theirs),
					"" if lua_ok else fmt.tprintf("\n  %s said: %s", lua, script_clip(lua_stderr)),
				),
			)
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("%d conformance files compared with %s", compared, lua)
	if compared == 0 {append(broken, "no conformance file is marked '--! lua'")}
}
