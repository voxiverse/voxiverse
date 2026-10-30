package base

import "core:fmt"
import "core:os"
import "core:prof/spall"
@(require) import "core:strconv" // used only in profiling builds
import "core:strings"
@(require) import "core:sync" // used only in profiling builds

// Profiling into a Spall trace (view it at https://gravitymoth.com/spall/ or
// with the native Spall app). Compiled in only with -define:VX_PROFILE=true
// (`build run --profile`); otherwise every procedure here is empty.
//
//	base.profile_start("voxiverse.spall") // main thread, once
//	defer base.profile_stop()
//	...
//	{
//		base.profile_scope("mesh chunks") // ends with the enclosing scope
//		...
//	}
//
// Other threads call profile_thread_start/stop around their work. GPU timings
// arrive through profile_gpu_event (the gpu package feeds it) on their own
// "GPU" track, on the same clock as CPU events.

PROFILE :: #config(VX_PROFILE, false)

// One trace per process and a buffer per thread: the only mutable globals in
// the codebase, and only in profiling builds.
@(private)
trace: spall.Context
@(private = "file", thread_local)
thread_buffer: spall.Buffer
@(private = "file", thread_local)
thread_backing: []u8
@(private = "file")
gpu_buffer: spall.Buffer
@(private = "file")
gpu_backing: []u8
@(private = "file")
active: bool

@(private = "file")
GPU_TRACK_ID :: 0xFFFF_FF00

profile_start :: proc(path: string) -> bool {
	when PROFILE {
		ok: bool
		// Scale 1: timestamps are spall.tick_now() nanoseconds, the clock
		// GPU timestamps are calibrated against.
		if trace, ok = spall.context_create_with_scale(path, false, 1); !ok {return false}
		active = true
		gpu_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE)
		gpu_buffer = spall.buffer_create(gpu_backing, GPU_TRACK_ID)
		profile_thread_start("main")
		return true
	} else {
		return false
	}
}

profile_stop :: proc() {
	when PROFILE {
		if !active {return}
		profile_thread_stop()
		spall.buffer_destroy(&trace, &gpu_buffer)
		delete(gpu_backing)
		spall.context_destroy(&trace)
		active = false
	}
}

profile_thread_start :: proc(name: string) {
	when PROFILE {
		if !active {return}
		thread_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE)
		thread_buffer = spall.buffer_create(thread_backing, u32(sync.current_thread_id()))
		spall._buffer_name_thread(&trace, &thread_buffer, name)
	}
}

profile_thread_stop :: proc() {
	when PROFILE {
		if !active {return}
		spall.buffer_destroy(&trace, &thread_buffer)
		delete(thread_backing)
		thread_backing = nil
	}
}

// profile_scope times the rest of the enclosing scope.
@(deferred_none = profile_end)
profile_scope :: #force_inline proc(name: string) {
	profile_begin(name)
}

// profile_scope_number is profile_scope with a number in the event's arguments
// ("#1234": the frame, the tick), so a slow one can be named and found again. The
// number is only formatted in a profiling build.
@(deferred_none = profile_end)
profile_scope_number :: #force_inline proc(name: string, number: u64) {
	when PROFILE {
		buf: [24]u8
		buf[0] = '#'
		digits := strconv.write_uint(buf[1:], number, 10)
		profile_begin(name, string(buf[:1 + len(digits)]))
	}
}

// profile_begin opens a scope (profile_end closes it). On a thread that did not
// call profile_thread_start it does nothing: there is no buffer to write to.
profile_begin :: #force_inline proc(name: string, args := "") {
	when PROFILE {
		if !active || thread_backing == nil {return}
		b := &thread_buffer
		if b.head + spall.BEGIN_EVENT_MAX > len(b.data) {spall.buffer_flush(&trace, b)}
		b.head += spall._build_begin(b.data[b.head:], name, args, profile_now())
	}
}

profile_end :: #force_inline proc() {
	when PROFILE {
		if !active || thread_backing == nil {return}
		ts := profile_now()
		b := &thread_buffer
		if b.head + size_of(spall.End_Event) > len(b.data) {spall.buffer_flush(&trace, b)}
		b.head += spall._build_end(b.data[b.head:], ts)
	}
}

// profile_process_name: what a trace says it is: "Voxiverse 0.1.2+5 (abc123) client,
// release build, profiling, arguments: --benchmark edits".
profile_process_name :: proc(program: string) -> string {
	args := strings.join(os.args[1:], " ", context.temp_allocator)
	return fmt.tprintf(
		"Voxiverse %s %s, %s build, profiling, arguments: %s",
		version_text(),
		program,
		build_name(),
		args if args != "" else "(none)",
	)
}

// profile_name_process names the trace's process: what a reader sees first, so it
// says what was profiled (program, version, build, arguments). Main thread.
profile_name_process :: proc(name: string) {
	when PROFILE {
		if !active {return}
		spall._buffer_name_process(&trace, &thread_buffer, name)
	}
}

// profile_gpu_begin / profile_gpu_end record a GPU section on the GPU track
// with explicit timestamps (trace clock, ns). Call them in recording order so
// nested sections nest.
profile_gpu_begin :: proc(name: string, ns: i64, args := "") {
	when PROFILE {
		if !active {return}
		if gpu_buffer.head + spall.BEGIN_EVENT_MAX > len(gpu_buffer.data) {
			spall.buffer_flush(&trace, &gpu_buffer)
		}
		gpu_buffer.head += spall._build_begin(
			gpu_buffer.data[gpu_buffer.head:],
			name,
			args,
			u64(ns),
		)
	}
}

profile_gpu_end :: proc(ns: i64) {
	when PROFILE {
		if !active {return}
		if gpu_buffer.head + size_of(spall.End_Event) > len(gpu_buffer.data) {
			spall.buffer_flush(&trace, &gpu_buffer)
		}
		gpu_buffer.head += spall._build_end(gpu_buffer.data[gpu_buffer.head:], u64(ns))
	}
}

// profile_name_gpu_track names the GPU track; the gpu package calls it once it
// knows whether its timestamps are calibrated to the trace clock, so a trace
// says how far its GPU/CPU alignment can be trusted.
profile_name_gpu_track :: proc(calibrated: bool, device := "") {
	when PROFILE {
		if !active {return}
		name := "GPU (calibrated)" if calibrated else "GPU (approximate)"
		if device != "" {name = fmt.tprintf("%s %s", name, device)}
		spall._buffer_name_thread(&trace, &gpu_buffer, name)
	}
}

profiling_enabled :: proc() -> bool {
	return PROFILE && active
}
