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

pow :: proc {
	pow_f64,
}

@(private = "file")
low_zero :: #force_inline proc "contextless" (x: f64) -> f64 {
	return transmute(f64)(transmute(u64)x & 0xffff_ffff_0000_0000)
}

@(private = "file")
with_high :: #force_inline proc "contextless" (x: f64, hi: i32) -> f64 {
	return transmute(f64)((u64(u32(hi)) << 32) | (transmute(u64)x & 0xffff_ffff))
}

// pow_f64 is FreeBSD's e_pow.c (Sun Microsystems, 1993: "Permission to use, copy,
// modify, and distribute this software is freely granted, provided that this notice is
// preserved"), the family exp_f64 came from; C99 Annex F's special cases. A NaN result is
// always 0x7FF8_0000_0000_0000: the sign and payload x64 and arm64 give a NaN differ.
pow_f64 :: proc "contextless" (x, y: f64) -> f64 {
	z := pow_raw(x, y)
	if z != z {return transmute(f64)u64(0x7FF8_0000_0000_0000)}
	return z
}

@(private = "file")
pow_raw :: proc "contextless" (x, y: f64) -> f64 {
	BP := [2]f64{1.0, 1.5}
	DP_H := [2]f64{0.0, 0h3fe2b80340000000}
	DP_L := [2]f64{0.0, 0h3e4cfdeb43cfd006}
	TWO53 :: 0h4340000000000000
	L1 :: 0h3fe3333333333303
	L2 :: 0h3fdb6db6db6fabff
	L3 :: 0h3fd55555518f264d
	L4 :: 0h3fd17460a91d4101
	L5 :: 0h3fcd864a93c9db65
	L6 :: 0h3fca7e284a454eef
	P1 :: 0h3fc555555555553e
	P2 :: 0hbf66c16c16bebd93
	P3 :: 0h3f11566aaf25de2c
	P4 :: 0hbebbbd41c5d26bf1
	P5 :: 0h3e66376972bea4d0
	LG2 :: 0h3fe62e42fefa39ef
	LG2_H :: 0h3fe62e4300000000
	LG2_L :: 0hbe205c610ca86c39
	OVT :: 8.0085662595372944372e-17
	CP :: 0h3feec709dc3a03fd
	CP_H :: 0h3feec709e0000000
	CP_L :: 0hbe3e2fe0145b01f5
	IVLN2 :: 0h3ff71547652b82fe
	IVLN2_H :: 0h3ff7154760000000
	IVLN2_L :: 0h3e54ae0bf85ddf44
	INF :: 0h7ff0000000000000

	xb, yb := transmute(u64)x, transmute(u64)y
	hx, lx := i32(xb >> 32), u32(xb)
	hy, ly := i32(yb >> 32), u32(yb)
	ix, iy := hx & 0x7fffffff, hy & 0x7fffffff

	if (u32(iy) | ly) == 0 {return 1} 	// x^0 = 1, even for NaN x
	if hx == 0x3ff00000 && lx == 0 {return 1} 	// 1^y = 1, even for NaN y
	if ix > 0x7ff00000 ||
	   (ix == 0x7ff00000 && lx != 0) ||
	   iy > 0x7ff00000 ||
	   (iy == 0x7ff00000 && ly != 0) {
		return x + y
	}

	// yisint: 0 y is not an integer, 1 an odd one, 2 an even one (for x < 0).
	yisint: i32 = 0
	if hx < 0 {
		if iy >= 0x43400000 {
			yisint = 2
		} else if iy >= 0x3ff00000 {
			k := (iy >> 20) - 0x3ff
			if k > 20 {
				j := ly >> u32(52 - k)
				if (j << u32(52 - k)) == ly {yisint = 2 - i32(j & 1)}
			} else if ly == 0 {
				j := iy >> u32(20 - k)
				if (j << u32(20 - k)) == iy {yisint = 2 - (j & 1)}
			}
		}
	}

	if ly == 0 {
		if iy == 0x7ff00000 { 	// y is +-inf
			if ((ix - 0x3ff00000) | i32(lx)) == 0 {return 1}
			if ix >= 0x3ff00000 {return y if hy >= 0 else 0}
			return -y if hy < 0 else 0
		}
		if iy == 0x3ff00000 {return 1 / x if hy < 0 else x}
		if hy == 0x40000000 {return x * x}
		if hy == 0x3fe00000 && hx >= 0 {return math.sqrt(x)}
	}

	ax := abs(x)
	if lx == 0 && (ix == 0x7ff00000 || ix == 0 || ix == 0x3ff00000) {
		z := ax // x is +-0, +-inf, +-1
		if hy < 0 {z = 1 / z}
		if hx < 0 {
			if ((ix - 0x3ff00000) | yisint) == 0 {
				z = (z - z) / (z - z) // (-1)^non-integer is NaN
			} else if yisint == 1 {
				z = -z
			}
		}
		return z
	}

	n := i32(u32(hx) >> 31) - 1
	if (n | yisint) == 0 {return (x - x) / (x - x)} 	// (x<0)^non-integer
	s := 1.0
	if (n | (yisint - 1)) == 0 {s = -1} 	// (-x)^odd

	t1, t2: f64
	if iy > 0x41e00000 { 	// |y| > 2^31
		if iy > 0x43f00000 { 	// |y| > 2^64: over- or underflows
			if ix <= 0x3fefffff {return INF if hy < 0 else 0}
			if ix >= 0x3ff00000 {return INF if hy > 0 else 0}
		}
		if ix < 0x3fefffff {return s * INF if hy < 0 else s * 0}
		if ix > 0x3ff00000 {return s * INF if hy > 0 else s * 0}
		t := ax - 1
		w := (t * t) * (0.5 - t * (0h3fd5555555555555 - t * 0.25))
		u := IVLN2_H * t
		v := t * IVLN2_L - w * IVLN2
		t1 = low_zero(u + v)
		t2 = v - (t1 - u)
	} else {
		n = 0
		if ix < 0x00100000 { 	// subnormal x
			ax *= TWO53
			n -= 53
			ix = i32(transmute(u64)ax >> 32)
		}
		n += (ix >> 20) - 0x3ff
		j := ix & 0x000fffff
		ix = j | 0x3ff00000
		k: i32
		if j <= 0x3988E {
			k = 0
		} else if j < 0xBB67A {
			k = 1
		} else {
			k = 0
			n += 1
			ix -= 0x00100000
		}
		ax = with_high(ax, ix)

		u := ax - BP[k]
		v := 1 / (ax + BP[k])
		ss := u * v
		s_h := low_zero(ss)
		t_h := with_high(0, ((ix >> 1) | 0x20000000) + 0x00080000 + (k << 18))
		t_l := ax - (t_h - BP[k])
		s_l := v * ((u - s_h * t_h) - s_h * t_l)
		s2 := ss * ss
		r := s2 * s2 * (L1 + s2 * (L2 + s2 * (L3 + s2 * (L4 + s2 * (L5 + s2 * L6)))))
		r += s_l * (s_h + ss)
		s2 = s_h * s_h
		t_h = low_zero(3 + s2 + r)
		t_l = r - ((t_h - 3) - s2)
		u = s_h * t_h
		v = s_l * t_h + t_l * ss
		p_h := low_zero(u + v)
		p_l := v - (p_h - u)
		z_h := CP_H * p_h
		z_l := CP_L * p_h + p_l * CP + DP_L[k]
		t := f64(n)
		t1 = low_zero(((z_h + z_l) + DP_H[k]) + t)
		t2 = z_l - (((t1 - t) - DP_H[k]) - z_h)
	}

	// (y1 + y2) * (t1 + t2)
	y1 := low_zero(y)
	p_l := (y - y1) * t1 + y * t2
	p_h := y1 * t1
	z := p_l + p_h
	zb := transmute(u64)z
	j, i := i32(zb >> 32), u32(zb)
	if j >= 0x40900000 { 	// z >= 1024
		if ((j - 0x40900000) | i32(i)) != 0 {return s * INF}
		if p_l + OVT > z - p_h {return s * INF}
	} else if (j & 0x7fffffff) >= 0x4090cc00 { 	// z <= -1075
		if (u32(j) - 0xc090cc00 | i) != 0 {return s * 0}
		if p_l <= z - p_h {return s * 0}
	}

	// 2^(p_h + p_l)
	ii := j & 0x7fffffff
	k := (ii >> 20) - 0x3ff
	n = 0
	if ii > 0x3fe00000 { 	// |z| > 0.5: n = [z + 0.5]
		n = j + (0x00100000 >> u32(k + 1))
		k = ((n & 0x7fffffff) >> 20) - 0x3ff
		t := with_high(0, n & ~(0x000fffff >> u32(k)))
		n = ((n & 0x000fffff) | 0x00100000) >> u32(20 - k)
		if j < 0 {n = -n}
		p_h -= t
	}
	t := low_zero(p_l + p_h)
	u := t * LG2_H
	v := (p_l - (t - p_h)) * LG2 + t * LG2_L
	z = u + v
	w := v - (z - u)
	t = z * z
	t1 = z - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))))
	r := (z * t1) / (t1 - 2) - (w + z * w)
	z = 1 - (r - z)
	jz := i32(transmute(u64)z >> 32)
	jz += n << 20
	if (jz >> 20) <= 0 {
		z = scalbn(z, int(n)) // subnormal output
	} else {
		z = with_high(z, jz)
	}
	return s * z
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
