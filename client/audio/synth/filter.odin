package synth

import "base:intrinsics"

import "common:base"

// Filters and small DSP pieces every source shares. Everything is f64 and
// built on base's sin, cos and exp, so a recipe and a seed give the same
// samples on every OS.

RATE :: 48000 // samples per second: effects are made at the device's rate, in float

// Biquad: RBJ cookbook coefficients, transposed direct form II.
Biquad :: struct {
	b0, b1, b2, a1, a2: f64,
	z1, z2:             f64,
}

biquad_run :: #force_inline proc "contextless" (f: ^Biquad, x: f64) -> f64 {
	y := f.b0 * x + f.z1
	f.z1 = f.b1 * x - f.a1 * y + f.z2
	f.z2 = f.b2 * x - f.a2 * y
	return y
}

// biquad_retune takes g's coefficients and keeps f's state (a sweep).
biquad_retune :: proc "contextless" (f: ^Biquad, g: Biquad) {
	f.b0, f.b1, f.b2, f.a1, f.a2 = g.b0, g.b1, g.b2, g.a1, g.a2
}

@(private)
biquad_make :: proc "contextless" (b0, b1, b2, a0, a1, a2: f64) -> Biquad {
	return {b0 = b0 / a0, b1 = b1 / a0, b2 = b2 / a0, a1 = a1 / a0, a2 = a2 / a0}
}

// angle is the normalized frequency 2*pi*f/RATE, kept under Nyquist.
@(private)
angle :: proc "contextless" (freq: f64) -> f64 {
	return 2 * PI * clamp(freq, 1, 0.45 * RATE) / RATE
}

PI :: 3.14159265358979323846264338327950288

lowpass :: proc "contextless" (freq, q: f64) -> Biquad {
	w := angle(freq)
	s, c := base.sincos(w)
	alpha := s / (2 * q)
	return biquad_make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
}

highpass :: proc "contextless" (freq, q: f64) -> Biquad {
	w := angle(freq)
	s, c := base.sincos(w)
	alpha := s / (2 * q)
	return biquad_make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
}

// bandpass: unity gain at freq; a higher q is narrower and rings longer.
bandpass :: proc "contextless" (freq, q: f64) -> Biquad {
	w := angle(freq)
	s, c := base.sincos(w)
	alpha := s / (2 * q)
	return biquad_make(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)
}

peaking :: proc "contextless" (freq, q, gain_db: f64) -> Biquad {
	w := angle(freq)
	s, c := base.sincos(w)
	a := from_db_amp(gain_db / 2)
	alpha := s / (2 * q)
	return biquad_make(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
}

low_shelf :: proc "contextless" (freq, gain_db: f64) -> Biquad {
	return shelf(freq, gain_db, false)
}

high_shelf :: proc "contextless" (freq, gain_db: f64) -> Biquad {
	return shelf(freq, gain_db, true)
}

@(private = "file")
shelf :: proc "contextless" (freq, gain_db: f64, high: bool) -> Biquad {
	w := angle(freq)
	s, c := base.sincos(w)
	a := from_db_amp(gain_db / 2)
	alpha := s / 2 * SQRT2 // shelf slope 1
	r := 2 * sqrt(a) * alpha
	if high {
		return biquad_make(
			a * ((a + 1) + (a - 1) * c + r),
			-2 * a * ((a - 1) + (a + 1) * c),
			a * ((a + 1) + (a - 1) * c - r),
			(a + 1) - (a - 1) * c + r,
			2 * ((a - 1) - (a + 1) * c),
			(a + 1) - (a - 1) * c - r,
		)
	}
	return biquad_make(
		a * ((a + 1) - (a - 1) * c + r),
		2 * a * ((a - 1) - (a + 1) * c),
		a * ((a + 1) - (a - 1) * c - r),
		(a + 1) + (a - 1) * c + r,
		-2 * ((a - 1) + (a + 1) * c),
		(a + 1) + (a - 1) * c - r,
	)
}

SQRT2 :: 1.41421356237309504880168872420969808

// sqrt is IEEE correctly rounded on every OS.
@(private)
sqrt :: proc "contextless" (x: f64) -> f64 {
	return intrinsics.sqrt(x)
}

// from_db_amp: 10^(db/20), through base.exp.
from_db_amp :: proc "contextless" (db: f64) -> f64 {
	return base.exp(db * LN10_OVER_20)
}

LN10_OVER_20 :: 0.11512925464970228420089957273422

// hann is the Hann window at position u in [0, 1].
hann :: proc "contextless" (u: f64) -> f64 {
	return 0.5 - 0.5 * base.cos(2 * PI * u)
}

// noise_white: uniform in [-1, 1).
noise_white :: #force_inline proc "contextless" (r: ^base.Rng) -> f64 {
	return 2 * base.rng_f64(r) - 1
}

// Noise colour state: pink is Kellet's economy filter, brown a leaky
// integrator (both scaled to peak near 1).
Noise_Color :: enum u8 {
	White,
	Pink,
	Brown,
}

Noise_State :: struct {
	b:     [3]f64,
	brown: f64,
}

noise_next :: proc "contextless" (s: ^Noise_State, r: ^base.Rng, c: Noise_Color) -> f64 {
	w := noise_white(r)
	switch c {
	case .White:
		return w
	case .Pink:
		s.b[0] = 0.99765 * s.b[0] + w * 0.0990460
		s.b[1] = 0.96300 * s.b[1] + w * 0.2965164
		s.b[2] = 0.57000 * s.b[2] + w * 1.0526913
		return 0.25 * (s.b[0] + s.b[1] + s.b[2] + w * 0.1848)
	case .Brown:
		s.brown = (s.brown + 0.02 * w) / 1.02
		return s.brown * 3.5
	}
	return 0
}
