package bench

import "core:fmt"
import "core:os"
import "core:strings"

import "common:base"

// How `-check` judges a budget: the median of CHECK_RUNS runs (unless
// -repetitions says otherwise) of the quantity against its limit, so one noisy
// run decides nothing. A scene or stage that fails to run in any run is
// "broken", reported on its own and failing at once: a median never hides it.
// Every table prints each run's value beside the median, and the result file keeps
// every run (base.Bench_Result).

CHECK_RUNS :: 5

// judge_runs: how many times a bench does the whole: what was asked, else CHECK_RUNS
// when checking, else 3.
judge_runs :: proc(asked: int, check: bool) -> int {
	if asked > 0 {return asked}
	return CHECK_RUNS if check else 3
}

// judge_runs_text: the runs' values in order, "12.3 12.9 11.8".
judge_runs_text :: proc(values: []f64, decimals: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v, i in values {
		if i > 0 {strings.write_string(&b, " ")}
		fmt.sbprintf(&b, "%.*f", decimals, v)
	}
	return strings.to_string(b)
}

// judge_metric_runs: each run's value of m (base.metric_value), for the runs that
// recorded any.
judge_metric_runs :: proc(result: ^base.Bench_Result, m: base.Metric) -> [dynamic]f64 {
	values := make([dynamic]f64, context.temp_allocator)
	for r in result.repetitions {
		if r[m].count > 0 {append(&values, base.metric_value(m, r[m]))}
	}
	return values
}

// judge_end prints what failed and exits 1 if anything did: the broken first, then
// what was over budget.
judge_end :: proc(broken, over: []string, check: bool) {
	for f in broken {fmt.eprintfln("bench broken: %s", f)}
	for f in over {fmt.eprintfln("bench over budget: %s", f)}
	if len(broken) + len(over) > 0 {os.exit(1)}
	if check {fmt.println("bench check passed")}
}
