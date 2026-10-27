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
