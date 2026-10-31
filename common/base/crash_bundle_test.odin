package base

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file")
SCRATCH :: "build/tmp/crash_bundle_test"

@(private = "file")
FILLER :: "............................................................................................................................................................................................................................................................................................................................................................................................................................"

@(private = "file")
read_text :: proc(dir, file: string) -> string {
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/%s", dir, file),
		context.temp_allocator,
	)
	return string(data) if err == nil else "<none>"
}

@(private = "file")
Spinner :: struct {
	ready, stop: u32,
}

@(private = "file")
spin :: proc(t: ^thread.Thread) {
	s := (^Spinner)(t.data)
	thread_register("spinner")
	defer thread_unregister()
	sync.atomic_store(&s.ready, 1)
	for sync.atomic_load(&s.stop) == 0 {sync.cpu_relax()}
}

// One test, since the bundle is one per process: retention, the log ring across wrap-around, the
// action ring, the home directory as "~", the files and their headings, other threads' stacks,
// and no allocation but the arena's.
@(test)
test_crash_bundle_files :: proc(t: ^testing.T) {
	os.remove_all(SCRATCH)
	defer os.remove_all(SCRATCH)
	// retention: twelve old bundles, the newest ten stay
	for i in 1 ..= 12 {os.make_directory_all(fmt.tprintf("%s/2020-01-%02d_00-00-00-1", SCRATCH, i))}
	if !testing.expect(t, crash_bundle_init(SCRATCH, "game")) {return}
	defer crash_bundle_destroy()
	infos, _ := os.read_directory_by_path(SCRATCH, -1, context.temp_allocator)
	testing.expect_value(t, len(infos), BUNDLE_KEEP)
	for fi in infos {testing.expect(t, fi.name != "2020-01-01_00-00-00-1" && fi.name != "2020-01-02_00-00-00-1")}

	thread_register("tester")
	defer thread_unregister()
	spinner: Spinner
	worker := thread.create(spin)
	worker.data = &spinner
	thread.start(worker)
	defer {
		sync.atomic_store(&spinner.stop, 1)
		thread.join(worker)
		thread.destroy(worker)
	}
	for sync.atomic_load(&spinner.ready) == 0 {sync.cpu_relax()}

	filler := FILLER
	// 1200 lines of 400 bytes: the ring wraps; the last 256 KiB stay, byte for byte
	all: strings.Builder
	strings.builder_init(&all, context.temp_allocator)
	for i in 0 ..< 1200 {
		num := fmt.tprintf("%d", i)
		line := fmt.tprintf("%s %s\n", num, filler[:398 - len(num)])
		strings.write_string(&all, line)
		crash_bundle_log(line)
	}
	home, _ := os.user_home_dir(context.temp_allocator)
	crash_bundle_log(fmt.tprintf("at %s/world/save.dat\n", home))
	for i in 0 ..< 300 {crash_bundle_action("action", fmt.tprintf("move_%d", i))}
	crash_bundle_set_gpu("Test GPU driver 1.0 vulkan 1.3")
	crash_bundle_set_state("title")

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	saved := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	dir := crash_bundle_write("signal=SIGSEGV address=0x0")
	context.allocator = saved
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, track.total_allocation_count, 0)
	if !testing.expect(t, dir != "") {return}
	testing.expect_value(t, crash_bundle_write("again"), "") // once per process

	crash := read_text(dir, "crash.txt")
	testing.expect(
		t,
		strings.has_prefix(crash, "what: signal=SIGSEGV address=0x0\nthread: tester\n"),
		crash,
	)
	for heading in ([]string{"app: game\n", "build: version=", "os: ", "cpu: ", "gpu: Test GPU driver", "uptime_s: ", "state: title\n"}) {
		testing.expect(t, strings.contains(crash, heading), heading)
	}

	threads := read_text(dir, "threads.txt")
	testing.expect(t, strings.has_prefix(threads, "thread tester (crashing)\n"), threads)
	testing.expect(t, strings.contains(threads, "thread spinner\n"), threads)
	when ODIN_OS != .Windows {
		testing.expect(t, !strings.contains(threads, "did not answer"), threads)
	}

	log_text := read_text(dir, "log.txt")
	tail := strings.to_string(all)
	// (the home line follows the 1200; the ring ends with it, "~" for the home directory)
	home_line := "at ~/world/save.dat\n"
	testing.expect(
		t,
		strings.has_suffix(log_text, home_line),
		log_text[max(0, len(log_text) - 80):],
	)
	body := log_text[:len(log_text) - len(home_line)]
	// the ring held 256 KiB: the home line's raw bytes took theirs from the oldest end
	raw_home := fmt.tprintf("at %s/world/save.dat\n", home)
	want := tail[len(tail) - (BUNDLE_LOG_BYTES - len(raw_home)):]
	testing.expect(t, body == want, "the log's tail is not the last bytes written, in order")
	testing.expect(t, !strings.contains(log_text, home) || home == "")

	actions := strings.split_lines(
		strings.trim_right(read_text(dir, "actions.txt"), "\n"),
		context.temp_allocator,
	)
	testing.expect_value(t, len(actions), BUNDLE_ACTIONS)
	testing.expect(t, strings.has_suffix(actions[0], " action move_44"), actions[0])
	testing.expect(t, strings.has_suffix(actions[len(actions) - 1], " action move_299"))
	testing.expect(t, strings.has_prefix(actions[0], "t="))
}
