#+build windows
package limited

import "core:sys/windows"

// install_stop_signals makes Ctrl-C and Ctrl-Break arrive as run_parallel's stop
// flag instead of killing the driver (see signal_posix.odin). A close or a shutdown
// is not handled: Windows gives a few seconds for it, and a run's jobs would outlast
// them.
install_stop_signals :: proc() {
	windows.SetConsoleCtrlHandler(handle_stop, windows.TRUE)
}

restore_stop_signals :: proc() {
	windows.SetConsoleCtrlHandler(handle_stop, windows.FALSE)
}

@(private = "file")
handle_stop :: proc "system" (ctrl: windows.DWORD) -> windows.BOOL {
	switch ctrl {
	case windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT:
		request_stop()
		return windows.TRUE
	}
	return windows.FALSE
}
