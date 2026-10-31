package tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "tools:build/limited"

// The crash fixture (tests/crash_fixture) starts four named threads, then dies four ways. Each
// run must fail and leave a bundle whose threads.txt names all five threads and whose crash.txt
// names the crashing one (Q3). Where another thread's stack is not collected yet (Windows), only
// the crashing thread's frames are required.
@(private = "file")
fixture_run :: proc(t: ^testing.T, exe: string, mode: string) -> (dir: string, ok: bool) {
	root := fmt.tprintf("build/tmp/crash_bundles_%s", mode)
	os.remove_all(root)
	defer if !ok {}
	result := limited.run_limited({exe, root, mode}, 60 * time.Second)
	testing.expectf(t, result == .Failed, "%s: the fixture did not crash (%v)", mode, result)
	infos, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if !testing.expectf(t, err == nil && len(infos) == 1, "%s: no bundle in %s", mode, root) {
		return
	}
	return fmt.tprintf("%s/%s", root, infos[0].name), true
}

@(private = "file")
text_of :: proc(dir, file: string) -> string {
	data, _ := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s", dir, file),
		context.temp_allocator,
	)
	return string(data)
}

@(test)
test_crash_bundles_name_every_thread :: proc(t: ^testing.T) {
	os.make_directory_all("build/tmp")
	exe := "build/tmp/crash_fixture"
	when ODIN_OS == .Windows {
		exe = "build/tmp/crash_fixture.exe"
	}
	build := slice.concatenate(
		[][]string {
			{"odin", "build", "tests/crash_fixture", fmt.tprintf("-out:%s", exe), "-debug"},
			limited.COLLECTIONS,
		},
		context.temp_allocator,
	)
	if !testing.expect_value(
		t,
		limited.run_limited(build, 120 * time.Second),
		limited.Run_Result.Ok,
	) {return}
	Case :: struct {
		mode, thread, what: string,
	}
	for c in ([]Case{{"main-segv", "main", "signal=SIGSEGV"}, {"worker-segv", "delta", "signal=SIGSEGV"}, {"assert", "main", "the fixture's assert"}, {"overflow", "delta", "stack overflow"}}) {
		when ODIN_OS == .Windows {
			if c.mode != "main-segv" {continue} 	// (the others' stacks: Q3b)
		}
		dir, ok := fixture_run(t, exe, c.mode)
		if !ok {continue}
		crash := text_of(dir, "crash.txt")
		testing.expectf(
			t,
			strings.contains(crash, fmt.tprintf("thread: %s\n", c.thread)),
			"%s: %s",
			c.mode,
			crash,
		)
		testing.expectf(t, strings.contains(crash, c.what), "%s: %s", c.mode, crash)
		threads := text_of(dir, "threads.txt")
		testing.expectf(
			t,
			strings.has_prefix(threads, fmt.tprintf("thread %s (crashing)\n", c.thread)),
			"%s: %s",
			c.mode,
			threads,
		)
		when ODIN_OS != .Windows {
			for name in ([]string{"main", "alpha", "beta", "gamma", "delta"}) {
				testing.expectf(
					t,
					strings.contains(threads, fmt.tprintf("thread %s", name)),
					"%s: no %s in %s",
					c.mode,
					name,
					threads,
				)
			}
			testing.expectf(
				t,
				!strings.contains(threads, "did not answer"),
				"%s: %s",
				c.mode,
				threads,
			)
			testing.expectf(
				t,
				strings.contains(threads, "  at "),
				"%s: no frame of ours in %s",
				c.mode,
				threads,
			)
		}
		testing.expectf(t, len(text_of(dir, "log.txt")) > 0, "%s: an empty log", c.mode)
		os.remove_all(fmt.tprintf("build/tmp/crash_bundles_%s", c.mode))
	}
}
