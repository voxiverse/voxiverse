package base

import "core:math"
import "core:slice"

// Numbers that state depends on (docs/determinism.md). core:math's sin, cos,
// exp, pow and tan are LLVM intrinsics: each OS's libm answers them, and
// -o:speed may fold them at compile time with another result. These are plain
// Odin code on IEEE arithmetic, so every OS and optimization level agrees to
// the bit. The f32 forms compute in f64 and round once.

sincos_f64 :: proc "contextless" (x: f64) -> (s, c: f64) {
	return math.sincos_f64(x)
}

sincos_f32 :: proc "contextless" (x: f32) -> (s, c: f32) {
	a, b := math.sincos_f64(f64(x))
	return f32(a), f32(b)
}

sincos :: proc {
	sincos_f32,
	sincos_f64,
}

sin_f64 :: proc "contextless" (x: f64) -> f64 {
	s, _ := math.sincos_f64(x)
	return s
}

sin_f32 :: proc "contextless" (x: f32) -> f32 {
	s, _ := math.sincos_f64(f64(x))
	return f32(s)
}

sin :: proc {
	sin_f32,
	sin_f64,
}

cos_f64 :: proc "contextless" (x: f64) -> f64 {
	_, c := math.sincos_f64(x)
	return c
}

cos_f32 :: proc "contextless" (x: f32) -> f32 {
	_, c := math.sincos_f64(f64(x))
	return f32(c)
}

cos :: proc {
	cos_f32,
	cos_f64,
}

exp_f32 :: proc "contextless" (x: f32) -> f32 {
	return f32(exp_f64(f64(x)))
}

exp :: proc {
	exp_f32,
	exp_f64,
}

// exp_f64 is FreeBSD's e_exp.c (Sun Microsystems, 1993: "Permission to use, copy,
// modify, and distribute this software is freely granted, provided that this
// notice is preserved"), the source core:math's ln came from.
exp_f64 :: proc "contextless" (x_in: f64) -> f64 {
	LN2_HI :: 0h3fe62e42fee00000
	LN2_LO :: 0h3dea39ef35793c76
	INV_LN2 :: 0h3ff71547652b82fe
	P1 :: 0h3fc555555555553e
	P2 :: 0hbf66c16c16bebd93
	P3 :: 0h3f11566aaf25de2c
	P4 :: 0hbebbbd41c5d26bf1
	P5 :: 0h3e66376972bea4d0
	O_THRESHOLD :: 0h40862e42fefa39ef // 7.09782712893383973096e+02
	U_THRESHOLD :: 0hc0874910d52d3051 // -7.45133219101941108420e+02

	x := x_in
	if x != x {return x}
	if x > O_THRESHOLD {return math.inf_f64(1)}
	if x < U_THRESHOLD {return 0}

	hi, lo: f64
	k: int
	ax := abs(x)
	if ax > 0.5 * math.LN2 {
		if ax < 1.5 * math.LN2 {
			if x < 0 {
				hi, lo, k = x + LN2_HI, -LN2_LO, -1
			} else {
				hi, lo, k = x - LN2_HI, LN2_LO, 1
			}
		} else {
			half := 0.5 if x >= 0 else -0.5
			k = int(INV_LN2 * x + half)
			t := f64(k)
			hi = x - t * LN2_HI
			lo = t * LN2_LO
		}
		x = hi - lo
	} else if ax < 0h3e30000000000000 { 	// 2^-28
		return 1 + x
	}

	t := x * x
	c := x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))))
	y: f64
	if k == 0 {
		return 1 - ((x * c) / (c - 2) - x)
	}
	y = 1 - ((lo - (x * c) / (2 - c)) - hi)
	return scalbn(y, k)
}

@(private = "file")
scalbn :: proc "contextless" (y: f64, k: int) -> f64 {
	pow2 :: proc "contextless" (e: int) -> f64 { 	// 2^e for e in [-1022, 1023]
		return transmute(f64)(u64(e + 1023) << 52)
	}
	switch {
	case k >= -1021 && k <= 1023:
		return y * pow2(k)
	case k == 1024:
		return y * 2 * pow2(1023)
	case:
		return y * pow2(k + 1000) * pow2(-1000) // k < -1021: scale in two steps
	}
}

sort_by :: slice.sort_by // (a generic body below is checked only when used)

// keys_sorted returns a map's keys in the order less gives: the way to walk a
// map where the walk reaches state or the wire (map order is not stable).
keys_sorted :: proc(
	m: map[$K]$V,
	less: proc(a, b: K) -> bool,
	allocator := context.allocator,
	loc := #caller_location,
) -> []K {
	keys := make([dynamic]K, 0, len(m), allocator, loc)
	for k in m {append(&keys, k)}
	sort_by(keys[:], less)
	return keys[:]
}
