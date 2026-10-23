package base

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"

// Windows crash handler: an unhandled exception (access violation, illegal
// instruction, stack overflow, ...) is reported (crash_report), then Windows
// continues as usual (Windows Error Reporting, or the attached debugger).

@(private)
crash_handler_install :: proc() {
	win.SetUnhandledExceptionFilter(crash_filter)
}

@(private = "file")
crash_filter :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	context = runtime.default_context()
	buf: [128]u8
	code: u32
	address: rawptr
	if info != nil && info.ExceptionRecord != nil {
		code, address =
			u32(info.ExceptionRecord.ExceptionCode), info.ExceptionRecord.ExceptionAddress
	}
	crash_report(fmt.bprintf(buf[:], "exception=0x%08x address=%p", code, address))
	return 0 // EXCEPTION_CONTINUE_SEARCH
}
