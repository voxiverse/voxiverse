#+build windows
package base

import "core:sync"
import "core:sys/windows"
import "core:time"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	QueryThreadCycleTime :: proc(thread: windows.HANDLE, cycles: ^windows.ULONG64) -> windows.BOOL ---
}

// GetThreadTimes only advances once per scheduler tick (15.6 ms), so a 2 ms
// slice reads as 0 or 15625 us. The thread's cycle count is exact; cycles per
// microsecond (the invariant TSC rate) is measured once against the wall clock.
@(private = "file")
cycles_per_us: u64 // 0 until measured (the same value from any thread)

@(private = "file")
thread_cycles :: proc() -> u64 {
	c: windows.ULONG64
	QueryThreadCycleTime(windows.GetCurrentThread(), &c)
	return u64(c)
}

@(private = "file")
calibrate :: proc() -> u64 {
	// Spin a few times for 2 ms each. A preemption only lowers the rate seen
	// (the thread's cycles stop, the wall clock does not), so the best wins.
	best: u64
	for _ in 0 ..< 5 {
		wall := time.tick_now()
		c0 := thread_cycles()
		for time.duration_microseconds(time.tick_since(wall)) < 2000 {}
		cycles := thread_cycles() - c0
		us := u64(time.duration_microseconds(time.tick_since(wall)))
		if us > 0 {best = max(best, cycles / us)}
	}
	return max(best, 1)
}

// thread_cpu_us is the CPU time this thread has used, in microseconds: what a
// budget test reads, so that other threads and processes taking the core
// during the measurement do not count.
thread_cpu_us :: proc() -> i64 {
	rate := sync.atomic_load(&cycles_per_us)
	if rate == 0 {
		rate = calibrate()
		sync.atomic_store(&cycles_per_us, rate)
	}
	return i64(thread_cycles() / rate)
}
