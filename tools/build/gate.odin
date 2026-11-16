package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "common:limited"

// `build gate`: the whole gate in one blocking run, each stage the driver's own command run
// as a child of this one, its output kept in build/gate/<stage>.log. A stage that fails does
// not stop the run, so one run says everything that is wrong; it ends with a table and one
// line, `gate PASSED` or `gate FAILED: <stages>`. The gate holds the build lock for all of
// it (its stages run under it: GATE_ENV), and it does not wait behind another gate or test
// (gate_refuses): it says so and ends.

// Gate_Stage: one step of the gate, as the summary names it and as the driver runs it.
Gate_Stage :: struct {
	name: string,
	args: []string,
}

// GATE_STAGES, in order: the type checks first (with the other targets'), then every test
// (the packages, then the image baselines), the benchmark budgets, the fuzzers' smoke run.
GATE_STAGES :: []Gate_Stage {
	{"check --cross", {"check", "--cross"}},
	{"test", {"test"}},
	{"bench budgets", {"bench", "budgets", "-check"}},
	{"fuzz --smoke", {"fuzz", "--smoke"}},
}

// GATE_DIR: where each stage's log is kept.
GATE_DIR :: "build/gate"

// GATE_ENV: what the gate tells the runs it starts, its own pid. A run whose parent has
// that pid is one of its stages, and runs under the gate's lock instead of waiting for it.
GATE_ENV :: "VX_GATE_PID"

// Gate_Result: how one stage ended.
Gate_Result :: struct {
	name:    string,
	passed:  bool,
	seconds: f64,
	log:     string,
}

// gate_stage_run: this run is a stage of a gate (its parent, which holds the lock).
gate_stage_run :: proc() -> bool {
	value := os.get_env(GATE_ENV, context.temp_allocator)
	pid, ok := strconv.parse_int(value)
	return ok && pid == os.get_ppid()
}

// gate_refusal: a gate does not start while the run holding the lock (holder: the lock's
// text, "pid <n>: build <command> ...") is a gate or a test, which it would only wait for
// and then repeat; why says so ("": it waits, as every run does, behind anything else).
gate_refusal :: proc(holder: string) -> (why: string) {
	_, found, command := strings.partition(holder, ": build ")
	if found == "" {return ""}
	name, _, _ := strings.partition(command, " ")
	if name != "gate" && name != "test" {return ""}
	return fmt.tprintf(
		"build: gate: a %s is already running in this tree (%s); not starting a second one: wait for it, or run the gate again when it has ended",
		name,
		holder,
	)
}

// gate_log: where a stage's output is kept ("check --cross": build/gate/check.log).
gate_log :: proc(name: string) -> string {
	first, _, _ := strings.partition(name, " ")
	return path_join({GATE_DIR, strings.concatenate({first, ".log"})})
}

// gate runs GATE_STAGES one after another, a line for each as it ends, then the failed
// stages' excerpts and the summary.
gate :: proc(args: []string) -> bool {
	if len(args) > 0 {
		fmt.eprintln("build: gate takes no arguments (it is the whole gate)")
		return false
	}
	os.make_directory_all(GATE_DIR)
	os.set_env(GATE_ENV, fmt.tprint(os.get_pid()))
	fmt.printfln(
		"gate: %d stages, one after another; their logs in %s/",
		len(GATE_STAGES),
		GATE_DIR,
	)
	results := make([]Gate_Result, len(GATE_STAGES))
	statuses := make([]int, len(GATE_STAGES))
	for stage, i in GATE_STAGES {
		log := gate_log(stage.name)
		cmd := make([dynamic]string)
		append(&cmd, os.args[0])
		append(&cmd, ..stage.args)
		job := limited.Job {
			cmd    = cmd[:],
			log    = log,
			quiet  = true,
			status = &statuses[i],
		}
		started := time.tick_now()
		ended := parallel({job}, 1)
		results[i] = {
			name    = stage.name,
			passed  = ended[0] == .Ok,
			seconds = time.duration_seconds(time.tick_since(started)),
			log     = log,
		}
		fmt.printfln("%s", gate_line(results[i]))
	}
	for r, i in results {
		if r.passed {continue}
		data, _ := os.read_entire_file_from_path(r.log, context.temp_allocator)
		fmt.printfln("\n--- %s FAILED: its whole output is %s ---", r.name, r.log)
		fmt.print(failure_excerpt(string(data), statuses[i]))
	}
	fmt.println()
	summary, passed := gate_summary(results)
	fmt.print(summary)
	return passed
}

// gate_line: a stage's line as it ends.
gate_line :: proc(r: Gate_Result) -> string {
	return fmt.tprintf(
		"gate   %s %s (%.0f s)",
		r.name,
		"passed" if r.passed else "FAILED",
		r.seconds,
	)
}

// gate_summary: the table of the stages and the last line, `gate PASSED` or `gate FAILED:`
// and the failed stages' names; passed: none failed.
gate_summary :: proc(results: []Gate_Result) -> (text: string, passed: bool) {
	width := len("stage")
	for r in results {width = max(width, len(r.name))}
	b := strings.builder_make()
	fmt.sbprintfln(&b, "%-*s  result  time    log", width, "stage")
	failed := make([dynamic]string, context.temp_allocator)
	total: f64
	for r in results {
		fmt.sbprintf(
			&b,
			"%-*s  %-6s  %5.0f s",
			width,
			r.name,
			"passed" if r.passed else "FAILED",
			r.seconds,
		)
		if !r.passed {
			fmt.sbprintf(&b, "  %s", r.log)
			append(&failed, r.name)
		}
		fmt.sbprintln(&b)
		total += r.seconds
	}
	fmt.sbprintfln(&b, "%-*s          %5.0f s", width, "total", total)
	if len(failed) == 0 {
		fmt.sbprintln(&b, "gate PASSED")
	} else {
		fmt.sbprintfln(
			&b,
			"gate FAILED: %s",
			strings.join(failed[:], ", ", context.temp_allocator),
		)
	}
	return strings.to_string(b), len(failed) == 0
}
