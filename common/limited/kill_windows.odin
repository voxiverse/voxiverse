#+build windows
package limited

import "core:fmt"

// kill_tree kills a process and every descendant (taskkill without a console window of
// its own: the game stops its updater's download with it).
kill_tree :: proc(pid: int) {
	_, _, _, _ = exec(
		{command = {"taskkill", "/T", "/F", "/PID", fmt.tprint(pid)}},
		context.temp_allocator,
		hidden = true,
	)
}
