package sfx

import "core:math"

import "../../common/game"

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
	Wood,
	Snow,
}

Action :: enum u8 {
	Break,
	Place,
	Step,
}

Player_Sound :: enum u8 {
	Land,
}

Blast_Sound :: enum u8 {
	Launch, // a rocket leaving: a rising hiss
	Boom, // an explosion: a deep thump, a rumble, crackle
}

Gun_Sound :: enum u8 {
	Pistol, // a sharp crack and a short thump
	Rifle, // a tighter, higher crack
	Sniper, // a heavy boom with a long tail
	Hit, // the hit marker's tick
	Headshot, // ... and its brighter ring
	Reload, // two clicks
}

Sheep_Sound :: enum u8 {
	Hurt, // a short bleat
	Die, // a long, falling one, and a puff
}

// material_of: what a block sounds like, from its sound set in the registry;
// false for none (air, water).
material_of :: proc(reg: ^game.Registry, b: game.Block) -> (Material, bool) {
	sound := reg.blocks.defs[b].sound
	if sound == game.NO_SOUND {return {}, false}
	return Material(reg.sounds[sound].material), true
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
	case .Wood:
		// A hollow knock: two body resonances, a tap, then a splinter or two.
		tone(&s, 310 * r, 0.060 * size, 1)
		tone(&s, 740 * r, 0.035 * size, 0.55)
		burst(
			&s,
			{start = 0, tau = 0.012 * size, filter = .Band, freq = 1200 * r, q = 2, gain = 0.6},
		)
		scatter(
			&s,
			int(3 * grains),
			0.01,
			0.10 * size,
			{tau = 0.006, filter = .Band, q = 4},
			1800,
			3200,
			0.15,
			0.3,
		)
	case .Snow:
		// A muffled crunch: soft grains under a low thump, no highs.
		burst(&s, {start = 0, tau = 0.045 * size, filter = .Low, freq = 500 * r, gain = 0.7})
		scatter(
			&s,
			int(22 * grains + 1),
			0.0,
			0.18 * size,
			{tau = 0.010, filter = .Low},
			600,
			1400,
			0.2,
			0.4,
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

// sheep_sound: a sheep's voice, a bleat: a sliding pitch with vibrato
// whose harmonics are shaped by two formants (no filters: each harmonic's
// loudness is the formants' at its frequency).
sheep_sound :: proc(c: Sheep_Sound, variant: int, allocator := context.allocator) -> []f32 {
	s := Synth {
		rng = seed(7777 + u32(c) * 131 + u32(variant) * 7),
	}
	r := rand_range(&s.rng, 0.9, 1.1)
	switch c {
	case .Hurt:
		bleat(&s, 0.26, 560 * r, 430 * r, 1)
		burst(&s, {start = 0, tau = 0.012, filter = .Band, freq = 1400, q = 1, gain = 0.25})
	case .Die:
		bleat(&s, 0.5, 470 * r, 250 * r, 1)
		burst(&s, {start = 0.38, tau = 0.06, filter = .Low, freq = 900, gain = 0.5})
	}
	return finish(&s, 0.7, allocator)
}

// gun_sound: the hitscan weapons' sounds and their feedback's.
gun_sound :: proc(x: Gun_Sound, variant: int, allocator := context.allocator) -> []f32 {
	s := Synth {
		rng = seed(5150 + u32(x) * 131 + u32(variant) * 7),
	}
	r := rand_range(&s.rng, 0.94, 1.06)
	switch x {
	case .Pistol:
		burst(&s, {start = 0, tau = 0.010, filter = .Band, freq = 1900 * r, q = 0.8, gain = 1})
		burst(&s, {start = 0, tau = 0.045, filter = .Low, freq = 240 * r, gain = 0.9})
		scatter(&s, 8, 0.01, 0.12, {tau = 0.01, filter = .Band, q = 1.2}, 700, 2600, 0.08, 0.3)
	case .Rifle:
		burst(&s, {start = 0, tau = 0.008, filter = .Band, freq = 2600 * r, q = 0.8, gain = 1})
		burst(&s, {start = 0, tau = 0.030, filter = .Low, freq = 320 * r, gain = 0.8})
		scatter(&s, 6, 0.005, 0.08, {tau = 0.008, filter = .Band, q = 1.2}, 1200, 3200, 0.06, 0.25)
	case .Sniper:
		burst(&s, {start = 0, tau = 0.014, filter = .Band, freq = 1300 * r, q = 0.7, gain = 1})
		burst(&s, {start = 0, tau = 0.120, filter = .Low, freq = 130 * r, gain = 1})
		burst(&s, {start = 0.02, tau = 0.200, filter = .Low, freq = 70 * r, gain = 0.6})
		scatter(&s, 24, 0.04, 0.6, {tau = 0.02, filter = .Band, q = 1.5}, 300, 1800, 0.05, 0.25)
	case .Hit:
		burst(&s, {start = 0, tau = 0.008, filter = .Band, freq = 2800 * r, q = 4, gain = 1})
	case .Headshot:
		burst(&s, {start = 0, tau = 0.012, filter = .Band, freq = 3400 * r, q = 6, gain = 1})
		burst(&s, {start = 0.03, tau = 0.020, filter = .Band, freq = 5100 * r, q = 6, gain = 0.8})
	case .Reload:
		burst(&s, {start = 0, tau = 0.010, filter = .Band, freq = 1500 * r, q = 3, gain = 0.9})
		burst(&s, {start = 0, tau = 0.030, filter = .Low, freq = 400 * r, gain = 0.5})
		burst(&s, {start = 0.18, tau = 0.012, filter = .Band, freq = 2100 * r, q = 3, gain = 1})
		burst(&s, {start = 0.18, tau = 0.040, filter = .Low, freq = 300 * r, gain = 0.6})
	}
	return finish(&s, 0.9, allocator)
}

// blast_sound: the rocket launcher's sounds.
blast_sound :: proc(x: Blast_Sound, variant: int, allocator := context.allocator) -> []f32 {
	s := Synth {
		rng = seed(4242 + u32(x) * 131 + u32(variant) * 7),
	}
	r := rand_range(&s.rng, 0.9, 1.1)
	switch x {
	case .Launch:
		burst(&s, {start = 0, tau = 0.02, filter = .Low, freq = 300 * r, gain = 0.8})
		hiss(&s, 0.35, 900 * r, 3500 * r, 0.6)
	case .Boom:
		burst(&s, {start = 0, tau = 0.09, filter = .Low, freq = 90 * r, gain = 1})
		burst(&s, {start = 0, tau = 0.14, filter = .Low, freq = 220 * r, gain = 0.8})
		burst(&s, {start = 0.01, tau = 0.12, filter = .Band, freq = 700 * r, q = 0.7, gain = 0.4})
		scatter(&s, 30, 0.03, 0.5, {tau = 0.012, filter = .Band, q = 1.5}, 400, 2500, 0.1, 0.35)
	}
	return finish(&s, 0.95, allocator)
}

// --- Synthesis -------------------------------------------------------------

// hiss: noise through a band rising from lo to hi Hz over seconds, fading.
@(private)
hiss :: proc(s: ^Synth, seconds, lo, hi, gain: f32) {
	n := min(int(seconds * RATE), len(s.buf))
	f := bandpass(lo, 1.2)
	for i in 0 ..< n {
		u := f32(i) / f32(n)
		if i % 32 == 0 {
			g := bandpass(lo + (hi - lo) * u, 1.2)
			f.b0, f.b1, f.b2, f.a1, f.a2 = g.b0, g.b1, g.b2, g.a1, g.a2
		}
		env := min(u / 0.05, 1) * (1 - u) * (1 - u)
		s.buf[i] += biquad(&f, rand_range(&s.rng, -1, 1)) * env * gain
	}
	s.len = max(s.len, n)
}

// bleat: a voiced sound from from_hz to to_hz over seconds.
@(private)
bleat :: proc(s: ^Synth, seconds, from_hz, to_hz, gain: f32) {
	n := min(int(seconds * RATE), len(s.buf))
	FORMANTS :: [2][3]f32{{900, 320, 1}, {2400, 500, 0.5}} // centre, width, height
	phase: f32
	for i in 0 ..< n {
		u := f32(i) / f32(n)
		f0 := from_hz + (to_hz - from_hz) * u
		f0 *= 1 + 0.035 * math.sin(math.TAU * 7 * f32(i) / RATE) // vibrato
		phase += f0 / RATE
		x: f32
		for k in 1 ..= 12 {
			hz := f0 * f32(k)
			if hz > RATE * 0.45 {break}
			amp: f32
			for fm in FORMANTS {amp += fm[2] * math.exp(-((hz - fm[0]) / fm[1]) * ((hz - fm[0]) / fm[1]))}
			x += amp * math.sin(math.TAU * phase * f32(k)) / f32(k)
		}
		env := min(u / 0.08, 1) * (1 - u) * (1 - u * 0.3)
		s.buf[i] += x * env * gain
	}
	s.len = max(s.len, n)
}

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
