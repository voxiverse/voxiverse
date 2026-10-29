// Package limited runs a command under a time limit. The build driver's `test`
// uses it, and so does smoke/ (which tests it): it is its own package so that
// both can.
package limited

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Run_Result :: enum {
	Ok,
	Failed, // exited nonzero, or could not start
	Timed_Out,
}

// run_limited is run with a time limit: a command still going at the limit is killed
// together with everything it started.
run_limited :: proc(cmd: []string, limit: time.Duration) -> Run_Result {
	desc := os.Process_Desc {
		command = cmd,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	child, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("build: could not start '%s': %v", cmd[0], err)
		return .Failed
	}
	state, werr := os.process_wait(child, limit)
	if werr == nil {
		return .Ok if state.exited && state.exit_code == 0 else .Failed
	}
	kill_tree(child.pid)
	_, _ = os.process_wait(child)
	return .Timed_Out
}

// kill_tree kills a process and every descendant (each is frozen before its children
// are listed, so none can start more while the tree is walked).
kill_tree :: proc(pid: int) {
	context.allocator = context.temp_allocator // capture's output
	when ODIN_OS == .Windows {
		_, _ = capture({"taskkill", "/T", "/F", "/PID", fmt.tprint(pid)})
	} else {
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
}

// capture runs a command and returns what it printed (to stdout).
@(private)
capture :: proc(cmd: []string) -> (output: string, ok: bool) {
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil {return "", false}
	return string(stdout), state.exited && state.exit_code == 0
}
