package build

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// `build bench compare <ref> <scenario> [-runs:N]` (PLAN.md, M19): is the
// working tree faster or slower than <ref> at a scenario? Both are built
// alike (this driver's flags; <ref> in a git worktree under
// build/worktrees/, kept for next time), then run alternately, <ref> and
// the working tree in turn N times (default 5), so heat and whatever else
// the machine is doing fall on both alike. Each run is one number per
// metric (the median of its repetitions' values: base.metric_value), and
// for times their p99 too; a metric's change is called only
// when the two sets of runs differ beyond chance (Mann-Whitney U, two
// sided, p < 0.05). Exact counts that differ are shown first: then the two
// did different work. <ref> must have the benchmark system (results in
// build/benchmarks/).

COMPARE_RUNS :: 5
COMPARE_P :: 0.05

Compare_Side :: struct {
	label:  string,
	root:   string, // its tree
	runs:   [dynamic]map[string]f64, // per run: each metric's median of repetitions
	counts: map[string]int,
	units:  map[string]string,
}

bench_compare :: proc(args: []string) -> bool {
	if len(args) < 2 {
		fmt.eprintln("build: bench compare <ref> <scenario> [-runs:N]")
		return false
	}
	ref, scenario := args[0], args[1]
	runs := COMPARE_RUNS
	for arg in args[2:] {
		if strings.has_prefix(arg, "-runs:") {
			if n, ok := strconv.parse_int(arg[len("-runs:"):]); ok && n >= 2 {runs = n; continue}
		}
		fmt.eprintfln("build: bench compare: not an option '%s' (-runs:N, at least 2)", arg)
		return false
	}
	out, found := capture(
		{"git", "rev-parse", "--short=12", strings.concatenate({ref, "^{commit}"})},
	)
	if !found {
		fmt.eprintfln("build: bench compare: no commit %s", ref)
		return false
	}
	hash := strings.trim_space(out)
	if _, has := capture(
		{"git", "cat-file", "-e", strings.concatenate({hash, ":base/bench_result.odin"})},
	); !has {
		fmt.eprintfln("build: bench compare: %s is older than the benchmark system", ref)
		return false
	}
	main_root, _ := os.get_working_directory(context.allocator)
	worktree := path_join({main_root, "build", "worktrees", hash})
	if !os.exists(worktree) {
		run({"git", "worktree", "add", "--detach", worktree, hash}) or_return
	}
	// The worktree builds shaders with this tree's compiler (no download).
	if glslang, ok := glslang_path(); ok {
		absolute, _ := filepath.abs(glslang, context.allocator)
		os.set_env("GLSLANG", absolute)
	}

	sides := [2]Compare_Side {
		{label = hash, root = worktree},
		{label = "working tree", root = main_root},
	}
	for &side in sides {
		fmt.printfln("bench  building %s (%s)", side.label, side.root)
		os.set_working_directory(side.root)
		os.make_directory_all("build") // (a new worktree has none)
		ok: bool
		if scenario == "chunks" {
			_, ok = build_tool("bench")
		} else {
			_, ok = build_game({"--release"})
		}
		os.set_working_directory(main_root)
		if !ok {return false}
	}
	for i in 0 ..< runs {
		for &side in sides {
			fmt.printfln("bench  run %d of %d: %s", i + 1, runs, side.label)
			compare_run(&side, scenario) or_return
		}
	}
	compare_report(sides[:], scenario)
	return true
}

// compare_run runs the scenario once in side's tree and reads its result.
@(private = "file")
compare_run :: proc(side: ^Compare_Side, scenario: string) -> bool {
	main_root, _ := os.get_working_directory(context.allocator)
	os.set_working_directory(side.root)
	defer os.set_working_directory(main_root)
	exe := path_join({"build", strings.concatenate({"voxiverse", exe_suffix()})})
	cmd := []string{exe, "--benchmark", scenario}
	if scenario ==
	   "chunks" {cmd = {path_join({"build", strings.concatenate({"bench", exe_suffix()})})}}
	if scenario == "server" {
		// The server alone (dedicated/bench.odin).
		cmd = {
			path_join({"build", strings.concatenate({"voxiverse-server", exe_suffix()})}),
			"--benchmark",
			scenario,
		}
	}
	state, stdout, stderr, run_err := os.process_exec(
		os.Process_Desc{command = cmd},
		context.allocator,
	)
	if run_err != nil || !state.exited || state.exit_code != 0 {
		// Its last words: why.
		out := strings.concatenate({string(stdout), string(stderr)})
		lines := strings.split_lines(strings.trim_space(out))
		fmt.eprintfln(
			"build: bench compare: the run failed in %s (%v, exit %d); its last lines:",
			side.root,
			run_err,
			state.exit_code,
		)
		for l in lines[max(0, len(lines) - 12):] {fmt.eprintln("  ", l)}
		return false
	}
	// Its result: the newest file of the scenario's.
	dir := path_join({"build", "benchmarks", scenario})
	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil || len(files) == 0 {
		fmt.eprintfln("build: bench compare: no results in %s/%s", side.root, dir)
		return false
	}
	newest := files[0]
	for f in files {if f.modification_time._nsec > newest.modification_time._nsec {newest = f}}
	data, read_err := os.read_entire_file_from_path(newest.fullpath, context.allocator)
	if read_err != nil {return false}
	value, parse_err := json.parse(data)
	if parse_err != nil {
		fmt.eprintfln("build: bench compare: %s does not parse (%v)", newest.fullpath, parse_err)
		return false
	}
	root := value.(json.Object)
	medians: map[string][dynamic]f64
	for rep in root["repetitions"].(json.Array) {
		for name, m in rep.(json.Object) {
			fields := m.(json.Object)
			if name not_in medians {medians[name] = {}}
			// Its value (base.metric_value: a median, or a mean for load);
			// results from before values were written have medians.
			chosen, has := fields["value"]
			append(&medians[name], number(chosen if has else fields["median"]))
			// Times also by their worst 1%: hitches and spikes matter as much
			// as the middle (a fix to those may not move it at all).
			if fields["unit"].(json.String) == "ms" {
				tail := strings.concatenate({name, " p99"})
				if tail not_in medians {medians[tail] = {}}
				append(&medians[tail], number(fields["p99"]))
				side.units[tail] = "ms"
			}
			side.units[name] = fields["unit"].(json.String)
		}
	}
	run: map[string]f64
	for name, values in medians {run[name] = median(values[:])}
	append(&side.runs, run)
	for name, v in root["counts"].(json.Object) {side.counts[name] = int(number(v))}
	return true
}

// number: a JSON number, written as an integer or not.
@(private = "file")
number :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer:
		return f64(n)
	case json.Float:
		return f64(n)
	}
	return 0
}

@(private = "file")
compare_report :: proc(sides: []Compare_Side, scenario: string) {
	ref, work := &sides[0], &sides[1]
	fmt.printfln(
		"\nbench compare %s: %s (A) against the working tree (B), %d runs each, alternating",
		scenario,
		ref.label,
		len(ref.runs),
	)
	for name, a in ref.counts {
		if b, ok := work.counts[name]; ok && a != b {
			fmt.printfln("  COUNTS DIFFER: %s %d -> %d (the two did different work)", name, a, b)
		}
	}
	names := make([dynamic]string)
	for name in ref.units {if name in work.units {append(&names, name)}}
	slice.sort(names[:])
	fmt.printfln("  %-22s %10s %10s %8s %7s  %s", "metric", "A", "B", "change", "p", "")
	for name in names {
		a, b := make([dynamic]f64), make([dynamic]f64)
		for r in ref.runs {if v, ok := r[name]; ok {append(&a, v)}}
		for r in work.runs {if v, ok := r[name]; ok {append(&b, v)}}
		if len(a) == 0 || len(b) == 0 {continue}
		ma, mb := median(a[:]), median(b[:])
		change := (mb - ma) / ma * 100 if ma != 0 else 0
		p := mann_whitney_p(a[:], b[:])
		unit := ref.units[name]
		verdict := ""
		if p < COMPARE_P {
			lower_better := unit == "ms" || unit == "s"
			if lower_better {verdict = "faster" if mb < ma else "SLOWER"} else {verdict = "fewer" if mb < ma else "more"}
		}
		fmt.printfln(
			"  %-22s %10s %10s %8s %7s  %s",
			fmt.tprintf("%s (%s)", name, unit),
			fmt.tprintf("%.3f", ma),
			fmt.tprintf("%.3f", mb),
			fmt.tprintf("%+.1f%%", change),
			fmt.tprintf("%.3f", p),
			verdict,
		)
	}
	fmt.printfln(
		"  (a change is called at p < %.2f; with %d runs each the smallest p is %.3f)",
		COMPARE_P,
		len(ref.runs),
		mann_whitney_p_floor(len(ref.runs), len(work.runs)),
	)
}

@(private = "file")
median :: proc(values: []f64) -> f64 {
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	n := len(sorted)
	if n == 0 {return 0}
	return sorted[n / 2] if n % 2 == 1 else (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}

// mann_whitney_p: the two-sided p of the Mann-Whitney U test that a and b
// come from one distribution (exact, from the distribution of U without
// ties; a tie counts half).
mann_whitney_p :: proc(a, b: []f64) -> f64 {
	u: f64
	for x in a {
		for y in b {
			if x > y {u += 1} else if x == y {u += 0.5}
		}
	}
	n1, n2 := len(a), len(b)
	counts := u_distribution(n1, n2)
	total: f64
	for c in counts {total += c}
	// P(U <= u) and P(U >= u), from the exact counts.
	low, high: f64
	for c, k in counts {
		if f64(k) <= u {low += c}
		if f64(k) >= u {high += c}
	}
	return min(1, 2 * min(low, high) / total)
}

// mann_whitney_p_floor: the smallest p any two sets of these sizes give.
mann_whitney_p_floor :: proc(n1, n2: int) -> f64 {
	counts := u_distribution(n1, n2)
	total: f64
	for c in counts {total += c}
	return min(1, 2 * counts[0] / total)
}

// u_distribution: how many arrangements of n1 and n2 values give each U
// (0 .. n1 n2): f(n, m, u) = f(n - 1, m, u - m) + f(n, m - 1, u).
@(private = "file")
u_distribution :: proc(n1, n2: int) -> []f64 {
	// table[n][m] is the distribution for n and m values.
	prev := make([][]f64, n2 + 1, context.temp_allocator)
	for m in 0 ..= n2 {
		prev[m] = make([]f64, 1, context.temp_allocator)
		prev[m][0] = 1
	}
	for n in 1 ..= n1 {
		cur := make([][]f64, n2 + 1, context.temp_allocator)
		cur[0] = make([]f64, 1, context.temp_allocator)
		cur[0][0] = 1
		for m in 1 ..= n2 {
			d := make([]f64, n * m + 1, context.temp_allocator)
			for u in 0 ..= n * m {
				if u - m >= 0 && u - m < len(prev[m]) {d[u] += prev[m][u - m]}
				if u < len(cur[m - 1]) {d[u] += cur[m - 1][u]}
			}
			cur[m] = d
		}
		prev = cur
	}
	return prev[n2]
}
