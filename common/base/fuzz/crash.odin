package fuzz

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:base"

// Saving the input that crashed. Before each case the harness copies the input into a
// buffer made once; the crash hook (a failed assert, a fatal signal, the watchdog) writes it
// to <out_dir>/<target>/crash-<XXH64>.bin with the target's name and seed in crash-<XXH64>.txt.

@(private = "file")
Crash_State :: struct {
	buf:     []u8,
	len:     int,
	name:    [64]u8,
	name_n:  int,
	out_dir: [256]u8,
	out_n:   int,
	seed:    u64,
	seeds:   [256]u8,
	seeds_n: int,
}

@(private = "file")
crash: Crash_State

@(private = "file")
installed: bool

// The watchdog: the wall tick a case began at (0: none running).
@(private = "file")
watch_started: i64

@(private = "file")
watch_thread: ^thread.Thread

crash_install :: proc(t: ^Target, cfg: Config) {
	// (kept for the run: not the tracked allocator's, which would call them leaks)
	context.allocator = runtime.heap_allocator()
	if len(crash.buf) < t.max_len {
		// (a bigger target replaces the buffer; the hook only runs between cases)
		crash.buf = make([]u8, t.max_len)
	}
	crash.name_n = copy(crash.name[:], t.name)
	crash.out_n = copy(crash.out_dir[:], cfg.out_dir)
	crash.seed = cfg.seed
	if installed {return}
	installed = true
	base.crash_hook_set(crash_hook)
	base.crash_handlers_install()
	asan_install()
	watch_thread = thread.create_and_start(watchdog_main, base.thread_context())
}

crash_input_set :: proc(t: ^Target, data: []u8) {
	crash.len = copy(crash.buf, data)
}

// save_failure writes the failing input and a note beside it; returns the .bin path.
save_failure :: proc(t: ^Target, cfg: Config, data: []u8, what: string) -> string {
	hash := xxhash.XXH64(data)
	dir := join({cfg.out_dir, t.name})
	os.make_directory_all(dir)
	path := fmt.aprintf("%s/crash-%016x.bin", dir, hash)
	_ = os.write_entire_file_from_bytes(path, data)
	note := fmt.tprintf(
		"target %s\nseed %d\nfailure %s\nreproduce: ./build.sh fuzz %s --case %s\n",
		t.name,
		cfg.seed,
		what,
		t.name,
		path,
	)
	_ = os.write_entire_file_from_bytes(
		fmt.tprintf("%s/crash-%016x.txt", dir, hash),
		transmute([]u8)note,
	)
	return path
}

// failure_key: the part of a crash report that is the same on every run (no address).
failure_key :: proc(what: string) -> string {
	end := len(what)
	for marker in ([]string{" address=", " exception="}) {
		if i := strings.index(what, marker); i >= 0 {end = min(end, i)}
	}
	if i := strings.index_byte(what, '\n'); i >= 0 {end = min(end, i)}
	return what[:end]
}

@(private)
crash_hook :: proc(what: string) {
	if crash.len == 0 && crash.name_n == 0 {return}
	hash := xxhash.XXH64(crash.buf[:crash.len])
	dir := fmt.tprintf(
		"%s/%s",
		string(crash.out_dir[:crash.out_n]),
		string(crash.name[:crash.name_n]),
	)
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/crash-%016x.bin", dir, hash)
	_ = os.write_entire_file_from_bytes(path, crash.buf[:crash.len])
	note := fmt.tprintf(
		"target %s\nseed %d\nfailure %s\nreproduce: ./build.sh fuzz %s --case %s\n",
		string(crash.name[:crash.name_n]),
		crash.seed,
		what,
		string(crash.name[:crash.name_n]),
		path,
	)
	_ = os.write_entire_file_from_bytes(
		fmt.tprintf("%s/crash-%016x.txt", dir, hash),
		transmute([]u8)note,
	)
	fmt.eprintfln("fuzz-failure: %s", failure_key(what))
	fmt.eprintfln("fuzz-input: %s", path)
}

// assertion_failure: a failed assert or a panic inside a target saves the input, then stops.
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	crash_hook(fmt.tprintf("%s: %s (%v)", prefix, message, loc))
	os.exit(70) // not a trap: under `odin test` a trap on a thread the runner did not start spins (#54)
}

watchdog_begin :: proc() {
	sync.atomic_store(&watch_started, time.tick_now()._nsec + 1)
}

watchdog_end :: proc() {
	sync.atomic_store(&watch_started, 0)
}

// hung: has a case begun at `started` (0: none) run past the limit at `now`?
hung :: proc(started, now: i64) -> bool {
	return started != 0 && now - started > HANG_SECONDS * i64(time.Second)
}

@(private = "file")
watchdog_main :: proc() {
	for {
		time.sleep(200 * time.Millisecond)
		started := sync.atomic_load(&watch_started)
		if hung(started, time.tick_now()._nsec + 1) {
			crash_hook("hang: a case ran past the watchdog's limit")
			os.exit(3)
		}
	}
}
