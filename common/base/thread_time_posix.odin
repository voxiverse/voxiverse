#+build linux, darwin
package base

import "core:sys/posix"

// thread_cpu_us is the CPU time this thread has used, in microseconds: what a
// budget test reads, so that other threads and processes taking the core
// during the measurement do not count.
thread_cpu_us :: proc() -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.THREAD_CPUTIME_ID, &ts)
	return i64(ts.tv_sec) * 1_000_000 + i64(ts.tv_nsec) / 1000
}

// ticks is a cheap monotonic counter for the ratio of two spans (nanoseconds
// here; the unit differs by platform). The processor's own cycle counter would
// do, but it reads 0 on arm64 macOS, and the thread's CPU clock costs more than
// the calls it would time.
ticks :: proc() -> u64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}
