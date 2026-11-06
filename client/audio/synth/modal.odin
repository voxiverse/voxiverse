package synth

import "common:base"

// Modal synthesis: a bank of damped resonators struck by a short burst, the
// way a struck object rings. Each material is a base frequency and six
// modes (frequency ratio, T60 in seconds, gain in dB).

// Material is the sound-material list (stone ... ice); the block registry's
// sound materials use these names.
Material :: enum u8 {
	Stone,
	Wood,
	Glass,
	Metal,
	Dirt,
	Gravel,
	Sand,
	Wool,
	Leaves,
	Snow,
	Water,
	Ice,
}

MAX_MODES :: 16 // resonators in a bank
TABLE_MODES :: 6 // modes a material defines

Mode :: struct {
	ratio:   f64,
	t60:     f64, // seconds to fall 60 dB
	gain_db: f64,
}

Modes :: struct {
	base:  f64, // Hz
	count: int, // 0: the material has no modes (water: bubbles)
	modes: [TABLE_MODES]Mode,
}

MATERIAL_MODES :: [Material]Modes {
	.Stone  = {
		1700,
		6,
		{
			{1, .035, 0},
			{1.62, .028, -3},
			{2.33, .022, -5},
			{3.1, .016, -8},
			{4.4, .012, -11},
			{5.9, .009, -14},
		},
	},
	.Wood   = {
		420,
		6,
		{
			{1, .06, 0},
			{2.1, .045, -4},
			{3.4, .03, -7},
			{5.2, .02, -10},
			{7.3, .014, -13},
			{9.6, .01, -16},
		},
	},
	.Glass  = {
		2600,
		6,
		{
			{1, .35, 0},
			{1.42, .3, -2},
			{2.37, .22, -4},
			{3.51, .16, -6},
			{4.62, .12, -9},
			{6.24, .09, -12},
		},
	},
	.Metal  = {
		900,
		6,
		{
			{1, .9, 0},
			{2.76, .7, -3},
			{5.40, .5, -6},
			{8.93, .35, -9},
			{13.34, .25, -12},
			{18.64, .18, -15},
		},
	},
	.Dirt   = {
		180,
		6,
		{
			{1, .02, 0},
			{1.9, .016, -4},
			{2.8, .012, -8},
			{4.1, .009, -12},
			{5.5, .007, -15},
			{7.0, .005, -18},
		},
	},
	.Gravel = {
		900,
		6,
		{
			{1, .012, 0},
			{1.35, .010, -3},
			{1.9, .008, -6},
			{2.6, .006, -9},
			{3.5, .005, -12},
			{4.6, .004, -15},
		},
	},
	.Sand   = {
		2500,
		6,
		{
			{1, .006, 0},
			{1.35, .005, -3},
			{1.9, .004, -6},
			{2.6, .003, -9},
			{3.5, .0025, -12},
			{4.6, .002, -15},
		},
	},
	.Wool   = {
		250,
		6,
		{
			{1, .012, 0},
			{1.35, .010, -4},
			{1.9, .008, -8},
			{2.6, .006, -12},
			{3.5, .005, -16},
			{4.6, .004, -20},
		},
	},
	.Leaves = {
		3200,
		6,
		{
			{1, .004, 0},
			{1.35, .0035, -3},
			{1.9, .003, -6},
			{2.6, .0025, -9},
			{3.5, .002, -12},
			{4.6, .0015, -15},
		},
	},
	.Snow   = {
		400,
		6,
		{
			{1, .01, 0},
			{1.35, .008, -3},
			{1.9, .0065, -6},
			{2.6, .005, -9},
			{3.5, .004, -12},
			{4.6, .003, -15},
		},
	},
	.Water  = {600, 0, {}},
	.Ice    = {
		2000,
		6,
		{
			{1, .2, 0},
			{1.38, .17, -2},
			{2.2, .13, -4},
			{3.2, .1, -6},
			{4.3, .08, -9},
			{5.6, .06, -12},
		},
	},
}

// Resonator: a two-pole section y = 2 r cos(w) y1 - r^2 y2 + g x.
Resonator :: struct {
	c1, c2, gain: f64,
	y1, y2:       f64,
}

Bank :: struct {
	count: int,
	res:   [MAX_MODES]Resonator,
}

// bank_add adds a resonator at freq Hz (skipped at or above 0.45 of the
// rate, or when the bank is full), ringing t60 seconds to -60 dB.
bank_add :: proc "contextless" (b: ^Bank, freq, t60, gain: f64) {
	if b.count >= MAX_MODES || freq >= 0.45 * RATE || freq <= 0 {return}
	r := base.exp(-6.907755278982137 / (max(t60, 1e-4) * RATE)) // ln 1000
	s, c := base.sincos(2 * PI * freq / RATE)
	// (1 - r) keeps every mode's response to a unit burst near the same
	// size whatever its decay; s is the usual two-pole normalization.
	b.res[b.count] = {
		c1   = 2 * r * c,
		c2   = -r * r,
		gain = gain * (1 - r) * s,
	}
	b.count += 1
}

bank_run :: proc "contextless" (b: ^Bank, x: f64) -> f64 {
	sum: f64
	for i in 0 ..< b.count {
		r := &b.res[i]
		y := r.c1 * r.y1 + r.c2 * r.y2 + r.gain * x
		r.y2, r.y1 = r.y1, y
		sum += y
	}
	return sum
}

// Modal_Params: what a modal source needs, all resolved for one variant.
Modal_Params :: struct {
	material:   Material,
	hardness:   f64, // 0..1: how bright the strike is
	modes:      int, // how many of the material's modes
	spread:     f64, // ratio on every frequency
	decay:      f64, // ratio on every T60
	brightness: f64, // dB per octave of mode ratio
	length:     f64, // the exciter's length, s
}

// exciter_cutoff: 500 + 15000 * hardness^2 Hz.
exciter_cutoff :: proc "contextless" (hardness: f64) -> f64 {
	return 500 + 15000 * hardness * hardness
}

// modal_bank builds the resonators for a material.
modal_bank :: proc(p: Modal_Params, pitch: f64) -> (b: Bank) {
	m := MATERIAL_MODES
	table := m[p.material]
	for i in 0 ..< min(p.modes, table.count) {
		mode := table.modes[i]
		g := from_db_amp(mode.gain_db + p.brightness * log2_ratio(mode.ratio))
		bank_add(&b, table.base * mode.ratio * p.spread * pitch, mode.t60 * p.decay, g)
	}
	return
}

// log2_ratio: log2 of a ratio at least 1, from the exp we have (Newton on
// 2^y), so it is the same on every OS.
@(private)
log2_ratio :: proc "contextless" (x: f64) -> f64 {
	if x <= 1 {return 0}
	y := 0.0
	for _ in 0 ..< 6 {
		// d/dy 2^y = ln2 * 2^y
		v := base.exp(y * LN2)
		y -= (v - x) / (LN2 * v)
	}
	return y
}

LN2 :: 0.69314718055994530941723212145818

// modal_render rings a bank with the exciter: a raised-cosine burst of
// `length` seconds, low-passed at the hardness's cutoff, and for hardness 1
// a one-sample click on top. Writes n samples into out.
modal_render :: proc(out: []f64, p: Modal_Params, pitch: f64) {
	bank := modal_bank(p, pitch)
	lp := lowpass(exciter_cutoff(p.hardness), 0.7071)
	burst := max(int(p.length * RATE), 1)
	for i in 0 ..< len(out) {
		x: f64
		if i < burst {x = hann(f64(i) / f64(burst)) if burst > 1 else 1}
		if i == 0 && p.hardness >= 1 {x += 1}
		out[i] = bank_run(&bank, biquad_run(&lp, x))
	}
}
