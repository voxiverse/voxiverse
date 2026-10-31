package base

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// DEV: the development aids are in: the tracking allocator, Vulkan
// validation by default, shader hot reload, developer commands. On in every
// -debug build unless the build turns it off (`build build --release
// --symbols`: release behaviour with line tables, for profilers); the build
// driver sets it. ODIN_DEBUG itself only says there are debug symbols.
DEV :: #config(VX_DEV, ODIN_DEBUG)

// Debug support for every program, set up at the top of main:
//
//	main :: proc() {
//		dbg: base.Debug
//		context = base.debug_begin(&dbg, "voxiverse.log", "main")
//		ok := run()
//		ok = base.debug_end(&dbg) && ok // reports leaks
//		os.exit(0 if ok else 1)
//	}
//
// What it gives you:
// - Logging (log.odin) to the console and to a log file (overwritten each
//   run). The console shows Info and up (VX_LOG=debug for everything); the
//   file always has everything. The calling thread's lines are tagged tag.
// - Failed asserts and panics print a stack trace before stopping.
// - In debug builds, every allocation through context.allocator is tracked;
//   debug_end lists leaks and bad frees with their source locations and
//   returns false if there were any.
// - Crashes (segfaults, access violations, illegal instructions) log what
//   happened and a stack trace before the process dies (crash_*.odin).
// - VX_BREAK=1 stops in an attached debugger instead of just logging (see
//   debug_break), e.g. on Vulkan validation errors.

Debug :: struct {
	tracking:   mem.Tracking_Allocator,
	tracked:    bool,
	backing:    mem.Allocator, // untracked: the debug machinery's own memory
	log_file:   ^os.File,
	log_path:   string,
	sink:       Log_Sink,
	logger:     log.Logger,
	break_mode: bool,
	attached:   Crash_Attachment,
}

// A file the crash report names (M32e: the audio ring's last window): the
// path in a fixed buffer, since the handler may not allocate, and when it was
// written.
Crash_Attachment :: struct {
	path:     [256]u8,
	path_len: int,
	written:  time.Tick,
}

// The active Debug, for the assertion handler (which gets no user data).
@(private = "file")
active: ^Debug

debug_begin :: proc(d: ^Debug, log_file_name: string, tag: string) -> runtime.Context {
	ctx := context
	d^ = {}
	d.backing = ctx.allocator
	d.break_mode = os.get_env("VX_BREAK", context.temp_allocator) == "1"
	active = d

	console_level: log.Level =
		.Debug if os.get_env("VX_LOG", context.temp_allocator) == "debug" else .Info
	if path, ok := log_file_path(log_file_name); ok {
		log_rotate(path)
		if f, err := os.open(path, {.Write, .Create, .Trunc}); err == nil {
			d.log_file = f
			d.log_path = strings.clone(path, d.backing)
		} else {
			fmt.eprintfln("debug: cannot write log file %s: %v", path, err)
		}
	}
	d.logger = log_sink_init(&d.sink, d.log_file, console_level, tag)
	ctx.logger = d.logger
	ctx.assertion_failure_proc = assertion_failure
	when ODIN_SANITIZER_FLAGS == {} {crash_handler_install()} 	// sanitizers have their own

	when DEV {
		mem.tracking_allocator_init(&d.tracking, d.backing, d.backing)
		ctx.allocator = mem.tracking_allocator(&d.tracking)
		d.tracked = true
	}
	return ctx
}

// debug_end reports leaked and wrongly freed memory (debug builds) and
// shuts logging down. Returns false if memory problems were found.
debug_end :: proc(d: ^Debug) -> bool {
	context.logger = d.logger
	ok := true
	if d.tracked {
		for _, entry in d.tracking.allocation_map {
			log.errorf("memory leak bytes=%d at=%v", entry.size, entry.location)
			ok = false
		}
		for entry in d.tracking.bad_free_array {
			log.errorf("memory bad free pointer=%p at=%v", entry.memory, entry.location)
			ok = false
		}
		if ok {
			log.debugf(
				"memory no leaks allocations=%d peak_bytes=%v",
				d.tracking.total_allocation_count,
				d.tracking.peak_memory_allocated,
			)
		}
		mem.tracking_allocator_destroy(&d.tracking)
	}

	context.allocator = d.backing
	if d.log_file != nil {os.close(d.log_file)}
	delete(d.log_path, d.backing)
	active = nil
	return ok
}

// log_stack_trace logs the calling code's stack, innermost first, keeping
// only frames in our own Odin code (library internals are noise). skip drops
// that many frames above the caller. Returns false if no frame of ours was on
// the stack, e.g. when a library calls back from its own thread.
log_stack_trace :: proc(level: log.Level = .Error, skip := 0) -> (found: bool) {
	bt := trace.capture(skip + 1)
	locations, err := trace.resolve(bt, context.temp_allocator, context.temp_allocator)
	if err != nil {
		log.logf(level, "  (stack trace unavailable: %s)", trace.resolve_err_string(err))
		return false
	}
	for loc in locations {
		// Our code only: not library internals, not Odin's runtime (assert, entry).
		if !strings.has_suffix(loc.file_path, ".odin") ||
		   strings.has_prefix(loc.procedure, "runtime::") {
			continue
		}
		// The frame's own location goes where the logger shows locations.
		log.logf(
			level,
			"  at %s",
			loc.procedure,
			location = {file_path = loc.file_path, line = i32(loc.line)},
		)
		found = true
	}
	return
}

// debug_attach names a file that the crash report will point at, with its
// age (call again after each write). A path that does not fit is not named.
debug_attach :: proc(path: string) {
	if active == nil || len(path) > len(active.attached.path) {return}
	a := &active.attached
	a.path_len = copy(a.path[:], path)
	a.written = time.tick_now()
}

// crash_report logs a crash and the stack (from a signal handler or
// exception filter: best effort, the process is going down anyway).
@(private)
crash_report :: proc(what: string) {
	if active == nil {
		fmt.eprintfln("crash: %s", what)
		return
	}
	context = runtime.default_context()
	context.logger = active.logger
	sync.atomic_store(&active.sink.crashing, true)
	log.fatalf("crash %s", what)
	if !log_stack_trace(.Fatal, 2) {log.fatal("  (no frames of ours on this thread's stack)")}
	if a := &active.attached; a.path_len > 0 {
		log.fatalf(
			"crash attached file=%s age_s=%.0f",
			string(a.path[:a.path_len]),
			time.duration_seconds(time.tick_since(a.written)),
		)
	}
	if active.log_file != nil {
		log.fatalf("crash full log: %s", active.log_path)
		os.flush(active.log_file)
	}
}

// debug_break stops in an attached debugger when VX_BREAK=1; otherwise it
// does nothing, so it is safe to leave at "this should never happen" spots.
debug_break :: proc() {
	if active != nil && active.break_mode {
		runtime.debug_trap()
	}
}

@(private = "file")
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	// Write straight to stderr too: the logger may be what failed.
	fmt.eprintfln("%s: %s (%v)", prefix, message, loc)
	if active != nil {
		context.logger = active.logger
		log.fatalf("%s: %s (%v)", prefix, message, loc)
		log_stack_trace(.Fatal, 1)
	}
	runtime.trap()
}

// LOGS_KEPT: how many earlier runs' logs are kept beside the current one (path.1 is the
// last run's, path.2 the one before, ...). A crash's log, and its stack, survives the
// restart that follows it.
LOGS_KEPT :: 5

// log_rotate moves path to path.1, path.1 to path.2, ..., dropping the oldest. It is
// best effort: a log that cannot be moved is overwritten, as before.
log_rotate :: proc(path: string) {
	for i := LOGS_KEPT; i >= 1; i -= 1 {
		from := path if i == 1 else fmt.tprintf("%s.%d", path, i - 1)
		if !os.exists(from) {continue}
		to := fmt.tprintf("%s.%d", path, i)
		os.remove(to)
		os.rename(from, to)
	}
}

// log_file_path places the log next to the executable (build/ in dev).
@(private = "file")
log_file_path :: proc(name: string) -> (string, bool) {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return "", false}
	return strings.concatenate({dir, "/", name}, context.temp_allocator), true
}
