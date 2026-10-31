package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:base"

// M46b: one process has a universe open at a time (the lock file).

// refused: whether the lock is refused (which the server logs as an error: quieted).
refused :: proc(dir: string) -> bool {
	loud := context.logger
	quiet := loud
	quiet.lowest_level = .Fatal
	context.logger = quiet
	defer context.logger = loud
	probe: Store
	if universe_lock(&probe, dir) {
		base.file_unlock(&probe.lock)
		return false
	}
	return true
}

@(test)
test_second_open_sees_the_lock :: proc(t: ^testing.T) {
	dir := scratch_dir("lock")
	defer delete(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	first: Store
	testing.expect(t, universe_lock(&first, dir), "the first open was refused")
	testing.expect(t, refused(dir), "a second open of the same universe was allowed")
	// An export is a second user too.
	why := universe_export(dir, fmt.tprintf("%s.vxu", dir), &base.Disk{})
	testing.expectf(
		t,
		strings.contains(why, "another process"),
		"an open universe was exported: %q",
		why,
	)
	base.file_unlock(&first.lock)
	testing.expect(t, !refused(dir), "the lock was not released")
}

// The lock is on the universe, not on the server that happens to hold it.
@(test)
test_server_start_takes_the_lock :: proc(t: ^testing.T) {
	dir := scratch_dir("lock_server")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	defer grief_close(g)
	if !ok {return}
	testing.expect(t, refused(dir), "a running server does not hold its universe's lock")
	// A second server on the same directory does not start.
	second := new(Session)
	defer free(second)
	loud := context.logger
	quiet := loud
	quiet.lowest_level = .Fatal
	context.logger = quiet
	started := session_start(second, {}, false, with = grief_config(dir))
	context.logger = loud
	testing.expect(t, !started, "a second server started on an open universe")
	// (it left nothing running, and the first still holds the lock)
	testing.expect(t, refused(dir), "the lock was lost")
}
