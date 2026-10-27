package base

import "core:testing"
import "core:time"

// A 2 ms busy loop must read as 1-4 ms on every OS. Windows used to report 0
// or 15625 us here (GetThreadTimes ticks). The loop is timed on the wall
// clock, so a preemption can make the CPU time come up short: any of a few
// attempts in range passes, a coarse clock never lands in range.
@(test)
test_thread_cpu_us_resolves_two_milliseconds :: proc(t: ^testing.T) {
	took: i64
	for _ in 0 ..< 5 {
		wall := time.tick_now()
		start := thread_cpu_us()
		for time.duration_microseconds(time.tick_since(wall)) < 2000 {}
		took = thread_cpu_us() - start
		if took >= 1000 && took <= 4000 {return}
	}
	testing.expectf(t, false, "2 ms busy loop read as %d us of thread CPU time", took)
}
