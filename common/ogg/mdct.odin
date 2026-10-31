package ogg

import "common:base"

// The inverse MDCT of a block of n samples from n/2 coefficients: a DCT-IV
// of size m = n/2 (one complex FFT of size m/2, radix 2, written once with a
// fixed order of operations), unfolded into n samples. All the constants are
// base.sin and base.cos, so the output is the same on every OS.

Mdct :: struct {
	n:   int, // block size
	m:   int, // n / 2
	pre: []f32, // pre rotation, (cos, sin) for k in 0 ..< m/2: exp(-i*pi*k/m)
	tw:  []f32, // post rotation: exp(-i*pi*(k + 1/4)/m)
	ftw: []f32, // FFT twiddles, (cos, sin) for k in 0 ..< m/4: exp(-2*pi*i*k/(m/2))
	rev: []u16, // bit reversal of 0 ..< m/2
}

PI_F64 :: 3.14159265358979323846264338327950288

mdct_init :: proc "contextless" (t: ^Mdct, a: ^Arena, n: int) -> Error {
	m := n / 2
	h := m / 2
	t.n, t.m = n, m
	ok: bool
	t.pre, ok = arena_make(a, f32, 2 * h)
	if !ok {return .Over_Limit}
	t.tw, ok = arena_make(a, f32, 2 * h)
	if !ok {return .Over_Limit}
	t.ftw, ok = arena_make(a, f32, 2 * max(h / 2, 1))
	if !ok {return .Over_Limit}
	t.rev, ok = arena_make(a, u16, h)
	if !ok {return .Over_Limit}
	for k in 0 ..< h {
		ang := -PI_F64 * (f64(k) + 0.25) / f64(m)
		pa := -PI_F64 * f64(k) / f64(m)
		t.pre[2 * k] = f32(base.cos_f64(pa))
		t.pre[2 * k + 1] = f32(base.sin_f64(pa))
		t.tw[2 * k] = f32(base.cos_f64(ang))
		t.tw[2 * k + 1] = f32(base.sin_f64(ang))
	}
	for k in 0 ..< h / 2 {
		ang := -2 * PI_F64 * f64(k) / f64(h)
		t.ftw[2 * k] = f32(base.cos_f64(ang))
		t.ftw[2 * k + 1] = f32(base.sin_f64(ang))
	}
	bitsn := ilog(h) - 1
	for i in 0 ..< h {
		r := 0
		for b in 0 ..< bitsn {
			if i & (1 << uint(b)) != 0 {r |= 1 << uint(bitsn - 1 - b)}
		}
		t.rev[i] = u16(r)
	}
	return .None
}

// dct4 computes out[k] = sum x[n] cos(pi/m (n + 1/2)(k + 1/2)); work holds m floats.
dct4 :: proc "contextless" (t: ^Mdct, x, out, work: []f32) {
	m := t.m
	h := m / 2
	// Every index below is under these lengths (rev holds 0 ..< h, mdct_init's
	// bit reversal), so none is checked per sample.
	assert_contextless(
		len(x) >= m &&
		len(out) >= m &&
		len(work) >= m &&
		len(t.pre) >= m &&
		len(t.tw) >= m &&
		len(t.ftw) >= h &&
		len(t.rev) >= h,
		"dct4: buffers shorter than the block",
	)
	#no_bounds_check {
		// Fold into complex z[j] = (x[2j] + i x[m-1-2j]) * w[j], in bit-reversed place.
		for j in 0 ..< h {
			re := x[2 * j]
			im := x[m - 1 - 2 * j]
			c, s := t.pre[2 * j], t.pre[2 * j + 1]
			p := int(t.rev[j])
			work[2 * p] = re * c - im * s
			work[2 * p + 1] = re * s + im * c
		}
		// Radix-2 butterflies.
		size := 2
		for size <= h {
			half := size / 2
			step := h / size
			for start := 0; start < h; start += size {
				for k in 0 ..< half {
					wr, wi := t.ftw[2 * k * step], t.ftw[2 * k * step + 1]
					i0 := 2 * (start + k)
					i1 := 2 * (start + k + half)
					xr := work[i1] * wr - work[i1 + 1] * wi
					xi := work[i1] * wi + work[i1 + 1] * wr
					work[i1] = work[i0] - xr
					work[i1 + 1] = work[i0 + 1] - xi
					work[i0] += xr
					work[i0 + 1] += xi
				}
			}
			size *= 2
		}
		for k in 0 ..< h {
			c, s := t.tw[2 * k], t.tw[2 * k + 1]
			re := work[2 * k] * c - work[2 * k + 1] * s
			im := work[2 * k] * s + work[2 * k + 1] * c
			out[2 * k] = re
			out[m - 1 - 2 * k] = -im
		}
	}
}

// imdct writes the n windowed-ready samples of the spectrum; v and work are m floats each.
imdct :: proc "contextless" (t: ^Mdct, spec, out, v, work: []f32) {
	m := t.m
	dct4(t, spec[:m], v, work)
	q := m / 2
	for i in 0 ..< q {out[i] = v[i + q]}
	for i in q ..< q + m {out[i] = -v[3 * q - 1 - i]}
	for i in q + m ..< 2 * m {out[i] = -v[i - 3 * q]}
}

// window_slope: the Vorbis power-sine rising half window, n samples.
window_slope :: proc "contextless" (w: []f32) {
	n := len(w)
	for i in 0 ..< n {
		x := base.sin_f64(PI_F64 / 2 * (f64(i) + 0.5) / f64(n))
		w[i] = f32(base.sin_f64(PI_F64 / 2 * x * x))
	}
}
