package platform

import "core:log"
import "core:os"
import "core:thread"

// open_folder shows a directory in the system's file manager (Explorer,
// Finder, or whatever xdg-open picks), without waiting for it; false if it
// could not be started.
open_folder :: proc(path: string) -> bool {
	when ODIN_OS == .Windows {
		command := []string{"explorer", path}
	} else when ODIN_OS == .Darwin {
		command := []string{"open", path}
	} else {
		command := []string{"xdg-open", path}
	}
	process, err := os.process_start({command = command})
	if err != nil {
		log.errorf("platform cannot open folder path=%s error=%v", path, err)
		return false
	}
	// Reaped when it exits, on a thread of its own (the launcher returns soon).
	thread.run_with_poly_data(
		process,
		proc(p: os.Process) {
			_, _ = os.process_wait(p) // (also frees the process's handle)
		},
	)
	return true
}
