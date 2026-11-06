#+build windows
package platform_common

import win "core:sys/windows"

import "common:base"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	SetThreadStackGuarantee :: proc(StackSizeInBytes: ^win.ULONG) -> win.BOOL ---
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, History: rawptr) -> rawptr ---
	RtlVirtualUnwind :: proc(HandlerType: win.DWORD, ImageBase: u64, ControlPc: u64, FunctionEntry: rawptr, Context: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

@(private = "file")
CONTEXT_FULL :: 0x10000B // CONTEXT_AMD64 | CONTEXT_CONTROL | CONTEXT_INTEGER

// stack_service: the Windows stack calls the crash bundle uses.
@(private)
stack_service :: proc() -> base.Stack_Service {
	return {guarantee = stack_guarantee, capture_thread = capture_thread}
}

// stack_guarantee keeps stack for the crash filter on the calling thread: after a stack overflow
// Windows runs the filter on what is left of the overflowed stack (a guard page), too little to
// write a bundle, so the filter faulted again and the process died without one.
@(private = "file")
stack_guarantee :: proc(bytes: int) {
	size := win.ULONG(bytes)
	SetThreadStackGuarantee(&size)
}

// capture_thread suspends the thread, reads its context and walks its stack with
// RtlLookupFunctionEntry and RtlVirtualUnwind (x64), then resumes it: a bundle written
// without a crash (a test, a hang report) leaves the process running, and a thread left
// suspended hangs whoever joins it.
@(private = "file")
capture_thread :: proc(id: u32, frames: []rawptr) -> int {
	h := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT, false, win.DWORD(id))
	if h == nil {return 0}
	defer win.CloseHandle(h)
	if win.SuspendThread(h) == max(win.DWORD) {return 0}
	defer win.ResumeThread(h)
	ctx: win.CONTEXT
	ctx.ContextFlags = CONTEXT_FULL
	if !win.GetThreadContext(h, &ctx) {return 0}
	return unwind(&ctx, frames)
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
