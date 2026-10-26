package base

import "base:runtime"

// Rng is xoshiro256** (Blackman and Vigna), seeded through splitmix64: 32 bytes
// of state, and a stream that is ours, not the toolchain's to change. Every
// random draw that reaches state (server simulation, worldgen, prediction) is
// made from one; see docs/determinism.md. Crypto randomness is never state.
Rng :: struct {
	s: [4]u64,
}

rng_make :: proc "contextless" (seed: u64) -> (r: Rng) {
	x := seed
	for &w in r.s {
		x += 0x9e37_79b9_7f4a_7c15
		z := x
		z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
		z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
		w = z ~ (z >> 31)
	}
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

// rng_f32 is uniform in [0, 1): the top 24 bits times 2^-24.
rng_f32 :: proc "contextless" (r: ^Rng) -> f32 {
	return f32(rng_u64(r) >> 40) * (1.0 / 16777216.0)
}

// rng_f64 is uniform in [0, 1): the top 53 bits times 2^-53.
rng_f64 :: proc "contextless" (r: ^Rng) -> f64 {
	return f64(rng_u64(r) >> 11) * (1.0 / 9007199254740992.0)
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
