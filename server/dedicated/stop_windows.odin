package dedicated

import "core:sync"
import win "core:sys/windows"

// catch_stop turns Ctrl+C, Ctrl+Break and closing the console window into a
// clean stop (the handler runs on its own thread; the main loop notices).
catch_stop :: proc() {
	win.SetConsoleCtrlHandler(on_console_event, true)
}

@(private = "file")
on_console_event :: proc "system" (event: win.DWORD) -> win.BOOL {
	sync.atomic_store(&stop_requested, true)
	if event == win.CTRL_CLOSE_EVENT {
		// Windows ends the process when this returns: give the main loop
		// time to save first (it has up to 5 seconds).
		win.Sleep(4000)
	}
	return true
}
