#+build linux, darwin, freebsd, openbsd, netbsd
package base

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:sync"
import "core:sys/posix"

// The POSIX half of crash bundles: files by open/write/close, and every thread's stack by a
// signal. The crashing thread sends SIGUSR2 to each registered thread; its handler (on the
// thread's own alternate stack) captures its frames into its slot and flags it.

Thread_Handle :: posix.pthread_t
Bundle_File :: posix.FD

@(private = "file")
ALT_STACK_BYTES :: 64 * 1024

@(private)
bundle_pid :: proc() -> int {
	return int(posix.getpid())
}

@(private)
bundle_mkdir :: proc(path: string) -> bool {
	buf: [800]u8
	return posix.mkdir(cpath(buf[:], path), {.IRUSR, .IWUSR, .IXUSR}) == .OK
}

@(private = "file")
cpath :: proc(buf: []u8, path: string) -> cstring {
	n := copy(buf[:len(buf) - 1], path)
	buf[n] = 0
	return cstring(raw_data(buf))
}

@(private)
bundle_open :: proc(dir, file: string) -> (Bundle_File, bool) {
	buf: [800]u8
	path := fmt.bprintf(buf[:len(buf) - 1], "%s/%s", dir, file)
	buf[len(path)] = 0
	fd := posix.open(cstring(raw_data(buf[:])), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	return fd, fd >= 0
}

@(private)
bundle_write :: proc(f: Bundle_File, data: []u8) {
	data := data
	for len(data) > 0 {
		n := posix.write(f, raw_data(data), len(data))
		if n <= 0 {return}
		data = data[n:]
	}
}

@(private)
bundle_close :: proc(f: Bundle_File) {
	posix.close(f)
}

@(private)
bundle_platform_init :: proc() {
	// The first backtrace loads the unwinder (it allocates): do that now, not in a handler.
	warm := trace.capture(0)
	_ = warm
	action := posix.sigaction_t {
		sa_sigaction = thread_stack_signal,
		sa_flags     = {.SIGINFO, .ONSTACK, .RESTART},
	}
	posix.sigemptyset(&action.sa_mask)
	posix.sigaction(.SIGUSR2, &action, nil)
}

@(private)
bundle_platform_destroy :: proc() {
	posix.signal(.SIGUSR2, auto_cast posix.SIG_DFL)
}

@(private)
thread_platform_register :: proc(s: ^Thread_Slot) {
	s.handle = posix.pthread_self()
	s.alt = nil
	old: posix.stack_t
	posix.sigaltstack(nil, &old)
	if old.ss_sp != nil && .DISABLE not_in old.ss_flags {return} 	// the main thread's, already set
	s.alt = make([]u8, ALT_STACK_BYTES, runtime.heap_allocator())
	st := posix.stack_t {
		ss_sp   = raw_data(s.alt),
		ss_size = len(s.alt),
	}
	posix.sigaltstack(&st, nil)
}

@(private)
thread_platform_unregister :: proc(s: ^Thread_Slot) {
	if s.alt != nil {
		st := posix.stack_t {
			ss_flags = {.DISABLE},
		}
		posix.sigaltstack(&st, nil)
		delete(s.alt, runtime.heap_allocator())
		s.alt = nil
	}
}

@(private = "file")
thread_stack_signal :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, _: rawptr) {
	if my_slot == 0 {return}
	context = runtime.default_context()
	s := &slots[my_slot - 1]
	s.frame_n = trace.capture_fill(frames_of(s), 0)
	sync.atomic_store(&s.done, 1)
}

@(private)
frames_of :: proc "contextless" (s: ^Thread_Slot) -> trace.Capture {
	return ([^]trace.Capture_Entry)(&s.frames[0])[:BUNDLE_FRAMES]
}

// threads_capture_others asks every other registered thread for its stack and waits for the
// answers, at most BUNDLE_WAIT_MS in all.
@(private)
threads_capture_others :: proc() {
	asked := 0
	for i in 0 ..< BUNDLE_THREADS {
		s := &slots[i]
		if sync.atomic_load(&s.used) != 1 || my_slot == i + 1 {continue}
		sync.atomic_store(&s.done, 0)
		if posix.pthread_kill(s.handle, .SIGUSR2) == .NONE {asked += 1}
	}
	if asked == 0 {return}
	for _ in 0 ..< BUNDLE_WAIT_MS {
		all := true
		for i in 0 ..< BUNDLE_THREADS {
			s := &slots[i]
			if sync.atomic_load(&s.used) == 1 &&
			   my_slot != i + 1 &&
			   sync.atomic_load(&s.done) == 0 {
				all = false
				break
			}
		}
		if all {return}
		ts := posix.timespec {
			tv_nsec = 1_000_000,
		}
		posix.nanosleep(&ts, nil)
	}
}
