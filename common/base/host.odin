package base

import "core:fmt"

// Host: everything the core knows about the machine it runs on. It is plain data and
// procedure values, filled in by the platform layer (`common/platform`, `client/platform`)
// once at start and handed down by the entry packages (`client/main`, `server/dedicated`);
// the core imports only base and never a platform package. Tests fill it with fakes.
//
// The services land one step at a time (docs/design.md, "The OS quarantine"): so far the boot
// information, the output (stdout and stderr), the entropy and the clocks.
Host :: struct {
	boot:    Boot_Info,
	output:  Output_Service,
	// Key material from the operating system's secure source: account keys, nonces,
	// salts, secrets. Never for gameplay randomness (see Rng, and cosmetic_rng for what
	// need not repeat).
	entropy: proc(out: []u8),
	clock:   Clock_Service,
}

// Boot_Info: what the process was started with, read once at boot.
Boot_Info :: struct {
	args:      []string, // argv[1:] (the program's own name is not in it)
	env:       Env, // every variable the game reads, read once at boot
	pid:       int, // the process id (the universe lock names its holder)
	cpu_count: int, // logical processors, to size the worker pools
	dirs:      Dirs, // the folders the game reads and writes
	machine:   Machine_Facts, // the CPU and OS, for benchmark results and crash bundles
}

// Machine_Facts: what the machine is, "" and 0 where the OS does not say.
Machine_Facts :: struct {
	cpu:     string, // the CPU's name
	cores:   int, // physical cores
	threads: int, // logical processors
	os:      string, // the OS and its version
}

// Dirs: well-known folders, "" when the platform does not know one.
Dirs :: struct {
	exe:    string, // the executable's folder
	data:   string, // the user's data folder
	config: string, // the user's config folder
	home:   string, // the user's home folder
}

// Env: the environment variables the game reads. A Maybe(string) is nil when the variable
// is unset (set but empty is a string "", which some of them treat differently).
Env :: struct {
	validation:        Maybe(string), // VX_VALIDATION
	packs:             Maybe(string), // VX_PACKS
	settings:          Maybe(string), // VX_SETTINGS
	saves:             Maybe(string), // VX_SAVES
	state_dir:         Maybe(string), // VX_STATE_DIR
	log_debug:         bool, // VX_LOG=debug
	break_on_error:    bool, // VX_BREAK=1
	pad_ignore:        string, // SDL_GAMECONTROLLER_IGNORE_DEVICES
	pad_ignore_except: string, // SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT
}

@(private = "file")
boot: Boot_Info

// boot_install makes info the process's boot information (platform.boot does it, before
// any thread starts); the code that needs it has no Host to read it from. Tests install a
// Boot_Info of their own to stand in for the environment.
boot_install :: proc(info: Boot_Info) {
	boot = info
}

// boot_info is the boot information installed at start (zero until one is installed).
boot_info :: proc() -> Boot_Info {
	return boot
}

// cpu_count is the number of logical processors, at least 1.
cpu_count :: proc() -> int {
	return max(boot.cpu_count, 1)
}

Output_Stream :: enum {
	Out, // stdout
	Err, // stderr
}

// Output_Service: the process's stdout and stderr. The platform fills it; `output_install`
// makes it the process's one output, which the log writer and the crash and assertion
// paths (they have no Host to read it from) write through. Until one is installed, output
// is dropped. The procedures are contextless: the crash handlers call them.
Output_Service :: struct {
	write:    proc "contextless" (stream: Output_Stream, text: string),
	// Whether the stream is a terminal that shows colour.
	is_color: proc "contextless" (stream: Output_Stream) -> bool,
}

@(private = "file")
output: Output_Service

// output_install makes service the process's output (platform.boot does it).
output_install :: proc(service: Output_Service) {
	output = service
}

// out_write writes text to the stream, as one write.
out_write :: proc "contextless" (stream: Output_Stream, text: string) {
	if output.write != nil {output.write(stream, text)}
}

// out_is_color reports whether the stream is a terminal that shows colour.
out_is_color :: proc "contextless" (stream: Output_Stream) -> bool {
	return output.is_color != nil && output.is_color(stream)
}

// out_printfln writes one formatted line to the stream, as one write. It formats on the
// stack (a line over 1 KiB is cut), so the crash paths can use it.
out_printfln :: proc(stream: Output_Stream, format: string, args: ..any) {
	buf: [1024]u8
	text := fmt.bprintf(buf[:len(buf) - 1], format, ..args)
	buf[len(text)] = '\n'
	out_write(stream, string(buf[:len(text) + 1]))
}

@(private = "file")
entropy: proc(out: []u8)

// entropy_install makes source the process's entropy (platform.boot does it); the code that
// needs key material has no Host to read it from.
entropy_install :: proc(source: proc(out: []u8)) {
	entropy = source
}

// entropy_fill fills out with secure random bytes. It stops the process when none is
// installed: a key from a fixed stream would be a quiet hole. Test builds fall back to a
// fixed stream, so a package's tests need not boot a platform.
entropy_fill :: proc(out: []u8) {
	if entropy != nil {
		entropy(out)
		return
	}
	when ODIN_TEST {
		@(static) fixed := Rng {
			s = {1, 2, 3, 4},
		}
		for &b in out {b = u8(rng_u64(&fixed))}
	} else {
		panic("entropy_fill: no entropy installed (platform.boot was not called)")
	}
}

@(private = "file")
@(thread_local)
cosmetic: Rng
@(private = "file")
@(thread_local)
cosmetic_ready: bool

// cosmetic_rng is the calling thread's stream for randomness that never reaches state and
// need not repeat: particles, sound pitch, a pipe's jitter. It is seeded from the entropy
// once per thread. Anything the simulation, a save or a replay can see uses an Rng made
// from a seed (docs/determinism.md).
cosmetic_rng :: proc() -> ^Rng {
	if !cosmetic_ready {
		seed: u64
		entropy_fill((cast([^]u8)&seed)[:size_of(seed)])
		cosmetic = rng_make(seed)
		cosmetic_ready = true
	}
	return &cosmetic
}

// Clock_Service: the clocks that read the OS. The platform fills it; `clock_install` makes
// it the process's one set (platform.boot does it).
Clock_Service :: struct {
	// The CPU time this thread has used, in microseconds: what a budget test reads, so that
	// other threads and processes taking the core during the measurement do not count.
	thread_cpu_us: proc() -> i64,
	// A cheap counter for the ratio of two spans (its unit differs by platform).
	ticks:         proc() -> u64,
	// The trace's clock in nanoseconds (the clock spall reads); nil where spall's own will do.
	profile_now:   proc "contextless" () -> u64,
}

@(private)
clock: Clock_Service

// clock_install makes service the process's clocks (platform.boot does it, before any
// thread starts).
clock_install :: proc(service: Clock_Service) {
	clock = service
}

// thread_cpu_us is the CPU time this thread has used, in microseconds. It stops the
// process when no clock is installed: a budget measured against 0 would pass quietly.
thread_cpu_us :: proc() -> i64 {
	if clock.thread_cpu_us ==
	   nil {panic("thread_cpu_us: no clock installed (platform.boot was not called)")}
	return clock.thread_cpu_us()
}

// ticks is a cheap counter for the ratio of two spans (the unit differs by platform).
ticks :: proc() -> u64 {
	if clock.ticks == nil {panic("ticks: no clock installed (platform.boot was not called)")}
	return clock.ticks()
}
