package base

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Performance history: each benchmark and exit check run appends one JSON
// line to build/perf-history.jsonl (when run from the repository: the
// build/ folder must exist), so runs compare across commits without
// keeping logs:
//
//	{"time":"2026-10-24T23:40:01Z","commit":"1aa8b6b2c3d4","build":"release","test":"bench","light_p50_ms":0.135}
//
// The commit comes from the build driver (-define:VX_COMMIT; "-dirty" with
// uncommitted changes).

COMMIT :: #config(VX_COMMIT, "unknown")
PERF_HISTORY_PATH :: "build/perf-history.jsonl"

Perf_Field :: struct {
	name:  string,
	value: f64,
}

// build_name: the build profile this program was made with (`build build`).
build_name :: proc() -> string {
	when DEV {
		return "debug" when ODIN_OPTIMIZATION_MODE == .None else "development"
	} else {
		return "release" when ODIN_OPTIMIZATION_MODE >= .Speed else "other"
	}
}

// perf_history_append records one run of test.
perf_history_append :: proc(test: string, fields: []Perf_Field) {
	if !os.exists("build") {return}
	b := strings.builder_make(context.temp_allocator)
	stamp, _ := time.time_to_rfc3339(
		time.now(),
		include_nanos = false,
		allocator = context.temp_allocator,
	)
	fmt.sbprintf(
		&b,
		`{{"time":%q,"commit":%q,"build":%q,"test":%q`,
		stamp,
		COMMIT,
		build_name(),
		test,
	)
	for f in fields {fmt.sbprintf(&b, `,%q:%.6g`, f.name, f.value)}
	strings.write_string(&b, "}\n")
	f, err := os.open(PERF_HISTORY_PATH, {.Write, .Create, .Append})
	if err != nil {return}
	defer os.close(f)
	os.write_string(f, strings.to_string(b))
}
