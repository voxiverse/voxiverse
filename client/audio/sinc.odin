package audio

import "base:intrinsics"
import "core:math"
import "core:simd"

// Windowed-sinc resampling: a Kaiser-windowed sinc (beta 10, 100 dB
// stop-band) tabulated at SINC_RES points per source sample and read with
// linear interpolation (the interpolation's own error is under -100 dB at
// that density). When the read step is above 1 (a pitched-up sound, or a
// source at a higher rate) the kernel is stretched by the step, so what the
// output cannot hold is filtered out before it can alias.

SINC_HALF :: 32 // taps each side of the read position at step <= 1
SINC_RES :: 1024 // table points per source sample
SINC_BETA :: 10.06 // Kaiser beta for 100 dB
SINC_CUTOFF :: 0.9 // of Nyquist: the pass-band ends near 0.4 of the rate, the stop-band begins at Nyquist
SINC_MAX_STEP :: 8 // the widest stretch (a step above this is clamped)

Sinc_Table :: struct {
	k:    [SINC_HALF * SINC_RES + 2]f32, // kernel for u in [0, SINC_HALF], in source samples
	// The same kernel by phase, for reading at a step of 1 or less: row p holds
	// the 2 * SINC_HALF taps for a position p / SINC_RES past a sample, taps
	// from sample - (SINC_HALF - 1) on, so a read is a dot product over one
	// run of samples and two rows.
	poly: [SINC_RES + 1][2 * SINC_HALF]f32,
}

// bessel_i0: the modified Bessel function of order 0 (series).
bessel_i0 :: proc "contextless" (x: f64) -> f64 {
	sum, term := 1.0, 1.0
	q := x * x / 4
	for k in 1 ..< 60 {
		term *= q / f64(k * k)
		sum += term
		if term < 1e-18 * sum {break}
	}
	return sum
}

// kaiser: the window at u in [-1, 1].
kaiser :: proc "contextless" (u, beta: f64) -> f64 {
	if abs(u) >= 1 {return 0}
	return bessel_i0(beta * math.sqrt(1 - u * u)) / bessel_i0(beta)
}

sinc_table_init :: proc "contextless" (t: ^Sinc_Table) {
	for i in 0 ..< len(t.k) {
		u := f64(i) / SINC_RES
		x := math.PI * SINC_CUTOFF * u
		s := 1.0 if u == 0 else math.sin(x) / x
		t.k[i] = f32(SINC_CUTOFF * s * kaiser(u / SINC_HALF, SINC_BETA))
	}
	for p in 0 ..= SINC_RES {
		for j in 0 ..< 2 * SINC_HALF {
			m := j - (SINC_HALF - 1)
			at := abs(m * SINC_RES - p)
			t.poly[p][j] = t.k[at] if at < SINC_HALF * SINC_RES else 0
		}
	}
}

// sinc_fast: sinc_read at a step of 1 or less, for a position whose taps all
// lie inside `s` (SINC_HALF - 1 <= int(pos) and int(pos) + SINC_HALF <
// len(s)): the phase rows on either side of pos, summed in 8 lanes.
sinc_fast :: proc "contextless" (t: ^Sinc_Table, s: []f32, pos: f64) -> f32 {
	i := int(pos)
	fp := (pos - f64(i)) * SINC_RES
	p := int(fp)
	w := f32(fp - f64(p))
	x := ([^]f32)(&s[i - (SINC_HALF - 1)])
	a := &t.poly[p]
	b := &t.poly[p + 1]
	sa, sb: #simd[8]f32
	for j := 0; j < 2 * SINC_HALF; j += 8 {
		v := intrinsics.unaligned_load((^#simd[8]f32)(&x[j]))
		sa += v * intrinsics.unaligned_load((^#simd[8]f32)(&a[j]))
		sb += v * intrinsics.unaligned_load((^#simd[8]f32)(&b[j]))
	}
	ra := simd.reduce_add_pairs(sa)
	rb := simd.reduce_add_pairs(sb)
	return ra + w * (rb - ra)
}

// sinc_read: the sound `s` at fractional position `pos`, `step` source
// samples per output frame. `loop_len` > 0 wraps the taps inside [0, end) of a
// loop (loop_start..loop_end); otherwise the edges repeat the end samples.
sinc_read :: proc "contextless" (
	t: ^Sinc_Table,
	s: []f32,
	pos: f64,
	step: f64,
	loop_start, loop_end: int,
	looping: bool,
) -> f32 {
	scale := clamp(step, 1, SINC_MAX_STEP)
	half := SINC_HALF * scale
	lo := int(math.ceil(pos - half))
	hi := int(math.floor(pos + half))
	inv := SINC_RES / scale
	last := len(s) - 1
	loop_len := loop_end - loop_start
	sum: f32
	for j in lo ..= hi {
		x := abs(f64(j) - pos) * inv
		i := int(x)
		if i >= SINC_HALF * SINC_RES {continue}
		w := f32(x - f64(i))
		k := t.k[i] + (t.k[i + 1] - t.k[i]) * w
		idx := j
		if looping {
			if idx >= loop_end {idx -= loop_len * ((idx - loop_start) / loop_len)}
			if idx < 0 {idx += loop_len * ((loop_len - 1 - idx) / loop_len)}
		}
		sum += s[clamp(idx, 0, last)] * k
	}
	return sum / f32(scale)
}

// resample_sound converts a sound to another rate, offline (at load: what
// the mixer then plays needs no conversion, and stays on the cheap cubic
// path). The result is allocated.
resample_sound :: proc(s: Sound, rate: u32, allocator := context.allocator) -> Sound {
	if s.rate == rate {
		out := make([]f32, len(s.samples), allocator)
		copy(out, s.samples)
		return {samples = out, rate = rate}
	}
	table := new(Sinc_Table, context.temp_allocator)
	sinc_table_init(table)
	step := f64(s.rate) / f64(rate)
	n := int(f64(len(s.samples)) / step)
	out := make([]f32, n, allocator)
	for i in 0 ..< n {
		out[i] = sinc_read(table, s.samples, f64(i) * step, step, 0, 0, false)
	}
	return {samples = out, rate = rate}
}
