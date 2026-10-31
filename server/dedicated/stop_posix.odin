#+build !windows
package dedicated

import "core:sync"
import "core:sys/posix"

// catch_stop turns Ctrl+C (SIGINT) and SIGTERM into a clean stop.
catch_stop :: proc() {
	posix.signal(.SIGINT, on_signal)
	posix.signal(.SIGTERM, on_signal)
}

@(private = "file")
on_signal :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&stop_requested, true)
}
