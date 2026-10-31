package crash_fixture

// Not a test: tests/crash_bundle_test.odin builds this program and runs it to crash on purpose.
//
//	crash_fixture <crashes dir> main-segv | worker-segv | assert | overflow
//
// Four named threads are running when it crashes, so the bundle must name five threads.

import "base:intrinsics"
import "common:base"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

ready: u32
mode: string

main :: proc() {
	if len(os.args) < 3 {os.exit(2)}
	mode = os.args[2]
	dbg: base.Debug
	context = base.debug_begin(&dbg, "crash_fixture.log", "main")
	if !base.crash_bundle_init(os.args[1], "game") {os.exit(2)}
	names := [4]string{"alpha", "beta", "gamma", "delta"}
	for name in names {
		t := thread.create(worker, name = name)
		t.data = raw_data(name)
		t.init_context = base.thread_context()
		thread.start(t)
	}
	for sync.atomic_load(&ready) < 4 {time.sleep(time.Millisecond)}
	switch mode {
	case "main-segv":
		crash_now()
	case "assert":
		assert(false, "the fixture's assert")
	case "worker-segv", "overflow":
		time.sleep(10 * time.Second) // a worker crashes the process
	}
	os.exit(3) // not reached
}

@(private)
crash_now :: proc() {
	intrinsics.volatile_store((^int)(uintptr(8)), 1)
}

@(private)
recurse :: proc(n: int) -> int {
	buf: [256]u8
	buf[n % 256] = u8(n)
	return recurse(n + 1) + int(buf[(n + 7) % 256])
}

worker :: proc(t: ^thread.Thread) {
	name := string(cstring(t.data))
	base.thread_register(name)
	defer base.thread_unregister()
	sync.atomic_add(&ready, 1)
	if name == "delta" {
		time.sleep(300 * time.Millisecond) // the others are parked by now
		switch mode {
		case "worker-segv":
			crash_now()
		case "overflow":
			_ = recurse(0)
		}
	}
	for {time.sleep(10 * time.Millisecond)}
}
