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
