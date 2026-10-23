package base

import win "core:sys/windows"

// The trace clock: what core:prof/spall stamps events with (the performance
// counter in ns), so GPU timestamps calibrated against it line up with CPU
// events.
trace_clock_ns :: proc "contextless" () -> i64 {
	now: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&now)
	return host_clock_to_ns(u64(now))
}

// host_clock_to_ns converts performance-counter ticks
// (VK_TIME_DOMAIN_QUERY_PERFORMANCE_COUNTER) to trace_clock_ns time.
host_clock_to_ns :: proc "contextless" (value: u64) -> i64 {
	@(static) frequency: win.LARGE_INTEGER
	if frequency == 0 {win.QueryPerformanceFrequency(&frequency)}
	ticks, freq := i64(value), i64(frequency)
	return (ticks / freq) * 1e9 + (ticks % freq) * 1e9 / freq
}
