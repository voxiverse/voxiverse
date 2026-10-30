#+build darwin
package smoke

import "core:os"
import "core:testing"
import "core:time"

import "../tools/build/limited"

// The window's zoom and green buttons against a real AppKit window. AppKit takes windows
// only on a process's main thread and the test runner's tests run on another, so
// smoke/window_fixture, a program of its own, does the driving and exits 1 on a failed check.
@(test)
test_zoom_and_green_button :: proc(t: ^testing.T) {
	os.make_directory_all("build/tmp")
	build := []string {
		"odin",
		"build",
		"smoke/window_fixture",
		"-out:build/tmp/window_fixture",
		"-vet",
		"-strict-style",
		"-warnings-as-errors",
	}
	if !testing.expect_value(
		t,
		limited.run_limited(build, 120 * time.Second),
		limited.Run_Result.Ok,
	) {return}
	testing.expect_value(
		t,
		limited.run_limited({"build/tmp/window_fixture"}, 60 * time.Second),
		limited.Run_Result.Ok,
	)
}
