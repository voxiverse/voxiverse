package base

import "core:sys/posix"

// The trace clock: what core:prof/spall stamps events with (CLOCK_MONOTONIC_RAW
// in ns), so GPU timestamps calibrated against it line up with CPU events.
trace_clock_ns :: proc "contextless" () -> i64 {
	t: posix.timespec
	posix.clock_gettime(posix.Clock(4), &t) // CLOCK_MONOTONIC_RAW
	return i64(t.tv_sec) * 1e9 + i64(t.tv_nsec)
}

host_clock_to_ns :: proc "contextless" (value: u64) -> i64 {
	return i64(value)
}
