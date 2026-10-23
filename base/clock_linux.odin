package base

import "core:sys/linux"

// The trace clock: what core:prof/spall stamps events with (CLOCK_MONOTONIC_RAW
// in ns), so GPU timestamps calibrated against it line up with CPU events.
trace_clock_ns :: proc "contextless" () -> i64 {
	t, _ := linux.clock_gettime(.MONOTONIC_RAW)
	return i64(t.time_sec) * 1e9 + i64(t.time_nsec)
}

// host_clock_to_ns converts a Vulkan host-domain timestamp
// (VK_TIME_DOMAIN_CLOCK_MONOTONIC_RAW) to trace_clock_ns time: already ns.
host_clock_to_ns :: proc "contextless" (value: u64) -> i64 {
	return i64(value)
}
