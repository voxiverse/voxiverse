package build

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// Following a log that grows in many small appends costs the new bytes each poll, not a
// copy of the whole log: the watcher's allocation stays far below the log's size, and the
// tests it reports are the ones in the log.
@(test)
test_watch_poll_allocates_for_new_bytes_only :: proc(t: ^testing.T) {
	dir := "build/tmp/test_watch_test"
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/grow.log"})
	defer delete(path)

	w := new(Test_Watch)
	defer free(w)
	w.log = path
	f, err := os.open(path, {.Write, .Create, .Trunc})
	testing.expect_value(t, err, nil)
	defer os.close(f)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.default_allocator())
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	filler := strings.repeat("x", 200)
	defer delete(filler)
	written := 0
	tests := 0
	poll :: proc(w: ^Test_Watch, alloc: runtime.Allocator) {
		context.allocator = alloc
		context.temp_allocator = alloc
		test_watch_poll(w)
	}
	{
		for i in 0 ..< 20000 {
			line: string
			if i % 1000 == 0 {
				line = fmt.tprintf(
					"[INFO ] --- Test #%d main.test_%d changed state to Running.\n",
					tests,
					tests,
				)
			} else if i % 1000 == 1 {
				line = fmt.tprintf(
					"[INFO ] --- Test #%d main.test_%d changed state to Successful.\n",
					tests,
					tests,
				)
				tests += 1
			} else {
				line = fmt.tprintf("%s\n", filler)
			}
			n, _ := os.write_string(f, line)
			written += n
			if i % 7 == 0 { 	// a partial last line now and then
				os.write_string(f, "partial")
				written += 7
				poll(w, alloc)
				os.write_string(f, "\n")
				written += 1
			}
			poll(w, alloc)
		}
	}
	testing.expectf(t, written > 4_000_000, "the log is only %d bytes", written)
	testing.expect_value(t, len(w.events), tests)
	for e, i in w.events {
		testing.expect_value(t, e.test, fmt.tprintf("main.test_%d", i))
		testing.expect_value(t, e.result, "pass")
	}
	testing.expect_value(t, len(w.started), 0)
	testing.expectf(
		t,
		int(track.total_memory_allocated) < written / 4,
		"the watcher allocated %d bytes following a %d byte log",
		track.total_memory_allocated,
		written,
	)
}
