package base

import "core:fmt"
import "core:sync"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

// The Windows half of crash bundles: files by CreateFileW/WriteFile, and every thread's stack:
// the crashing thread suspends each registered thread, reads its context and walks its stack
// with RtlLookupFunctionEntry and RtlVirtualUnwind (x64). Nothing is resumed: the process ends.

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
threads_capture_others :: proc() {
	for i in 0 ..< BUNDLE_THREADS {
		s := &slots[i]
		if sync.atomic_load(&s.used) != 1 || my_slot == i + 1 {continue}
		sync.atomic_store(&s.done, 0)
		h := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT, false, s.handle)
		if h == nil {continue}
		if win.SuspendThread(h) == max(win.DWORD) {continue}
		ctx: win.CONTEXT
		ctx.ContextFlags = CONTEXT_FULL
		if !win.GetThreadContext(h, &ctx) {continue}
		s.frame_n = unwind(&ctx, s.frames[:])
		sync.atomic_store(&s.done, 1)
	}
}

@(private = "file")
CONTEXT_FULL :: 0x10000B // CONTEXT_AMD64 | CONTEXT_CONTROL | CONTEXT_INTEGER

@(default_calling_convention = "system")
foreign kernel32 {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, History: rawptr) -> rawptr ---
	RtlVirtualUnwind :: proc(HandlerType: win.DWORD, ImageBase: u64, ControlPc: u64, FunctionEntry: rawptr, Context: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

// unwind walks the stack from ctx into frames; a frame without unwind data is a leaf (the
// return address is at the stack pointer).
@(private = "file")
unwind :: proc(ctx: ^win.CONTEXT, frames: []rawptr) -> int {
	n := 0
	for n < len(frames) && ctx.Rip != 0 {
		frames[n] = rawptr(uintptr(ctx.Rip))
		n += 1
		base: u64
		entry := RtlLookupFunctionEntry(ctx.Rip, &base, nil)
		if entry == nil {
			if ctx.Rsp == 0 {break}
			ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
			ctx.Rsp += 8
			continue
		}
		handler: rawptr
		frame: u64
		RtlVirtualUnwind(0, base, ctx.Rip, entry, ctx, &handler, &frame, nil)
	}
	return n
}
