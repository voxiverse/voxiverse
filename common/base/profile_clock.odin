package base

@(require) import "core:prof/spall" // used only in profiling builds

// profile_now: the trace's clock in nanoseconds. The platform's own when it installed one
// (Linux: CLOCK_MONOTONIC_RAW through libc, whose vDSO takes ~60 ns where spall's system
// call takes ~900, twice a scope, which made a profiling build's timings several times
// too long), otherwise as spall reads it (cheap: QueryPerformanceCounter, mach_absolute_time).
profile_now :: proc "contextless" () -> u64 {
	if clock.profile_now != nil {return clock.profile_now()}
	when PROFILE {return spall._trace_now(&trace)} else {return 0}
}
