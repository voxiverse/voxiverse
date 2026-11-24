package sfx

import "core:math"

import "common:base"
import "common:game"

// Sound effects, synthesized: no recordings. Each sound is a few layers of
// filtered noise bursts and decaying tones, made at a low rate (nothing above
// 8 kHz) and rounded to 12 bits. A material has a recipe (a dull tap for
// stone, a low crumble for dirt, a soft brush for grass, a hush of grains for
// sand...); breaking, placing and stepping play it bigger or smaller.
// Variants come from different seeds; the game adds random pitch, level and
// brightness to each play (engine/sounds.odin).
//
// What a block sound is held to (measured by `build audiodump -sounds`;
// docs/audio.md): an attack of a few milliseconds, never a click; its energy
// low (a centroid under about 1.2 kHz for the soft materials, under 2 kHz for
// the hard ones, glass alone brighter); a gentle decay; a break a crumble, not
// a crack.
//
//	samples := sfx.block_sound(.Stone, .Break, variant = 0, allocator)
//	audio.add_sound(&mixer, {samples, sfx.RATE})

RATE :: 16000 // samples per second
VARIANTS :: 3 // of every sound
BITS :: 12 // samples are rounded to this many bits

Material :: enum u8 {
	Stone,
	Dirt,
	Grass,
	Sand,
	Gravel,
	Glass,
	Wood,
	Snow,
	Metal,
}

Action :: enum u8 {
	Break,
	Place,
	Step,
}

Player_Sound :: enum u8 {
	Land,
	Made, // something made (a game's crafting done): a soft latch, then two bright rising chimes
}

Blast_Sound :: enum u8 {
	Launch, // a rocket leaving: a rising hiss
	Boom, // an explosion: a deep thump, a rumble, crackle
}

Gate_Sound :: enum u8 {
	Open, // a gate's void gathering: a low swell, rising
}

Gun_Sound :: enum u8 {
	Pistol, // a sharp crack and a short thump
	Rifle, // a tighter, higher crack
	Sniper, // a heavy boom with a long tail
	Hit, // the hit marker's tick
	Headshot, // ... and its brighter ring
	Reload, // two clicks
}

// Creature_Sound: a creature's cry, hurt or dying (in its kind's voice: game.Entity_Voice).
Creature_Sound :: enum u8 {
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
// small part of it: how long the layers ring, how many grains, how loud, and
// how slowly it comes in (a step is a soft footfall, not a hit).
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
@(private = "file", rodata)
ACTION_ATTACK := [Action]f32 {
	.Break = 0.004,
	.Place = 0.004,
	.Step  = 0.007,
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
	s.attack = ACTION_ATTACK[a]
	r := rand_range(&s.rng, 0.92, 1.08) // each variant a little higher or lower
	// A break crumbles: more grains after the hit, falling quieter as they go.
	crumble := a == .Break
	switch m {
	case .Stone:
		// A dull tap: a low body and a muted knock, then a few chips.
		burst(&s, {tau = 0.035 * size, filter = .Low, freq = 320 * r, gain = 1})
		burst(&s, {tau = 0.020 * size, filter = .Band, freq = 900 * r, q = 1.2, gain = 0.6})
		scatter(
			&s,
			int(6 * grains),
			0.03,
			0.16,
			{tau = 0.008, filter = .Band, q = 1.2},
			700,
			1600,
			0.15,
			0.3,
		)
		if crumble {
			burst(&s, {start = 0.03, tau = 0.06, filter = .Low, freq = 220 * r, gain = 0.4})
			scatter(&s, 12, 0.06, 0.3, {tau = 0.012, filter = .Band, q = 1}, 400, 1100, 0.15, 0.35)
		}
	case .Dirt:
		// A low crumble.
		burst(&s, {tau = 0.050 * size, filter = .Low, freq = 450 * r, gain = 1})
		burst(&s, {tau = 0.050 * size, filter = .Low, freq = 150 * r, gain = 0.8})
		scatter(
			&s,
			int(8 * grains + 0.5),
			0.01,
			0.18,
			{tau = 0.015, filter = .Band, q = 1.2},
			250,
			800,
			0.25,
			0.5,
		)
		if crumble {
			scatter(&s, 8, 0.08, 0.28, {tau = 0.018, filter = .Low}, 250, 600, 0.1, 0.25)
		}
	case .Grass:
		// A soft brush: low leafy noise coming in slowly, a few blades.
		s.attack *= 2
		burst(&s, {tau = 0.050 * size, filter = .Low, freq = 900 * r, gain = 0.8})
		burst(&s, {tau = 0.040 * size, filter = .Low, freq = 170 * r, gain = 0.5})
		scatter(
			&s,
			int(10 * grains + 0.5),
			0.0,
			0.18,
			{tau = 0.010, filter = .Band, q = 0.8},
			900,
			2200,
			0.12,
			0.25,
		)
	case .Sand:
		// A hush of grains.
		s.attack *= 1.5
		burst(&s, {tau = 0.050 * size, filter = .Low, freq = 700 * r, gain = 0.5})
		scatter(
			&s,
			int(24 * grains + 1),
			0.0,
			0.2 * size,
			{tau = 0.008, filter = .Band, q = 0.7},
			700,
			2000,
			0.12,
			0.3,
		)
	case .Gravel:
		// Small stones shifting.
		burst(&s, {tau = 0.040 * size, filter = .Low, freq = 250 * r, gain = 0.7})
		scatter(
			&s,
			int(14 * grains + 1),
			0.02,
			0.16 * size,
			{tau = 0.006, filter = .Band, q = 1.5},
			500,
			1500,
			0.2,
			0.45,
		)
		if crumble {
			scatter(
				&s,
				14,
				0.06,
				0.3,
				{tau = 0.008, filter = .Band, q = 1.5},
				400,
				1100,
				0.15,
				0.35,
			)
		}
	case .Glass:
		// A clink: short inharmonic partials (no two in tune), a soft tick, then
		// shards; the brightest of the materials, but no hiss.
		for ratio, i in ([?]f32{1, 1.47, 2.09, 2.56, 3.31}) {
			tone(&s, 1500 * r * ratio, (0.045 - 0.007 * f32(i)) * size, 1 / (1 + 0.5 * f32(i)))
		}
		burst(&s, {tau = 0.003, filter = .Band, freq = 2500, q = 1.5, gain = 0.5})
		scatter(
			&s,
			int(7 * grains),
			0.01,
			0.16 * size,
			{tau = 0.010, filter = .Band, q = 4},
			2500,
			5000,
			0.15,
			0.35,
		)
	case .Wood:
		// A low knock: two body resonances, a soft tap, a splinter or two.
		tone(&s, 200 * r, 0.050 * size, 1)
		tone(&s, 470 * r, 0.030 * size, 0.5)
		burst(&s, {tau = 0.010 * size, filter = .Band, freq = 800 * r, q = 1.5, gain = 0.5})
		scatter(
			&s,
			int(3 * grains),
			0.01,
			0.10 * size,
			{tau = 0.006, filter = .Band, q = 3},
			1200,
			2200,
			0.12,
			0.25,
		)
		if crumble {
			scatter(&s, 5, 0.06, 0.22, {tau = 0.012, filter = .Band, q = 2}, 400, 900, 0.12, 0.25)
		}
	case .Snow:
		// A muffled crunch: soft grains under a low thump, no highs.
		s.attack *= 1.5
		burst(&s, {tau = 0.045 * size, filter = .Low, freq = 450 * r, gain = 0.7})
		scatter(
			&s,
			int(22 * grains + 1),
			0.0,
			0.18 * size,
			{tau = 0.010, filter = .Low},
			500,
			1200,
			0.2,
			0.4,
		)
	case .Metal:
		// A muted plate: a clank of inharmonic partials damped soon, a soft tick.
		for ratio, i in ([?]f32{1, 2.76, 5.4}) {
			tone(&s, 520 * r * ratio, (0.08 - 0.02 * f32(i)) * size, 1 / (1 + 0.8 * f32(i)))
		}
		burst(&s, {tau = 0.004, filter = .Band, freq = 1800 * r, q = 1.5, gain = 0.4})
		burst(&s, {tau = 0.020 * size, filter = .Low, freq = 260 * r, gain = 0.5})
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
		s.attack = 0.004 // a thud, not a slap
		burst(&s, {start = 0, tau = 0.070, filter = .Low, freq = 140 * r, gain = 1})
		burst(&s, {start = 0, tau = 0.030, filter = .Low, freq = 420 * r, gain = 0.6})
		scatter(&s, 3, 0.005, 0.05, {tau = 0.01, filter = .Band, q = 1.5}, 300, 800, 0.2, 0.3)
		return finish(&s, 0.85, allocator)
	case .Made:
		burst(&s, {start = 0, tau = 0.012, filter = .Low, freq = 600 * r, gain = 0.5})
		burst(&s, {start = 0.04, tau = 0.045, filter = .Band, freq = 1180 * r, q = 9, gain = 0.9})
		burst(&s, {start = 0.11, tau = 0.070, filter = .Band, freq = 1770 * r, q = 9, gain = 1})
		return finish(&s, 0.6, allocator)
	}
	return nil
}

// creature_sound: a creature's cry in a voice (none for game.Entity_Voice.None). Each is a
// voice through the formants (bleat: a sliding pitch with vibrato whose harmonics the
// formants shape) at its own pitch and length, with noise for the throat: the sheep's
// bleat, a beast's low growl, a small thing's squeak, the dead's slow groan, a spitter's
// rasps, a person's grunt, a bird's chirps, a shell's clicks, a machine's whir (bands of
// noise sliding up, no voice) and a large thing's long bellow.
creature_sound :: proc(
	voice: game.Entity_Voice,
	c: Creature_Sound,
	variant: int,
	allocator := context.allocator,
) -> []f32 {
	if voice == .None {return nil}
	s := Synth {
		rng = seed(7777 + u32(c) * 131 + u32(variant) * 7 + u32(voice) * 1009),
	}
	r := rand_range(&s.rng, 0.9, 1.1)
	die := c == .Die
	switch voice {
	case .None:
	case .Bleat:
		if die {
			bleat(&s, 0.5, 470 * r, 250 * r, 1)
			burst(&s, {start = 0.38, tau = 0.06, filter = .Low, freq = 900, gain = 0.5})
		} else {
			bleat(&s, 0.26, 560 * r, 430 * r, 1)
			burst(&s, {start = 0, tau = 0.012, filter = .Band, freq = 1400, q = 1, gain = 0.25})
		}
	case .Growl:
		bleat(&s, 0.7 if die else 0.32, 150 * r, (70 if die else 120) * r, 1)
		scatter(
			&s,
			14 if die else 6,
			0,
			0.6 if die else 0.28,
			{tau = 0.02, filter = .Low, q = 1},
			180,
			420,
			0.3,
			0.6,
		)
	case .Squeak:
		bleat(&s, 0.3 if die else 0.12, 1500 * r, (900 if die else 1900) * r, 1)
	case .Groan:
		bleat(&s, 0.8 if die else 0.55, 210 * r, (110 if die else 160) * r, 1)
		burst(
			&s,
			{start = 0, tau = 0.1 if die else 0.06, filter = .Band, freq = 500, q = 1, gain = 0.3},
		)
	case .Croak:
		rasps := 4 if die else 2
		for k in 0 ..< rasps {
			burst(
				&s,
				{
					start = f32(k) * 0.11,
					tau = 0.03,
					filter = .Band,
					freq = 380 * r,
					q = 3,
					gain = 1 - 0.15 * f32(k),
				},
			)
		}
	case .Grunt:
		bleat(&s, 0.45 if die else 0.16, 240 * r, (130 if die else 190) * r, 1)
		burst(&s, {start = 0, tau = 0.02, filter = .Low, freq = 700, gain = 0.3})
	case .Chirp:
		chirps := 3 if die else 2
		for k in 0 ..< chirps {
			from := (2600 - 300 * f32(k)) * r
			bleat(&s, 0.07, from, from * (0.6 if die else 1.3), 0.8 - 0.15 * f32(k))
			burst(
				&s,
				{
					start = f32(k) * 0.09,
					tau = 0.012,
					filter = .Band,
					freq = 3200 * r,
					q = 4,
					gain = 0.3,
				},
			)
		}
	case .Chitter:
		clicks := 9 if die else 5
		for k in 0 ..< clicks {
			burst(
				&s,
				{
					start = f32(k) * 0.045,
					tau = 0.006,
					filter = .Band,
					freq = (1800 + 260 * f32(k % 3)) * r,
					q = 5,
					gain = 1 - 0.07 * f32(k),
				},
			)
		}
	case .Whir:
		steps := 8 if die else 5
		for k in 0 ..< steps {
			u := f32(k) / f32(steps)
			hz := (420 + 900 * (1 - u if die else u)) * r
			burst(&s, {start = u * 0.35, tau = 0.03, filter = .Band, freq = hz, q = 8, gain = 0.7})
		}
		burst(&s, {start = 0, tau = 0.08, filter = .Low, freq = 160 * r, gain = 0.4})
	case .Bellow:
		bleat(&s, 0.9 if die else 0.6, 95 * r, (55 if die else 80) * r, 1)
		burst(&s, {start = 0, tau = 0.15, filter = .Low, freq = 220 * r, gain = 0.4})
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

// gate_sound: a gate's sounds.
gate_sound :: proc(x: Gate_Sound, variant: int, allocator := context.allocator) -> []f32 {
	s := Synth {
		rng = seed(5150 + u32(x) * 131 + u32(variant) * 7),
	}
	r := rand_range(&s.rng, 0.95, 1.05)
	switch x {
	case .Open:
		swell(&s, 0.9, 70 * r, 140 * r, 1)
	}
	return finish(&s, 0.8, allocator)
}

// --- Synthesis -------------------------------------------------------------

// swell: a low tone with a fifth above it and a band of noise round them,
// all rising from lo to hi Hz over seconds and growing louder until a short
// fall at the end.
@(private)
swell :: proc(s: ^Synth, seconds, lo, hi, gain: f32) {
	n := min(int(seconds * RATE), len(s.buf))
	f := bandpass(lo * 4, 0.8)
	phase: f32
	for i in 0 ..< n {
		u := f32(i) / f32(n)
		hz := lo * math.pow(hi / lo, u)
		if i % 32 == 0 {
			g := bandpass(hz * 4, 0.8)
			f.b0, f.b1, f.b2, f.a1, f.a2 = g.b0, g.b1, g.b2, g.a1, g.a2
		}
		phase += hz / RATE
		voice := 0.6 * math.sin(math.TAU * phase) + 0.25 * math.sin(math.TAU * phase * 1.5)
		air := biquad(&f, rand_range(&s.rng, -1, 1))
		env := u * u * min((1 - u) / 0.15, 1)
		s.buf[i] += (voice + 0.9 * air) * env * gain
	}
	s.len = max(s.len, n)
}

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
	buf:    [RATE * MAX_SECONDS]f32,
	len:    int, // samples used so far
	rng:    u32,
	attack: f32, // seconds a burst or tone takes to come in (0: ATTACK)
}

ATTACK :: 0.0015 // seconds: a millisecond and a half: sharp, not clicking

@(private)
Filter :: enum u8 {
	None,
	Low,
	High,
	Band,
}

// Burst: noise, coming in over the synth's attack, decaying (time constant
// tau), filtered.
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
	attack := s.attack if s.attack > 0 else ATTACK
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

// tone: a sine that rings down (glass, metal, wood), coming in over the
// synth's attack (no sine starts at full height: that is a click).
@(private)
tone :: proc(s: ^Synth, freq, tau, gain: f32) {
	n := min(int(6 * tau * RATE), len(s.buf))
	phase := rand_range(&s.rng, 0, math.TAU)
	attack := max(s.attack, ATTACK)
	for i in 0 ..< n {
		t := f32(i) / RATE
		env := min(t / attack, 1) * math.exp(-t / tau)
		s.buf[i] += math.sin(phase + math.TAU * freq * t) * env * gain
	}
	s.len = max(s.len, n)
}

// finish scales the sound to peak, fades its last milliseconds and rounds
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
	return lo + (hi - lo) * base.unit_f32(x)
}
