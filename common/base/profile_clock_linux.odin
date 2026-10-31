#+build linux
package base

import "core:c"

foreign import libc "system:c"

@(private = "file")
Timespec :: struct {
	sec:  i64,
	nsec: c.long,
}

@(private = "file")
foreign libc {
	@(link_name = "clock_gettime")
	libc_clock_gettime :: proc "c" (clock: c.int, tp: ^Timespec) -> c.int ---
}

@(private = "file")
CLOCK_MONOTONIC_RAW :: 4

// profile_now: the trace's clock in nanoseconds. It is the clock spall reads
// (CLOCK_MONOTONIC_RAW, the one the GPU's timestamps are calibrated against),
// read through libc: its vDSO takes ~60 ns where spall's system call takes ~900,
// twice a scope, which made a profiling build's timings several times too long.
profile_now :: proc "contextless" () -> u64 {
	t: Timespec
	libc_clock_gettime(CLOCK_MONOTONIC_RAW, &t)
	return u64(t.sec) * 1_000_000_000 + u64(t.nsec)
}
