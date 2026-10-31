package base

import "core:fmt"
import win "core:sys/windows"

// The Windows half of crash bundles: files by CreateFileW/WriteFile. Other threads' stacks are
// not collected yet (Q3b: SuspendThread, GetThreadContext, RtlVirtualUnwind): threads.txt holds
// the crashing thread's stack and lists the others as "did not answer".

Thread_Handle :: win.DWORD
Bundle_File :: win.HANDLE

@(private)
bundle_pid :: proc() -> int {
	return int(win.GetCurrentProcessId())
}

@(private)
bundle_mkdir :: proc(path: string) -> bool {
	return bool(win.CreateDirectoryW(win.utf8_to_wstring(path), nil))
}

@(private)
bundle_open :: proc(dir, file: string) -> (Bundle_File, bool) {
	pbuf: [800]u8
	path := fmt.bprintf(pbuf[:], "%s/%s", dir, file)
	h := win.CreateFileW(
		win.utf8_to_wstring(path),
		win.GENERIC_WRITE,
		0,
		nil,
		win.CREATE_ALWAYS,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	return h, h != win.INVALID_HANDLE_VALUE
}

@(private)
bundle_write :: proc(f: Bundle_File, data: []u8) {
	data := data
	for len(data) > 0 {
		n: win.DWORD
		if !win.WriteFile(f, raw_data(data), win.DWORD(len(data)), &n, nil) || n == 0 {return}
		data = data[n:]
	}
}

@(private)
bundle_close :: proc(f: Bundle_File) {
	win.CloseHandle(f)
}

// bundle_watchdog: nothing on Windows yet (no known hang; the exception filter ends the process).
@(private)
bundle_watchdog :: proc(arm: bool) {}

@(private)
bundle_platform_init :: proc() {}

@(private)
bundle_platform_destroy :: proc() {}

@(private)
thread_platform_register :: proc(s: ^Thread_Slot) {
	s.handle = win.GetCurrentThreadId()
}

@(private)
thread_platform_unregister :: proc(s: ^Thread_Slot) {}

@(private)
threads_capture_others :: proc() {}
