package base

import "core:fmt"
import "core:sync"
import win "core:sys/windows"

// The Windows half of crash bundles: files by CreateFileW/WriteFile, and every thread's stack:
// the crashing thread asks the stack service (common/platform) to suspend each registered
// thread, walk its stack and resume it.

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
	stack_guarantee()
}

// stack_guarantee keeps stack for the crash filter on the calling thread: after a stack overflow
// Windows runs the filter on what is left of the overflowed stack (a guard page), too little to
// write a bundle, so the filter faulted again and the process died without one.
@(private)
stack_guarantee :: proc() {
	if stack.guarantee != nil {stack.guarantee(CRASH_STACK)}
}

@(private = "file")
CRASH_STACK :: 128 * 1024

@(private)
thread_platform_unregister :: proc(s: ^Thread_Slot) {}

@(private)
threads_capture_others :: proc() {
	for i in 0 ..< BUNDLE_THREADS {
		s := &slots[i]
		if sync.atomic_load(&s.used) != 1 || my_slot == i + 1 {continue}
		sync.atomic_store(&s.done, 0)
		if stack.capture_thread == nil {continue}
		n := stack.capture_thread(s.handle, s.frames[:])
		if n == 0 {continue}
		s.frame_n = n
		sync.atomic_store(&s.done, 1)
	}
}
