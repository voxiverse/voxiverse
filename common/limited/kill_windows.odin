#+build windows
package limited

import "core:fmt"

// kill_tree kills a process and every descendant.
kill_tree :: proc(pid: int) {
	context.allocator = context.temp_allocator // capture's output
	_, _ = capture({"taskkill", "/T", "/F", "/PID", fmt.tprint(pid)})
}
