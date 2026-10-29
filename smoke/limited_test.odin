package smoke

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

import "../tools/build/limited"

// A command that outlasts its limit is killed with its children, and says so.
@(test)
test_run_limited_kills_the_tree :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	marker := "build/tmp/hang_test_child"
	os.make_directory_all("build/tmp")
	os.remove(marker)
	start := time.tick_now()
	// The shell starts a child of its own, which would write the marker if it lived.
	result := limited.run_limited(
		{"sh", "-c", fmt.tprintf("(sleep 3; : > %s) & wait", marker)},
		time.Second,
	)
	testing.expect_value(t, result, limited.Run_Result.Timed_Out)
	testing.expect(t, time.duration_seconds(time.tick_since(start)) < 3, "the kill took too long")
	time.sleep(4 * time.Second)
	testing.expect(t, !os.exists(marker), "a child outlived the kill")
	os.remove(marker)
}

@(test)
test_run_limited_results :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		testing.expect_value(t, limited.run_limited({"true"}, time.Minute), limited.Run_Result.Ok)
		testing.expect_value(
			t,
			limited.run_limited({"false"}, time.Minute),
			limited.Run_Result.Failed,
		)
	}
}

// A panic on a thread the test started (a server's worker) once spun the Odin runner at
// full CPU for ever (voxiverse#54). The fixture package panics on purpose in a job worker
// with a server running; the run must fail, not time out, within seconds.
@(test)
test_panic_in_a_server_thread_fails_fast :: proc(t: ^testing.T) {
	os.make_directory_all("build/tmp")
	out := "-out:build/tmp/panic_fixture"
	when ODIN_OS == .Windows {
		out = "-out:build/tmp/panic_fixture.exe" // Odin wants an extension there
	}
	cmd := []string {
		"odin",
		"test",
		"smoke/panic_fixture",
		out,
		"-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true",
	}
	start := time.tick_now()
	result := limited.run_limited(cmd, 120 * time.Second)
	took := time.duration_seconds(time.tick_since(start))
	testing.expect_value(t, result, limited.Run_Result.Failed)
	// The compile is most of it; the panic itself ends the run in about a second.
	testing.expectf(t, took < 100, "the panicking run took %.0f s", took)
}

// run_parallel: each job's result in its place, a quiet job's output left in its log, and
// one over its limit killed while the others finish.
@(test)
test_run_parallel_results :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	os.make_directory_all("build/tmp")
	jobs := []limited.Job {
		{cmd = {"sh", "-c", "echo hello"}, log = "build/tmp/parallel_0.log", quiet = true},
		{cmd = {"sh", "-c", "exit 3"}, log = "build/tmp/parallel_1.log"},
		{cmd = {"sh", "-c", "sleep 30"}, log = "build/tmp/parallel_2.log", limit = time.Second},
		{cmd = {"true"}, log = "build/tmp/parallel_3.log"},
	}
	start := time.tick_now()
	results := limited.run_parallel(jobs, 2, allocator = context.temp_allocator)
	testing.expect(t, time.duration_seconds(time.tick_since(start)) < 20, "the limit was not kept")
	testing.expect_value(t, results[0], limited.Run_Result.Ok)
	testing.expect_value(t, results[1], limited.Run_Result.Failed)
	testing.expect_value(t, results[2], limited.Run_Result.Timed_Out)
	testing.expect_value(t, results[3], limited.Run_Result.Ok)
	out, _ := os.read_entire_file_from_path("build/tmp/parallel_0.log", context.temp_allocator)
	testing.expect_value(t, string(out), "hello\n")
	for j in jobs {os.remove(j.log)}
}

// A stop request (Ctrl-C) kills the running jobs with their children and starts no
// more: each running one is reported Interrupted, and so is each one left. The request
// comes from done, as the first job ends (a real signal would stop the test runner).
@(test)
test_run_parallel_stops_on_request :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	marker := "build/tmp/parallel_stop_child"
	os.make_directory_all("build/tmp")
	os.remove(marker)
	jobs := []limited.Job {
		{cmd = {"true"}, log = "build/tmp/parallel_stop_0.log"},
		{
			cmd = {"sh", "-c", fmt.tprintf("(sleep 3; : > %s) & wait", marker)},
			log = "build/tmp/parallel_stop_1.log",
		},
		{cmd = {"true"}, log = "build/tmp/parallel_stop_2.log"},
	}
	stop :: proc(data: rawptr, index: int, result: limited.Run_Result, seconds: f64) {
		heard := (^[3]limited.Run_Result)(data)
		heard[index] = result
		if index == 0 {limited.request_stop()}
	}
	heard := [3]limited.Run_Result{.Failed, .Failed, .Failed}
	start := time.tick_now()
	results := limited.run_parallel(jobs, 2, stop, &heard, context.temp_allocator)
	took := time.duration_seconds(time.tick_since(start))
	limited.clear_stop()
	testing.expect(t, took < 3, "the stop took too long")
	testing.expect_value(t, results[0], limited.Run_Result.Ok)
	testing.expect_value(t, results[1], limited.Run_Result.Interrupted)
	testing.expect_value(t, results[2], limited.Run_Result.Interrupted)
	testing.expect_value(t, heard[1], limited.Run_Result.Interrupted)
	testing.expect_value(t, heard[2], limited.Run_Result.Failed) // never started: not told
	time.sleep(4 * time.Second)
	testing.expect(t, !os.exists(marker), "a child outlived the stop")
	for j in jobs {os.remove(j.log)}
	os.remove(marker)
}
