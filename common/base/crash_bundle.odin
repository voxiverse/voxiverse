package base

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// Crash bundles (docs/plan.md, Q3): a crash leaves one folder with what a fix needs.
//
//	<crashes dir>/<UTC yyyy-mm-dd_hh-mm-ss>-<pid>/
//	    crash.txt    what happened, which thread, the build, OS, CPU, GPU, uptime, the state
//	    threads.txt  every registered thread's stack (ours frames only), the crashing one first
//	    log.txt      the last 256 KiB of the log
//	    actions.txt  the last 256 actions (menus, controls, joins), oldest first
//
// Nothing here is uploaded. Never in a bundle: keys, chat, typed text, names, server addresses,
// the home directory (written "~"). Everything the writer needs is allocated by
// crash_bundle_init; the crash path formats into those buffers and writes with raw OS calls.
// (The one exception to "allocates nothing" is the C library's own: backtrace_symbols and the
// symbolizer process run by core:debug/trace; Odin-side allocations go to the arena.)

BUNDLE_LOG_BYTES :: 256 * 1024
BUNDLE_ACTIONS :: 256
BUNDLE_ACTION_BYTES :: 96
BUNDLE_KEEP :: 10
BUNDLE_THREADS :: 64
BUNDLE_FRAMES :: 48
BUNDLE_TEXT :: 64 * 1024
BUNDLE_ARENA :: 4 * 1024 * 1024
BUNDLE_WAIT_MS :: 500
BUNDLE_WATCHDOG_S :: 20 // the writer's whole budget: after it the process is ended as it was

Thread_Slot :: struct {
	used:      u32, // atomic: 1 while the thread is registered
	name:      [32]u8,
	name_len:  int,
	handle:    Thread_Handle, // platform: how to reach the thread from the crashing one
	frames:    [BUNDLE_FRAMES]rawptr,
	frame_n:   int,
	done:      u32, // atomic: the thread has captured its frames
	alt:       []u8, // its alternate stack, if we made it (POSIX)
	stack_top: uintptr, // about where its stack starts (an address near the registering call)
}

@(private)
slots: [BUNDLE_THREADS]Thread_Slot
@(private, thread_local)
my_slot: int // thread-local index + 1 (0: not registered)

Crash_Bundle :: struct {
	root:        [512]u8, // the crashes directory
	root_len:    int,
	home:        [256]u8, // the user's home directory, replaced by "~" in the log
	home_len:    int,
	header:      [2048]u8, // build, OS and CPU lines, made at init
	header_len:  int,
	gpu:         [256]u8,
	gpu_len:     int,
	state:       [128]u8,
	state_len:   int,
	start:       time.Tick,
	log:         []u8, // the ring
	log_head:    int, // atomic: bytes ever written
	actions:     []u8, // BUNDLE_ACTIONS records of BUNDLE_ACTION_BYTES: [len, text...]
	action_head: int, // atomic: records ever written
	text:        [3][]u8, // crash.txt, threads.txt, actions.txt
	arena_mem:   []u8,
	arena:       mem.Arena,
	written:     u32, // atomic: a bundle was written (once per process)
	last_dir:    [768]u8, // where it went
	last_len:    int,
	allocator:   runtime.Allocator,
}

@(private)
bundle: ^Crash_Bundle // atomic

// crash_bundle_init reserves everything the writer needs and deletes bundles beyond the newest
// BUNDLE_KEEP in root (the crashes directory, made if it does not exist). app is "game" or "server".
crash_bundle_init :: proc(root: string, app: string) -> bool {
	if len(root) == 0 || len(root) > 500 || sync.atomic_load(&bundle) != nil {return false}
	allocator := runtime.heap_allocator()
	os.make_directory_all(root)
	b := new(Crash_Bundle, allocator)
	b.allocator = allocator
	b.root_len = copy(b.root[:], root)
	if home, err := os.user_home_dir(context.temp_allocator); err == nil {
		b.home_len = copy(b.home[:], home)
		if b.home_len < len(home) {b.home_len = 0} 	// too long to compare: not replaced
	}
	b.start = time.tick_now()
	b.log = make([]u8, BUNDLE_LOG_BYTES, allocator)
	b.actions = make([]u8, BUNDLE_ACTIONS * BUNDLE_ACTION_BYTES, allocator)
	for &t in b.text {t = make([]u8, BUNDLE_TEXT, allocator)}
	b.arena_mem = make([]u8, BUNDLE_ARENA, allocator)

	cpu, cores, threads, os_name := machine_facts(context.temp_allocator)
	profile := "development" if DEV else "release"
	if ODIN_SANITIZER_FLAGS != {} {profile = "sanitize"}
	h := fmt.bprintf(
		b.header[:],
		"app: %s\nbuild: version=%s commit=%s profile=%s\nos: %s\ncpu: %s cores=%d threads=%d\n",
		app,
		VERSION,
		COMMIT,
		profile,
		os_name,
		cpu,
		cores,
		threads,
	)
	b.header_len = len(h)
	bundle_prune(root)
	bundle_platform_init()
	sync.atomic_store(&bundle, b)
	return true
}

// crash_bundle_destroy frees the writer's memory (debug_end; tests).
crash_bundle_destroy :: proc() {
	b := sync.atomic_exchange(&bundle, nil)
	if b == nil {return}
	bundle_platform_destroy()
	a := b.allocator
	delete(b.log, a)
	delete(b.actions, a)
	for t in b.text {delete(t, a)}
	delete(b.arena_mem, a)
	free(b, a)
}

crash_bundle_active :: proc() -> bool {
	return sync.atomic_load(&bundle) != nil
}

// crash_bundle_set_gpu: the device name, driver and API version, once the device exists.
crash_bundle_set_gpu :: proc(text: string) {
	if b := sync.atomic_load(&bundle); b != nil {b.gpu_len = copy(b.gpu[:], text)}
}

// crash_bundle_set_state: what the program is doing ("title", "loading", "world 12,3", "singleplayer").
// Never a server address or a name.
crash_bundle_set_state :: proc(text: string) {
	if b := sync.atomic_load(&bundle); b != nil {b.state_len = copy(b.state[:], text)}
}

// crash_bundle_log copies one log line (the file's form, with its newline) into the ring.
// The logger calls it, locked or not (the crash handler's lines are not): it reserves its bytes
// with one atomic add.
crash_bundle_log :: proc(line: string) {
	b := sync.atomic_load(&bundle)
	if b == nil || len(line) == 0 {return}
	line := line
	if len(line) > len(b.log) {line = line[len(line) - len(b.log):]}
	end := sync.atomic_add(&b.log_head, len(line))
	start := (end) % len(b.log)
	first := min(len(line), len(b.log) - start)
	copy(b.log[start:], line[:first])
	copy(b.log[:], line[first:])
}

// crash_bundle_action records one action: "t=<seconds> <kind> <detail>". Kind is one word
// (action, screen, world, command); detail is a name, never typed text.
crash_bundle_action :: proc(kind: string, detail: string = "") {
	b := sync.atomic_load(&bundle)
	if b == nil {return}
	i := sync.atomic_add(&b.action_head, 1) % BUNDLE_ACTIONS
	rec := b.actions[i * BUNDLE_ACTION_BYTES:][:BUNDLE_ACTION_BYTES]
	secs := time.duration_seconds(time.tick_since(b.start))
	text := fmt.bprintf(rec[1:], "t=%.3f %s %s", secs, kind, detail)
	rec[0] = u8(len(text))
}

// thread_register names the calling thread for crash bundles and gives it a stack for the
// signal that reports it (POSIX). Every thread we start calls it first and thread_unregister
// last (`defer`). The table holds BUNDLE_THREADS; more are not listed.
thread_register :: proc(name: string) {
	for i in 0 ..< BUNDLE_THREADS {
		s := &slots[i]
		if sync.atomic_compare_exchange_strong(&s.used, 0, 2) != 0 {continue} 	// 2: being filled
		s.name_len = copy(s.name[:], name)
		s.frame_n = 0
		top := 0
		s.stack_top = uintptr(&top)
		sync.atomic_store(&s.done, 0)
		thread_platform_register(s)
		my_slot = i + 1
		sync.atomic_store(&s.used, 1)
		return
	}
}

thread_unregister :: proc() {
	if my_slot == 0 {return}
	s := &slots[my_slot - 1]
	my_slot = 0
	sync.atomic_store(&s.used, 2)
	thread_platform_unregister(s)
	sync.atomic_store(&s.used, 0)
}

// stack_overflow_at: the fault at address is within STACK_WINDOW below the calling thread's
// stack top: a guard page hit, not a wild pointer.
@(private)
stack_overflow_at :: proc(address: rawptr) -> bool {
	if my_slot == 0 {return false}
	top, at := slots[my_slot - 1].stack_top, uintptr(address)
	return at < top && top - at < 16 * 1024 * 1024
}

@(private)
thread_name_here :: proc() -> string {
	if my_slot == 0 {return "unregistered"}
	s := &slots[my_slot - 1]
	return string(s.name[:s.name_len])
}

// crash_bundle_write writes the bundle for a crash described by what (the signal and address, the
// exception, the assert message) and returns its directory ("" if there is none: not initialised,
// already written, or a test run). The calling thread is the crashing one. Called from the signal
// handler, the exception filter and the assertion handler.
crash_bundle_write :: proc(what: string) -> string {
	b := sync.atomic_load(&bundle)
	if b == nil {return ""}
	if sync.atomic_compare_exchange_strong(&b.written, 0, 1) != 0 {return ""}

	// What the crash path allocates goes to the arena.
	mem.arena_init(&b.arena, b.arena_mem)
	arena := mem.arena_allocator(&b.arena)
	context.allocator = arena
	context.temp_allocator = arena

	now := time.now()
	y, mon, d := time.date(now)
	hour, minute, second := time.clock(now)
	name := fmt.bprintf(
		b.last_dir[:],
		"%s/%04d-%02d-%02d_%02d-%02d-%02d-%d",
		string(b.root[:b.root_len]),
		y,
		mon,
		d,
		hour,
		minute,
		second,
		bundle_pid(),
	)
	b.last_len = len(name)
	bundle_watchdog(true)
	defer bundle_watchdog(false)
	if !bundle_mkdir(name) {return ""}

	// Every other thread captures its stack; this one's goes first.
	var_frames: [BUNDLE_FRAMES]rawptr
	own_n := 0
	{
		own_n = trace.capture_fill(([^]trace.Capture_Entry)(&var_frames[0])[:BUNDLE_FRAMES], 0)
	}
	threads_capture_others()

	// crash.txt
	{
		gpu := string(b.gpu[:b.gpu_len]) if b.gpu_len > 0 else "none yet"
		state := string(b.state[:b.state_len]) if b.state_len > 0 else "unknown"
		text := fmt.bprintf(
			b.text[0],
			"what: %s\nthread: %s\n%sgpu: %s\nuptime_s: %.0f\nstate: %s\n",
			what,
			thread_name_here(),
			string(b.header[:b.header_len]),
			gpu,
			time.duration_seconds(time.tick_since(b.start)),
			state,
		)
		bundle_file(name, "crash.txt", transmute([]u8)text)
	}
	// threads.txt: first with raw addresses (nothing to go wrong), then, with the frames
	// resolved to our procedures, over it. Resolving asks the C library or the OS for symbols
	// (on macOS CoreSymbolication, which takes locks, allocates and talks to other processes),
	// so a hang there leaves the raw file, and the watchdog ends the process.
	for resolve in ([]bool{false, true}) {
		sb := strings.builder_from_bytes(b.text[1])
		fmt.sbprintf(&sb, "thread %s (crashing)\n", thread_name_here())
		write_frames(&sb, var_frames[:own_n], resolve)
		for i in 0 ..< BUNDLE_THREADS {
			s := &slots[i]
			if sync.atomic_load(&s.used) != 1 || my_slot == i + 1 {continue}
			fmt.sbprintf(&sb, "thread %s\n", string(s.name[:s.name_len]))
			if sync.atomic_load(&s.done) == 0 {
				strings.write_string(&sb, "  did not answer\n")
			} else {
				write_frames(&sb, s.frames[:s.frame_n], resolve)
			}
		}
		bundle_file(name, "threads.txt", sb.buf[:])
	}
	// log.txt: the ring's tail in order, the home directory as "~"
	{
		head := sync.atomic_load(&b.log_head)
		n := min(head, len(b.log))
		start := (head - n) % len(b.log)
		file, ok := bundle_open(name, "log.txt")
		if ok {
			defer bundle_close(file)
			home := string(b.home[:b.home_len])
			tail := b.log[start:][:min(n, len(b.log) - start)]
			log_write_replaced(file, tail, home)
			log_write_replaced(file, b.log[:n - len(tail)], home)
		}
	}
	// actions.txt: oldest first
	{
		head := sync.atomic_load(&b.action_head)
		n := min(head, BUNDLE_ACTIONS)
		sb := strings.builder_from_bytes(b.text[2])
		for k in head - n ..< head {
			rec := b.actions[(k % BUNDLE_ACTIONS) * BUNDLE_ACTION_BYTES:][:BUNDLE_ACTION_BYTES]
			if rec[0] == 0 || int(rec[0]) >= BUNDLE_ACTION_BYTES {continue}
			strings.write_string(&sb, string(rec[1:][:rec[0]]))
			strings.write_byte(&sb, '\n')
		}
		bundle_file(name, "actions.txt", sb.buf[:])
	}
	return name
}

// bundle_last: the directory the last bundle went to ("" if none).
crash_bundle_last :: proc() -> string {
	b := sync.atomic_load(&bundle)
	if b == nil {return ""}
	return string(b.last_dir[:b.last_len])
}

// crash_bundle_rearm lets a test write a second bundle.
crash_bundle_rearm :: proc() {
	if b := sync.atomic_load(&bundle); b != nil {sync.atomic_store(&b.written, 0)}
}

// log_write_replaced writes part with "~" for every home prefix.
@(private)
log_write_replaced :: proc(file: Bundle_File, part: []u8, home: string) {
	rest := string(part)
	for len(rest) > 0 {
		i := strings.index(rest, home) if len(home) > 0 else -1
		if i < 0 {
			bundle_write(file, transmute([]u8)rest)
			return
		}
		bundle_write(file, transmute([]u8)rest[:i])
		bundle_write(file, {'~'})
		rest = rest[i + len(home):]
	}
}

// is_handler_frame: the crash machinery's own frames, above the crashed code's.
@(private)
is_handler_frame :: proc(procedure: string) -> bool {
	for name in ([]string{"crash_bundle_write", "crash_report", "crash_signal", "crash_filter", "assertion_failure", "thread_stack_signal"}) {
		if strings.contains(procedure, name) {return true}
	}
	return false
}

// write_frames lists the frames of ours (resolve), or just the raw addresses; with none of
// ours, the raw addresses.
@(private)
write_frames :: proc(sb: ^strings.Builder, frames: []rawptr, resolve: bool) {
	if len(frames) == 0 {
		strings.write_string(sb, "  (no frames)\n")
		return
	}
	if !resolve {
		strings.write_string(sb, "  (raw")
		for f in frames[:min(len(frames), 16)] {fmt.sbprintf(sb, " %p", f)}
		strings.write_string(sb, ")\n")
		return
	}
	entries := make([]trace.Capture_Entry, len(frames))
	for f, i in frames {entries[i] = trace.Capture_Entry(f)}
	locs, err := trace.resolve(entries)
	found := false
	if err == nil {
		for loc in locs {
			if !strings.has_suffix(loc.file_path, ".odin") ||
			   strings.has_prefix(loc.procedure, "runtime::") ||
			   is_handler_frame(loc.procedure) {continue}
			fmt.sbprintf(sb, "  at %s (%s:%d)\n", loc.procedure, loc.file_path, loc.line)
			found = true
		}
	}
	if !found {
		// A build without line tables: addresses, for a matching build to resolve.
		strings.write_string(sb, "  (no frames of ours; raw")
		for f in frames[:min(len(frames), 16)] {fmt.sbprintf(sb, " %p", f)}
		strings.write_string(sb, ")\n")
	}
	free_all(context.allocator)
}

@(private)
bundle_file :: proc(dir, file: string, data: []u8) {
	f, ok := bundle_open(dir, file)
	if !ok {return}
	b := sync.atomic_load(&bundle)
	log_write_replaced(f, data, string(b.home[:b.home_len]))
	bundle_close(f)
}

// bundle_prune keeps the newest BUNDLE_KEEP bundles in root (names sort by time).
@(private)
bundle_prune :: proc(root: string) {
	infos, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if err != nil {return}
	names := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		if fi.type == .Directory {append(&names, fi.name)}
	}
	if len(names) <= BUNDLE_KEEP {return}
	slice.sort(names[:])
	for n in names[:len(names) - BUNDLE_KEEP] {
		os.remove_all(fmt.tprintf("%s/%s", root, n))
	}
}
