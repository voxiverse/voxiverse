package base

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Benchmark results (PLAN.md, M19): one JSON file per run in
// build/benchmarks/<scenario>/, a line per run in build/benchmarks/history.jsonl.
// A run is a scenario's repetitions, each with every metric it recorded,
// and the exact counts that must not change unless the work did. Results
// carry the machine: they compare only within one (its fingerprint).
// Nothing here is committed: build/ is the developer's.

// The commit a build was made from (the build driver stamps it in with
// -define:VX_COMMIT; "-dirty" with uncommitted changes).
COMMIT :: #config(VX_COMMIT, "unknown")

// build_name: the build profile this program was made with (`build build`).
build_name :: proc() -> string {
	when DEV {
		return "debug" when ODIN_OPTIMIZATION_MODE == .None else "development"
	} else {
		return "release" when ODIN_OPTIMIZATION_MODE >= .Speed else "other"
	}
}

BENCH_DIR :: "build/benchmarks" // (build/bench is the chunk benchmark's executable)
BENCH_SCHEMA :: 1

Bench_Count :: struct {
	name:  string,
	value: int,
}

Bench_Result :: struct {
	scenario:    string,
	version:     int, // the scenario's: results of different versions never compare
	gpu:         string, // device name ("" without one)
	driver:      string,
	resolution:  [2]int, // what was drawn ({0, 0}: nothing)
	repetitions: [dynamic][Metric]Metric_Summary,
	counts:      [dynamic]Bench_Count,
}

// bench_repetition_end stops recording and keeps the metrics as one
// repetition.
bench_repetition_end :: proc(r: ^Bench_Result) {
	metrics_stop()
	rep: [Metric]Metric_Summary
	for m in Metric {rep[m] = metric_summary(m)}
	append(&r.repetitions, rep)
}

bench_result_destroy :: proc(r: ^Bench_Result) {
	delete(r.repetitions)
	delete(r.counts)
}

// Machine: what a result was measured on.
Machine :: struct {
	cpu:         string,
	cores:       int,
	threads:     int,
	os:          string,
	fingerprint: string, // a hash of the rest and the GPU's: results compare within one
}

machine_info :: proc(gpu, driver: string, allocator := context.temp_allocator) -> (m: Machine) {
	cpu: string
	cpu, m.cores, m.threads, m.os = machine_facts(allocator)
	m.cpu = strings.trim_space(cpu)
	if m.cpu == "" {m.cpu = "unknown"}
	key := fmt.tprintf("%s|%d|%d|%s|%s|%s", m.cpu, m.cores, m.threads, m.os, gpu, driver)
	m.fingerprint = fmt.aprintf("%08x", hash.fnv32a(transmute([]u8)key), allocator = allocator)
	return
}

// bench_result_write writes r's file and history line; the file's path, or
// "" if it could not.
bench_result_write :: proc(r: ^Bench_Result) -> string {
	dir := filepath.join({BENCH_DIR, r.scenario}, context.temp_allocator) or_else BENCH_DIR
	os.make_directory_all(dir) // (an error here shows as the file failing)
	machine := machine_info(r.gpu, r.driver)
	stamp, _ := time.time_to_rfc3339(
		time.now(),
		include_nanos = false,
		allocator = context.temp_allocator,
	)
	head := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&head,
		`"schema":%d,"scenario":%q,"version":%d,"time":%q,"commit":%q,"build":%q,"resolution":[%d,%d],` +
		`"machine":{{"fingerprint":%q,"cpu":%q,"cores":%d,"threads":%d,"os":%q,"gpu":%q,"driver":%q}},"counts":{{`,
		BENCH_SCHEMA,
		r.scenario,
		r.version,
		stamp,
		COMMIT,
		build_name(),
		r.resolution.x,
		r.resolution.y,
		machine.fingerprint,
		machine.cpu,
		machine.cores,
		machine.threads,
		machine.os,
		r.gpu,
		r.driver,
	)
	for c, i in r.counts {fmt.sbprintf(&head, `%s%q:%d`, "," if i > 0 else "", c.name, c.value)}
	strings.write_string(&head, "}")

	// The file: every repetition's every recorded metric.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	strings.write_string(&b, strings.to_string(head))
	strings.write_string(&b, `,"repetitions":[`)
	for rep, i in r.repetitions {
		strings.write_string(&b, "," if i > 0 else "")
		write_metrics(&b, rep)
	}
	strings.write_string(&b, "]}\n")
	name := fmt.tprintf(
		"%s-%s.json",
		strings.concatenate(
			{stamp[:10], "T", stamp[11:13], stamp[14:16], stamp[17:19]},
			context.temp_allocator,
		),
		COMMIT,
	)
	path := filepath.join({dir, name}, context.temp_allocator) or_else name
	if os.write_entire_file(path, transmute([]u8)strings.to_string(b)) != nil {return ""}

	// The history line: each metric's value (metric_value), the median over
	// the repetitions.
	h := strings.builder_make(context.temp_allocator)
	strings.write_string(&h, "{")
	strings.write_string(&h, strings.to_string(head))
	fmt.sbprintf(&h, `,"repetitions":%d,"medians":{{`, len(r.repetitions))
	first := true
	for m in Metric {
		medians := make([dynamic]f64, context.temp_allocator)
		for rep in r.repetitions {if rep[m].count > 0 {append(&medians, metric_value(m, rep[m]))}}
		if len(medians) == 0 {continue}
		fmt.sbprintf(
			&h,
			`%s%q:%.6g`,
			"" if first else ",",
			METRIC_INFO[m].name,
			median_of(medians[:]),
		)
		first = false
	}
	strings.write_string(&h, "}}\n")
	history :=
		filepath.join({BENCH_DIR, "history.jsonl"}, context.temp_allocator) or_else "history.jsonl"
	if f, err := os.open(history, {.Write, .Create, .Append}); err == nil {
		os.write_string(f, strings.to_string(h))
		os.close(f)
	}
	return path
}

@(private = "file")
write_metrics :: proc(b: ^strings.Builder, rep: [Metric]Metric_Summary) {
	strings.write_string(b, "{")
	first := true
	for s, m in rep {
		if s.count == 0 {continue}
		fmt.sbprintf(
			b,
			`%s%q:{{"unit":%q,"value":%.6g,"count":%d,"mean":%.6g,"median":%.6g,"p10":%.6g,"p90":%.6g,"p99":%.6g}}`,
			"" if first else ",",
			METRIC_INFO[m].name,
			METRIC_INFO[m].unit,
			metric_value(m, s),
			s.count,
			s.mean,
			s.median,
			s.p10,
			s.p90,
			s.p99,
		)
		first = false
	}
	strings.write_string(b, "}")
}

// median_of sorts values in place.
median_of :: proc(values: []f64) -> f64 {
	if len(values) == 0 {return 0}
	for i in 1 ..< len(values) {
		for j := i;
		    j > 0 && values[j] < values[j - 1];
		    j -= 1 {values[j], values[j - 1] = values[j - 1], values[j]}
	}
	n := len(values)
	return values[n / 2] if n % 2 == 1 else (values[n / 2 - 1] + values[n / 2]) / 2
}
