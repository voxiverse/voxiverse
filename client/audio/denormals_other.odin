#+build !amd64
package audio

// flush_denormals does nothing off x86-64: this toolchain's inline assembly
// is amd64-only, so FPCR's flush-to-zero cannot be set from Odin. The filters'
// and the reverb's own state flushing (they zero what falls under 1e-25) is
// all there is, which the arm64 chips we run on (Apple's) do not need: they
// handle denormals at full speed.
flush_denormals :: proc "contextless" () {}

denormals_flushed :: proc "contextless" () -> bool {return false}
