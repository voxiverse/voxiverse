package fuzz

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "common:base"

TEST_OUT :: "build/tmp/fuzz-test"

toy_boom :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	if string(data) == "boom" {fail("boom reached")}
	return u64(len(data) % 4)
}

toy_bool_generator :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	append(out, "bool")
}

toy_leak :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	_ = make([]u8, 10, allocator)
	return 0
}

toy_big :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	b := make([]u8, 1 << 20, allocator)
	delete(b, allocator)
	return 0
}

// other_ready: another target has installed its crash state on another thread.
other_ready: sync.Sema

toy_assert :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	// (the other target installs after this one did: a process-wide state would now hold its name)
	sync.sema_wait_with_timeout(&other_ready, 5 * time.Second)
	assert(len(data) > 1000, "the toy always fails")
	return 0
}

@(test)
test_mutator_is_deterministic :: proc(t: ^testing.T) {
	run :: proc(seed: u64) -> []u8 {
		r := base.rng_make(seed)
		buf: [dynamic]u8
		append(&buf, "hello fuzzing world")
		for _ in 0 ..< 50 {mutate(&r, &buf, transmute([]u8)string("other input"), {"tok"})}
		return buf[:]
	}
	a, b, c := run(84), run(84), run(85)
	defer {delete(a); delete(b); delete(c)}
	testing.expect(t, string(a) == string(b), "same seed, same mutations")
	testing.expect(t, string(a) != string(c), "another seed, other mutations")
}

@(test)
test_toy_failure_is_found_saved_and_minimized :: proc(t: ^testing.T) {
	target := Target {
		name       = "toy.boom",
		run        = toy_boom,
		max_len    = 64,
		generate   = toy_bool_generator,
		dictionary = {"m", "boom"},
	}
	report := run_target(&target, {seed = 84, cases = 200_000, out_dir = TEST_OUT})
	defer {
		for f in report.failures {delete(f)}
		delete(report.failures)
	}
	testing.expect(t, len(report.failures) > 0, "the toy failure is found by mutation from 'bool'")
	if len(report.failures) == 0 {return}
	line := report.failures[0]
	open := strings.last_index(line, "(")
	path := line[open + 1:len(line) - 1]
	found, err := os.read_entire_file_from_path(path, context.allocator)
	defer delete(found)
	testing.expect(t, err == nil, "the input was saved")
	check :: proc(candidate: []u8, user: rawptr) -> string {
		tg := (^Target)(user)
		res := run_case(tg, candidate)
		defer delete(res.detail)
		return strings.clone(res.detail, context.temp_allocator)
	}
	min := minimize(found, check, &target)
	defer delete(min)
	testing.expect_value(t, string(min), "boom")
}

@(test)
test_leak_is_named :: proc(t: ^testing.T) {
	target := Target {
		name    = "toy.leak",
		run     = toy_leak,
		max_len = 16,
	}
	res := run_case(&target, {})
	defer delete(res.detail)
	testing.expect_value(t, res.failure, Failure.Leak)
	testing.expect(t, strings.contains(res.detail, "fuzz_test.odin:"), res.detail)
}

@(test)
test_allocation_past_the_cap_fails :: proc(t: ^testing.T) {
	target := Target {
		name    = "toy.big",
		run     = toy_big,
		max_len = 16,
	}
	res := run_case(&target, {})
	defer delete(res.detail)
	testing.expect_value(t, res.failure, Failure.Over_Cap)
}

@(test)
test_new_signature_joins_the_corpus :: proc(t: ^testing.T) {
	c: Corpus
	corpus_init(&c)
	defer corpus_destroy(&c)
	testing.expect(t, corpus_offer(&c, {1}, 7), "a new signature is kept")
	testing.expect(t, !corpus_offer(&c, {2}, 7), "a seen signature is dropped")
	testing.expect(t, corpus_offer(&c, {3}, 8))
	testing.expect_value(t, len(c.inputs), 2)
}

@(test)
test_watchdog_limit :: proc(t: ^testing.T) {
	second := i64(1_000_000_000)
	testing.expect(t, !hung(0, 100 * second), "no case running")
	testing.expect(t, !hung(second, 5 * second))
	testing.expect(t, hung(second, (HANG_SECONDS + 2) * second))
}

// The crash path, in a child process (it ends the process): the parent starts this test's
// own binary (the runner's test filter is a compile-time define: the child runs the suite,
// and every test but test_child_crash does its usual work) and looks for the saved input.
@(test)
test_crash_saves_the_input :: proc(t: ^testing.T) {
	// (the child runs the whole suite, this test included: it must not start a child itself)
	if os.get_env("VX_FUZZ_CHILD", context.temp_allocator) == "1" {return}
	dir := TEST_OUT + "/toy.assert"
	os.remove_all(dir)
	os.remove_all(TEST_OUT + "/toy.other")
	self, _ := os.get_executable_path(context.temp_allocator)
	desc := os.Process_Desc {
		command = {self},
		env     = {"VX_FUZZ_CHILD=1"},
	}
	_, stdout, stderr, err := os.process_exec(desc, context.allocator)
	defer {delete(stdout); delete(stderr)}
	testing.expectf(t, err == nil, "the child ran: %v %v", err, self)
	testing.expect(t, strings.contains(string(stderr), "fuzz-failure:"), string(stderr))
	files, _ := os.read_all_directory_by_path(dir, context.allocator)
	defer os.file_info_slice_delete(files, context.allocator)
	bins := 0
	for f in files {
		if strings.has_suffix(f.name, ".bin") {bins += 1}
	}
	testing.expect_value(t, bins, 1)
	// (and nothing under the name of the target that was only installed beside it)
	other, _ := os.read_all_directory_by_path(TEST_OUT + "/toy.other", context.allocator)
	defer os.file_info_slice_delete(other, context.allocator)
	for f in other {
		testing.expectf(
			t,
			!strings.has_suffix(f.name, ".bin"),
			"saved under the wrong target: %s",
			f.name,
		)
	}
}

@(test)
test_child_crash :: proc(t: ^testing.T) {
	if os.get_env("VX_FUZZ_CHILD", context.temp_allocator) != "1" {return}
	target := Target {
		name    = "toy.assert",
		run     = toy_assert,
		max_len = 64,
	}
	// Two targets in one process: another thread installs its own state while this target
	// runs; the crash is saved under this one's name.
	other := thread.create_and_start_with_poly_data(&other_ready, proc(ready: ^sync.Sema) {
			other_target := Target {
				name    = "toy.other",
				run     = toy_boom,
				max_len = 16,
			}
			crash_install(&other_target, {seed = 2, out_dir = TEST_OUT})
			sync.sema_post(ready)
		})
	defer thread.destroy(other)
	run_target(&target, {seed = 1, cases = 10, out_dir = TEST_OUT})
}
