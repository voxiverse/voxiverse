#+build !windows
package limited

import "core:c/libc"

@(private = "file")
previous_int, previous_term: proc "c" (_: i32)

// install_stop_signals makes Ctrl-C and a plain TERM arrive as run_parallel's stop
// flag instead of killing the driver: the jobs it started are stopped with their
// children, and each is reported interrupted rather than failed. The driver holds
// them only around run_parallel (restore_stop_signals puts back what was there), so
// a Ctrl-C anywhere else still ends the run at once; smoke sets the flag itself,
// because the test runner installs handlers of its own in the same process.
install_stop_signals :: proc() {
	previous_int = libc.signal(libc.SIGINT, handle_stop)
	previous_term = libc.signal(libc.SIGTERM, handle_stop)
}

restore_stop_signals :: proc() {
	libc.signal(libc.SIGINT, previous_int)
	libc.signal(libc.SIGTERM, previous_term)
}

@(private = "file")
handle_stop :: proc "c" (_: i32) {
	request_stop()
}
