#+build amd64
package audio

import "core:simd/x86"

// flush_denormals sets the thread's floating-point control so denormals are
// zero (FTZ/DAZ): they cost hundreds of cycles each on x86-64.
@(enable_target_feature = "sse")
flush_denormals :: proc "contextless" () {
	x86._mm_setcsr(x86._mm_getcsr() | 0x8040) // FTZ (bit 15) and DAZ (bit 6)
}

// denormals_flushed: whether this thread has them flushed (for tests).
@(enable_target_feature = "sse")
denormals_flushed :: proc "contextless" () -> bool {
	return x86._mm_getcsr() & 0x8040 == 0x8040
}
