#+build linux
package server

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// A lock held by another process, which the OS drops with it.
@(test)
test_lock_held_by_a_child_process :: proc(t: ^testing.T) {
	dir := scratch_dir("lock_child")
	defer delete(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	script := fmt.tprintf("exec 9>%s/lock; flock -n 9 && exec sleep 20", dir)
	child, err := os.process_start({command = {"sh", "-c", script}})
	if !testing.expectf(t, err == nil, "cannot start a child process: %v", err) {return}
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
	}
	// Wait for it to take the lock (a second open is refused).
	held := false
	for _ in 0 ..< 100 {
		if refused(dir) {held = true; break}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, held, "an open of a universe another process holds was allowed")
	_ = os.process_kill(child)
	_, _ = os.process_wait(child)
	testing.expect(t, !refused(dir), "a crashed process left its lock behind")
}
