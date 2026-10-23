package sfx

import "core:math"

import "../../game"

// Sound effects, synthesized: no recordings. Each sound is a few layers of
// filtered noise bursts and decaying tones, made at a low rate and crushed
// to 8 bits, so it is gritty the way the textures are crunchy. A material
// has a recipe (a resonant clack for stone, a low crumble for dirt, a hiss
// of grains for sand...); breaking, placing and stepping play it bigger or
// smaller. Variants come from different seeds; the game adds random pitch.
//
//	samples := sfx.block_sound(.Stone, .Break, variant = 0, allocator)
//	audio.add_sound(&mixer, {samples, sfx.RATE})

RATE :: 16000 // samples per second
VARIANTS :: 3 // of every sound
BITS :: 8 // samples are crushed to this many bits

Material :: enum u8 {
	Stone,
	Dirt,
	Grass,
	Sand,
	Gravel,
	Glass,
}

Action :: enum u8 {
	Break,
	Place,
	Step,
}

Player_Sound :: enum u8 {
	Land,
}

// material_of: what a block sounds like; false for air.
material_of :: proc(b: game.Block) -> (Material, bool) {
	switch b {
	case .Air:
		return {}, false
	case .Stone, .Bedrock:
		return .Stone, true
	case .Dirt:
		return .Dirt, true
	case .Grass:
		return .Grass, true
	case .Sand:
		return .Sand, true
	case .Gravel:
		return .Gravel, true
	case .Lamp:
		return .Glass, true
	}
	return {}, false
}

// Breaking is the full sound; placing a shorter, fuller thunk; a step a
// small part of it: how long the layers ring, how many grains, how loud.
@(private = "file", rodata)
ACTION_SIZE := [Action]f32 {
	.Break = 1,
	.Place = 0.75,
	.Step  = 0.5,
}
@(private = "file", rodata)
ACTION_GRAINS := [Action]f32 {
	.Break = 1,
	.Place = 0.3,
	.Step  = 0.15,
}
@(private = "file", rodata)
ACTION_PEAK := [Action]f32 {
	.Break = 0.9,
	.Place = 0.8,
	.Step  = 0.45,
}

// block_sound makes a material's sound for an action.
block_sound :: proc(
	m: Material,
	a: Action,
	variant: int,
	allocator := context.allocator,
) -> []f32 {
	s := Synth {
		rng = seed(u32(m) * 977 + u32(a) * 131 + u32(variant) * 7 + 1),
	}
	size, grains, peak := ACTION_SIZE[a], ACTION_GRAINS[a], ACTION_PEAK[a]
	r := rand_range(&s.rng, 0.92, 1.08) // each variant a little higher or lower
	switch m {
	case .Stone:
		f := rand_range(&s.rng, 1500, 2000) * r
		burst(&s, {start = 0, tau = 0.018 * size, filter = .Band, freq = f, q = 5, gain = 1})
		burst(
			&s,
			{start = 0, tau = 0.030 * size, filter = .Band, freq = f * 1.73, q = 8, gain = 0.5},
		)
		burst(&s, {start = 0, tau = 0.040 * size, filter = .Low, freq = 220 * r, gain = 0.7})
		scatter(
			&s,
			int(5 * grains),
			0.02,
			0.15,
			{tau = 0.006, filter = .Band, q = 3},
			2500,
			4500,
			0.2,
			0.45,
		)
	case .Dirt:
		burst(&s, {start = 0, tau = 0.060 * size, filter = .Low, freq = 600 * r, gain = 1})
		burst(&s, {start = 0, tau = 0.050 * size, filter = .Low, freq = 160 * r, gain = 0.8})
		scatter(
			&s,
			int(8 * grains + 0.5),
			0.01,
			0.18,
			{tau = 0.015, filter = .Band, q = 1.5},
			250,
			900,
			0.25,
			0.55,
		)
	case .Grass:
		burst(&s, {start = 0, tau = 0.050 * size, filter = .Low, freq = 650 * r, gain = 0.8})
		burst(&s, {start = 0, tau = 0.045 * size, filter = .Low, freq = 170 * r, gain = 0.6})
		burst(&s, {start = 0.005, tau = 0.040 * size, filter = .High, freq = 2500, gain = 0.3})
		scatter(
			&s,
			int(8 * grains + 0.5),
			0.0,
			0.18,
			{tau = 0.008, filter = .Band, q = 1},
			3000,
			6000,
			0.15,
			0.35,
		)
	case .Sand:
		burst(&s, {start = 0, tau = 0.050 * size, filter = .Low, freq = 900 * r, gain = 0.45})
		scatter(
			&s,
			int(28 * grains + 1),
			0.0,
			0.2 * size,
			{tau = 0.007, filter = .Band, q = 0.8},
			1500,
			4000,
			0.15,
			0.35,
		)
	case .Gravel:
		burst(&s, {start = 0, tau = 0.040 * size, filter = .Low, freq = 250 * r, gain = 0.7})
		scatter(
			&s,
			int(16 * grains + 1),
			0.0,
			0.16 * size,
			{tau = 0.005, filter = .Band, q = 2.5},
			900,
			2600,
			0.3,
			0.75,
		)
	case .Glass:
		// A brittle clink: short inharmonic partials (no two in tune), a
		// tick, then shards.
		for ratio, i in ([?]f32{1, 1.47, 2.09, 2.56, 3.31}) {
			tone(&s, 1900 * r * ratio, (0.055 - 0.008 * f32(i)) * size, 1 / (1 + 0.4 * f32(i)))
		}
		burst(&s, {start = 0, tau = 0.003, filter = .High, freq = 4000, gain = 0.8})
		scatter(
			&s,
			int(9 * grains),
			0.01,
			0.16 * size,
			{tau = 0.010, filter = .Band, q = 6},
			3500,
			7000,
			0.25,
			0.5,
		)
	}
	return finish(&s, peak, allocator)
}

// player_sound: the player's own noises (no jump: heard every few seconds,
// it would grate). A landing is made once, loud; the
// game scales it with how hard they landed.
player_sound :: proc(p: Player_Sound, variant: int, allocator := context.allocator) -> []f32 {
	s := Synth {
		rng = seed(9132 + u32(p) * 131 + u32(variant) * 7),
	}
	r := rand_range(&s.rng, 0.92, 1.08)
	switch p {
	case .Land:
		burst(&s, {start = 0, tau = 0.070, filter = .Low, freq = 140 * r, gain = 1})
		burst(&s, {start = 0, tau = 0.030, filter = .Low, freq = 420 * r, gain = 0.6})
		scatter(&s, 3, 0.005, 0.05, {tau = 0.01, filter = .Band, q = 1.5}, 300, 800, 0.2, 0.3)
		return finish(&s, 0.85, allocator)
	}
	return nil
}

// --- Synthesis -------------------------------------------------------------

MAX_SECONDS :: 1

@(private)
Synth :: struct {
	buf: [RATE * MAX_SECONDS]f32,
	len: int, // samples used so far
	rng: u32,
}

@(private)
Filter :: enum u8 {
	None,
	Low,
	High,
	Band,
}

// Burst: noise, sharply on, decaying (time constant tau), filtered.
@(private)
Burst :: struct {
	start:  f32, // seconds
	tau:    f32, // seconds: the envelope falls by e every tau
	filter: Filter,
	freq:   f32, // Hz: cutoff, or band centre
	q:      f32, // band sharpness
	gain:   f32,
}

@(private)
burst :: proc(s: ^Synth, b: Burst) {
	n := min(int((b.start + 6 * b.tau) * RATE), len(s.buf))
	first := int(b.start * RATE)
	f: Biquad
	switch b.filter {
	case .None:
	case .Low:
		f = lowpass(b.freq)
	case .High:
		f = highpass(b.freq)
	case .Band:
		f = bandpass(b.freq, b.q)
	}
	attack := f32(0.0015) // a millisecond and a half: sharp, not clicking
	for i in first ..< n {
		t := f32(i - first) / RATE
		env := min(t / attack, 1) * math.exp(-t / b.tau)
		x := rand_range(&s.rng, -1, 1)
		if b.filter != .None {x = biquad(&f, x)}
		s.buf[i] += x * env * b.gain
	}
	s.len = max(s.len, n)
}

// scatter: count small bursts (grains) at random times between from and to
// seconds, each at a random frequency and gain in the ranges given.
@(private)
scatter :: proc(
	s: ^Synth,
	count: int,
	from, to: f32,
	grain: Burst,
	freq_lo, freq_hi: f32,
	gain_lo, gain_hi: f32,
) {
	for _ in 0 ..< count {
		g := grain
		g.start = rand_range(&s.rng, from, to)
		g.freq = rand_range(&s.rng, freq_lo, freq_hi)
		g.gain = rand_range(&s.rng, gain_lo, gain_hi)
		burst(s, g)
	}
}

// tone: a sine that rings down (glass, metal).
@(private)
tone :: proc(s: ^Synth, freq, tau, gain: f32) {
	n := min(int(6 * tau * RATE), len(s.buf))
	phase := rand_range(&s.rng, 0, math.TAU)
	for i in 0 ..< n {
		t := f32(i) / RATE
		s.buf[i] += math.sin(phase + math.TAU * freq * t) * math.exp(-t / tau) * gain
	}
	s.len = max(s.len, n)
}

// finish scales the sound to peak, fades its last milliseconds and crushes
// it to BITS bits; the result is a copy.
@(private)
finish :: proc(s: ^Synth, peak: f32, allocator := context.allocator) -> []f32 {
	out := make([]f32, s.len, allocator)
	loudest: f32
	for x in s.buf[:s.len] {loudest = max(loudest, abs(x))}
	scale := peak / loudest if loudest > 0 else 0
	fade := min(RATE / 200, s.len) // 5 ms
	levels := f32(int(1) << (BITS - 1) - 1)
	for x, i in s.buf[:s.len] {
		y := x * scale
		if i >= s.len - fade {y *= f32(s.len - i) / f32(fade)}
		out[i] = math.round(y * levels) / levels
	}
	return out
}

// Biquad filters (RBJ cookbook), direct form I.
@(private)
Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	x1, x2, y1, y2:     f32,
}

@(private)
biquad :: proc(f: ^Biquad, x: f32) -> f32 {
	y := f.b0 * x + f.b1 * f.x1 + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2
	f.x2, f.x1 = f.x1, x
	f.y2, f.y1 = f.y1, y
	return y
}

@(private)
lowpass :: proc(freq: f32) -> Biquad {
	w := math.TAU * min(freq, RATE * 0.45) / RATE
	alpha := math.sin(w) / (2 * math.SQRT_TWO / 2) // Q = 1/√2
	c := math.cos(w)
	a0 := 1 + alpha
	return {
		b0 = (1 - c) / 2 / a0,
		b1 = (1 - c) / a0,
		b2 = (1 - c) / 2 / a0,
		a1 = -2 * c / a0,
		a2 = (1 - alpha) / a0,
	}
}

@(private)
highpass :: proc(freq: f32) -> Biquad {
	w := math.TAU * min(freq, RATE * 0.45) / RATE
	alpha := math.sin(w) / (2 * math.SQRT_TWO / 2)
	c := math.cos(w)
	a0 := 1 + alpha
	return {
		b0 = (1 + c) / 2 / a0,
		b1 = -(1 + c) / a0,
		b2 = (1 + c) / 2 / a0,
		a1 = -2 * c / a0,
		a2 = (1 - alpha) / a0,
	}
}

// bandpass: unity gain at freq; higher q is narrower and rings longer.
@(private)
bandpass :: proc(freq, q: f32) -> Biquad {
	w := math.TAU * min(freq, RATE * 0.45) / RATE
	alpha := math.sin(w) / (2 * q)
	c := math.cos(w)
	a0 := 1 + alpha
	return {b0 = alpha / a0, b1 = 0, b2 = -alpha / a0, a1 = -2 * c / a0, a2 = (1 - alpha) / a0}
}

// A small deterministic generator (xorshift32): the same sounds every run.
@(private)
seed :: proc(n: u32) -> u32 {
	x := n * 0x9e3779b9 + 0x6d2b79f5
	return x if x != 0 else 1
}

@(private)
rand_range :: proc(state: ^u32, lo, hi: f32) -> f32 {
	x := state^
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	state^ = x
	return lo + (hi - lo) * f32(x >> 8) / f32(1 << 24)
}
