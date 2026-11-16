package build

import "core:strings"
import "core:testing"

// A gate does not queue behind a gate or a test (it would repeat it), and waits behind
// anything else, as every run does. The holder is the lock's text as main writes it.
@(test)
test_gate_refuses_only_a_gate_or_a_test :: proc(t: ^testing.T) {
	why := gate_refusal("pid 41: build test server/core -o:speed")
	testing.expect(t, strings.contains(why, "a test is already running"), why)
	testing.expect(
		t,
		strings.contains(why, "pid 41: build test server/core"),
		"it names the holder",
	)
	testing.expect(t, strings.contains(gate_refusal("pid 41: build gate"), "a gate is already"))
	testing.expect(t, gate_refusal("pid 41: build test") != "")
	testing.expect_value(t, gate_refusal("pid 41: build check"), "")
	testing.expect_value(t, gate_refusal("pid 41: build bench budgets -check"), "")
	testing.expect_value(t, gate_refusal("pid 41: build testkit"), "") // only starts with test
	testing.expect_value(t, gate_refusal("it did not say which"), "")
	testing.expect_value(t, gate_refusal(""), "")
}

// Each stage's log is named for the stage's command, so two stages never share one.
@(test)
test_gate_logs_are_the_stages_own :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	seen := make(map[string]bool)
	for stage in GATE_STAGES {
		log := gate_log(stage.name)
		testing.expectf(t, !seen[log], "%s: a log another stage writes", log)
		seen[log] = true
	}
	testing.expect_value(t, gate_log("check --cross"), path_join({GATE_DIR, "check.log"}))
}

// The summary is a row a stage, the failed ones naming their log, and one last line that
// says it all: `gate PASSED`, or `gate FAILED:` and every failed stage.
@(test)
test_gate_summary_says_what_failed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	all_passed := []Gate_Result {
		{name = "check --cross", passed = true, seconds = 31, log = "build/gate/check.log"},
		{name = "test", passed = true, seconds = 600, log = "build/gate/test.log"},
	}
	text, passed := gate_summary(all_passed)
	testing.expect(t, passed)
	testing.expect(t, strings.has_suffix(text, "\ngate PASSED\n"), text)
	testing.expect(t, !strings.contains(text, "build/gate/"), "a passed stage names no log")
	testing.expect(t, strings.contains(text, "  631 s"), "the total")

	some_failed := []Gate_Result {
		{name = "check --cross", passed = true, seconds = 31, log = "build/gate/check.log"},
		{name = "test", passed = false, seconds = 600, log = "build/gate/test.log"},
		{name = "bench budgets", passed = true, seconds = 40, log = "build/gate/bench.log"},
		{name = "fuzz --smoke", passed = false, seconds = 20, log = "build/gate/fuzz.log"},
	}
	text, passed = gate_summary(some_failed)
	testing.expect(t, !passed)
	testing.expect(t, strings.has_suffix(text, "\ngate FAILED: test, fuzz --smoke\n"), text)
	lines := strings.split_lines(strings.trim_right(text, "\n"), context.temp_allocator)
	testing.expect_value(t, len(lines), 1 + len(some_failed) + 2) // header, stages, total, verdict
	testing.expect(t, strings.has_suffix(lines[2], "build/gate/test.log"), lines[2])
	testing.expect(t, !strings.contains(lines[3], "build/gate/"), lines[3])
	// The columns line up: every row's result starts where the header's does.
	at := strings.index(lines[0], "result")
	for line in lines[1:len(lines) - 2] {
		testing.expect(t, line[at:at + 6] == "passed" || line[at:at + 6] == "FAILED", line)
	}
}
