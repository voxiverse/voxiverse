package synth

import "common:base"

// Formant synthesis: a glottal pulse train (a Rosenberg pulse) or noise
// through three band-pass formants that glide between vowel targets, with a
// pitch contour, vibrato, jitter (random period) and shimmer (random
// amplitude). A voice: a sheep's bleat, a creature's grunt.

Vowel :: enum u8 {
	A,
	E,
	I,
	O,
	U,
	Bleat,
}

// VOWELS: the three formant frequencies, Hz.
VOWELS :: [Vowel][3]f64 {
	.A     = {800, 1150, 2900},
	.E     = {400, 1600, 2700},
	.I     = {300, 2300, 3000},
	.O     = {450, 800, 2830},
	.U     = {325, 700, 2530},
	.Bleat = {900, 2400, 3400},
}

FORMANT_Q :: [3]f64{8, 10, 12}
FORMANT_GAIN :: [3]f64{1, 0.6, 0.3}

Formant_Params :: struct {
	pitch_from, pitch_to: f64, // Hz
	vowel_from, vowel_to: Vowel,
	vibrato_rate:         f64, // Hz
	vibrato_cents:        f64,
	jitter:               f64, // 0..1 of 2%
	shimmer:              f64, // 0..1 of 3 dB
	breath:               f64, // 0..1: noise mixed in (1: only noise)
}

// rosenberg: one glottal period at phase u in [0, 1): a rising half
// cosine, a quick fall, then closed.
@(private)
rosenberg :: proc "contextless" (u: f64) -> f64 {
	OPEN :: 0.6
	CLOSE :: 0.2
	switch {
	case u < OPEN:
		return 0.5 * (1 - base.cos(PI * u / OPEN))
	case u < OPEN + CLOSE:
		return base.cos(PI / 2 * (u - OPEN) / CLOSE)
	}
	return 0
}

// formant_render writes the voice into out (all of it), at pitch ratio `pitch`.
formant_render :: proc(out: []f64, p: Formant_Params, rng: ^base.Rng, pitch: f64) {
	vowels := VOWELS
	q := FORMANT_Q
	fg := FORMANT_GAIN
	from, to := vowels[p.vowel_from], vowels[p.vowel_to]
	filters: [3]Biquad
	n := len(out)
	phase: f64
	period_scale := 1.0
	amp := 1.0
	noise_amp: Noise_State
	prev: f64 // the glottal pulse's DC is removed by differencing
	for i in 0 ..< n {
		u := f64(i) / f64(max(n - 1, 1))
		if i % 16 == 0 {
			for k in 0 ..< 3 {
				biquad_retune(&filters[k], bandpass(from[k] + (to[k] - from[k]) * u, q[k]))
			}
		}
		t := f64(i) / RATE
		cents := p.vibrato_cents * base.sin(2 * PI * p.vibrato_rate * t)
		f0 := (p.pitch_from + (p.pitch_to - p.pitch_from) * u) * pitch
		f0 *= base.exp(cents * LN2 / 1200) / period_scale
		phase += f0 / RATE
		if phase >= 1 {
			phase -= 1
			// A new period: draw its jitter and shimmer.
			period_scale = 1 + p.jitter * 0.02 * (2 * base.rng_f64(rng) - 1)
			amp = from_db_amp(p.shimmer * 3 * (2 * base.rng_f64(rng) - 1))
		}
		g := rosenberg(phase)
		glottal := (g - prev) * 30 // the derivative: the lips' radiation
		prev = g
		src := glottal * amp * (1 - p.breath) + noise_next(&noise_amp, rng, .White) * p.breath
		sum: f64
		for k in 0 ..< 3 {sum += biquad_run(&filters[k], src) * fg[k]}
		out[i] = sum
	}
}
