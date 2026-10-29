package base

import "core:testing"
import "core:time"

// The thread CPU clock must tick in steps well under 1 ms on every OS.
// Windows used to advance in 15625 us steps (GetThreadTimes ticks). The test
// reads the clock itself, not the wall clock: it spins until 5 ms of this
// thread's CPU time have passed and looks at the smallest step between two
// different readings. Preemption by other threads or processes takes no CPU
// time from this clock, so it cannot change the result; a coarse clock has no
// step below its tick.
@(test)
test_thread_cpu_us_resolves_under_a_millisecond :: proc(t: ^testing.T) {
	guard := time.tick_now()
	start := thread_cpu_us()
	last := start
	smallest := max(i64)
	for last - start < 5000 {
		now := thread_cpu_us()
		if now != last {
			smallest = min(smallest, now - last)
			last = now
		}
		if time.duration_seconds(time.tick_since(guard)) > 30 {break}
	}
	testing.expectf(
		t,
		smallest < 1000,
		"thread CPU time advanced in steps of at least %d us (%d us seen)",
		smallest,
		last - start,
	)
}
