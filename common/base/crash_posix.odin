#+build linux, darwin, freebsd, openbsd, netbsd
package base

import "base:runtime"
import "core:fmt"
import "core:sys/posix"

// POSIX crash handler: fatal signals are reported (crash_report) on an
// alternate stack, so a stack overflow can be reported too; then the default
// action runs (core dump, or the debugger's view of the crash).

@(private = "file")
FATAL_SIGNALS := [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGFPE, .SIGILL}

// The main thread's alternate stack comes from the heap, as the workers' do. As a global array
// in the image it made the macOS main-segv crash bundle die intermittently while capturing the
// crashing thread's own frames; the workers' heap stacks never did. SIGSTKSZ on macOS is 128 KiB.
@(private = "file")
MAIN_ALT_STACK_BYTES :: 128 * 1024

@(private = "file")
alt_stack: []u8

@(private)
crash_handler_install :: proc() {
	if alt_stack == nil {alt_stack = make([]u8, MAIN_ALT_STACK_BYTES, runtime.heap_allocator())}
	stack := posix.stack_t {
		ss_sp   = raw_data(alt_stack),
		ss_size = len(alt_stack),
	}
	posix.sigaltstack(&stack, nil)
	action := posix.sigaction_t {
		sa_sigaction = crash_signal,
		sa_flags     = {.SIGINFO, .ONSTACK, .RESETHAND}, // RESETHAND: the re-raise takes the default action
	}
	posix.sigemptyset(&action.sa_mask)
	for sig in FATAL_SIGNALS {posix.sigaction(sig, &action, nil)}
}

@(private = "file")
crash_signal :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, _: rawptr) {
	context = runtime.default_context()
	buf: [128]u8
	address := info.si_addr if info != nil else nil
	what := fmt.bprintf(buf[:], "signal=%v address=%p", sig, address)
	// A guard page is hit as SIGSEGV (Linux) or SIGBUS (macOS).
	if (sig == .SIGSEGV || sig == .SIGBUS) && stack_overflow_at(address) {
		what = fmt.bprintf(buf[:], "signal=%v address=%p (stack overflow)", sig, address)
	}
	crash_report(what)
	posix.raise(sig) // handler reset: the default action now
}
