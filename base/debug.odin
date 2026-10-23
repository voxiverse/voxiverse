package base

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

// Debug support for every program, set up at the top of main:
//
//	main :: proc() {
//		dbg: base.Debug
//		context = base.debug_begin(&dbg, "voxiverse.log")
//		ok := run()
//		ok = base.debug_end(&dbg) && ok // reports leaks
//		os.exit(0 if ok else 1)
//	}
//
// What it gives you:
// - Logging to the console and to a log file (overwritten each run). The
//   console shows Info and up (VX_LOG=debug for everything); the file always
//   has everything.
// - Failed asserts and panics print a stack trace before stopping.
// - In debug builds, every allocation through context.allocator is tracked;
//   debug_end lists leaks and bad frees with their source locations and
//   returns false if there were any.
// - VX_BREAK=1 stops in an attached debugger instead of just logging (see
//   debug_break), e.g. on Vulkan validation errors.

Debug :: struct {
	tracking:   mem.Tracking_Allocator,
	tracked:    bool,
	backing:    mem.Allocator, // untracked: the debug machinery's own memory
	log_file:   ^os.File,
	console:    log.Logger,
	file:       log.Logger,
	logger:     log.Logger,
	break_mode: bool,
}

// The active Debug, for the assertion handler (which gets no user data).
@(private = "file")
active: ^Debug

debug_begin :: proc(d: ^Debug, log_file_name: string) -> runtime.Context {
	ctx := context
	d^ = {}
	d.backing = ctx.allocator
	d.break_mode = os.get_env("VX_BREAK", context.temp_allocator) == "1"
	active = d

	console_level: log.Level =
		.Debug if os.get_env("VX_LOG", context.temp_allocator) == "debug" else .Info
	d.console = log.create_console_logger(console_level, allocator = d.backing)
	d.logger = d.console
	if path, ok := log_file_path(log_file_name); ok {
		if f, err := os.open(path, {.Write, .Create, .Trunc}); err == nil {
			d.log_file = f
			d.file = log.create_file_logger(f, .Debug, allocator = d.backing)
			d.logger = log.create_multi_logger(d.console, d.file, allocator = d.backing)
		} else {
			fmt.eprintfln("debug: cannot write log file %s: %v", path, err)
		}
	}
	ctx.logger = d.logger
	ctx.assertion_failure_proc = assertion_failure

	when ODIN_DEBUG {
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
			log.errorf("leak: %d bytes allocated at %v", entry.size, entry.location)
			ok = false
		}
		for entry in d.tracking.bad_free_array {
			log.errorf("bad free of %p at %v", entry.memory, entry.location)
			ok = false
		}
		if ok {
			log.debugf(
				"memory: no leaks (%d allocations, peak %v)",
				d.tracking.total_allocation_count,
				d.tracking.peak_memory_allocated,
			)
		}
		mem.tracking_allocator_destroy(&d.tracking)
	}

	context.allocator = d.backing
	if d.log_file != nil {
		log.destroy_multi_logger(d.logger)
		log.destroy_file_logger(d.file) // also closes the file
	}
	log.destroy_console_logger(d.console)
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
		log.logf(level, "  at %s (%s:%d)", loc.procedure, loc.file_path, loc.line)
		found = true
	}
	return
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

// log_file_path places the log next to the executable (build/ in dev).
@(private = "file")
log_file_path :: proc(name: string) -> (string, bool) {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return "", false}
	return strings.concatenate({dir, "/", name}, context.temp_allocator), true
}
