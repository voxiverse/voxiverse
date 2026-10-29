#+build !windows
package limited

import "core:fmt"
import "core:strconv"
import "core:strings"

// kill_tree kills a process and every descendant (each is frozen before its children
// are listed, so none can start more while the tree is walked).
kill_tree :: proc(pid: int) {
	context.allocator = context.temp_allocator // capture's output
	pids := make([dynamic]int, context.temp_allocator)
	append(&pids, pid)
	for i := 0; i < len(pids); i += 1 {
		_, _ = capture({"kill", "-STOP", fmt.tprint(pids[i])})
		out, _ := capture({"pgrep", "-P", fmt.tprint(pids[i])})
		for line in strings.split_lines(out, context.temp_allocator) {
			if child, ok := strconv.parse_int(strings.trim_space(line)); ok {
				append(&pids, child)
			}
		}
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "kill", "-KILL")
	for p in pids {append(&cmd, fmt.tprint(p))}
	_, _ = capture(cmd[:])
}
