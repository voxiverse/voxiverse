#+build !linux
package base

@(require) import "core:prof/spall" // used only in profiling builds

// profile_now: the trace's clock in nanoseconds, as spall reads it (cheap here:
// QueryPerformanceCounter, mach_absolute_time).
profile_now :: proc "contextless" () -> u64 {
	when PROFILE {return spall._trace_now(&trace)} else {return 0}
}
