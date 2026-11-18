package base

import "base:intrinsics"
import "base:runtime"

// Rng is xoshiro256** (Blackman and Vigna), seeded through splitmix64: 32 bytes
// of state, and a stream that is ours, not the toolchain's to change. Every
// random draw that reaches state (server simulation, worldgen, prediction) is
// made from one; see docs/determinism.md. Crypto randomness is never state.
Rng :: struct {
	s: [4]u64,
}

// rng_make: the state is the first four draws of splitmix from seed (chance.odin).
rng_make :: proc "contextless" (seed: u64) -> (r: Rng) {
	x := seed
	for &w in r.s {w = splitmix(&x)}
	return
}

rng_u64 :: proc "contextless" (r: ^Rng) -> u64 {
	rotl :: proc "contextless" (x: u64, k: u64) -> u64 {return (x << k) | (x >> (64 - k))}
	result := rotl(r.s[1] * 5, 7) * 9
	t := r.s[1] << 17
	r.s[2] ~= r.s[0]
	r.s[3] ~= r.s[1]
	r.s[1] ~= r.s[2]
	r.s[0] ~= r.s[3]
	r.s[2] ~= t
	r.s[3] = rotl(r.s[3], 45)
	return result
}

rng_u32 :: proc "contextless" (r: ^Rng) -> u32 {
	return u32(rng_u64(r) >> 32)
}

// rng_int_max is uniform in [0, n): Lemire's multiply-shift with rejection.
rng_int_max :: proc "contextless" (r: ^Rng, n: int) -> int {
	runtime.assert_contextless(n > 0, "rng_int_max needs n > 0")
	un := u64(n)
	hi, lo := mul128(rng_u64(r), un)
	if lo < un {
		threshold := -un % un
		for lo < threshold {
			hi, lo = mul128(rng_u64(r), un)
		}
	}
	return int(hi)
}

// rng_int_range is uniform in [lo, hi).
rng_int_range :: proc "contextless" (r: ^Rng, lo, hi: int) -> int {
	runtime.assert_contextless(hi > lo, "rng_int_range needs lo < hi")
	return lo + rng_int_max(r, hi - lo)
}

// rng_roll is uniform in [lo, hi], both ends included (a die is rng_roll(r, 1, 6)):
// rng_int_range(r, lo, hi + 1), draw for draw, for any integer type.
rng_roll :: proc "contextless" (r: ^Rng, lo, hi: $T) -> T where intrinsics.type_is_integer(T) {
	runtime.assert_contextless(hi >= lo, "rng_roll needs lo <= hi")
	return lo + T(rng_int_max(r, int(hi) - int(lo) + 1))
}

// rng_f32 is uniform in [0, 1): unit_f32 of a draw.
rng_f32 :: proc "contextless" (r: ^Rng) -> f32 {
	return unit_f32(rng_u64(r))
}

// rng_f64 is uniform in [0, 1): unit_f64 of a draw.
rng_f64 :: proc "contextless" (r: ^Rng) -> f64 {
	return unit_f64(rng_u64(r))
}

rng_f32_range :: proc "contextless" (r: ^Rng, lo, hi: f32) -> f32 {
	return lo + (hi - lo) * rng_f32(r)
}

rng_f64_range :: proc "contextless" (r: ^Rng, lo, hi: f64) -> f64 {
	return lo + (hi - lo) * rng_f64(r)
}

@(private = "file")
mul128 :: proc "contextless" (a, b: u64) -> (hi, lo: u64) {
	p := u128(a) * u128(b)
	return u64(p >> 64), u64(p)
}
