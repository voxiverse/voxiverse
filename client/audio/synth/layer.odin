package synth

import "core:mem"

import "common:base"

// A recipe is data: sounds made of layers. generate draws every range once
// per variant (in the order the values appear in the recipe, from
// rng_make(seed * 64 + variant), so adding a value later does not change the
// earlier draws), renders each layer (source, envelope, filter, level,
// delay), sums them, applies the recipe's EQ, removes DC, fades both ends
// 1 ms and scales the peak to the sound's `gain`.

// Class is a row of the targets table (docs/audio.md).
Class :: enum u8 {
	Block_Break,
	Block_Place,
	Block_Step,
	Land,
	Creature_Hurt,
	Creature_Die,
	Launch,
	Boom,
}

Character :: enum u8 {
	Follow, // the player's sound-character option decides (the default)
	Clean, // never roughened
}

// Value is a number or a range. A ranged value in a per-variant place has a
// slot: the index of its draw in the variant's table (-1: not drawn there).
Value :: struct {
	lo, hi: f64,
	slot:   int,
}

Envelope :: struct {
	attack, hold, decay: Value, // s; decay is to -60 dB (exp) or to zero (lin)
	linear:              bool,
}

Filter_Kind :: enum u8 {
	None,
	Lowpass,
	Highpass,
	Bandpass,
}

Layer_Filter :: struct {
	kind:    Filter_Kind,
	freq, q: Value,
}

Noise_Source :: struct {
	color: Noise_Color,
}

Tone_Source :: struct {
	from, to: Value, // Hz; to == from: steady
}

Click_Source :: struct {
	hardness: Value,
}

Modal_Source :: struct {
	material:                                   Material,
	hardness, modes, spread, decay, brightness: Value,
	length:                                     Value, // the exciter's, s
}

Granular_Source :: struct {
	kind:              Grain_Kind,
	material:          Material,
	count, spread:     Value,
	size, pitch, gain: Range, // per grain
	density:           Density,
}

Formant_Source :: struct {
	pitch_from, pitch_to:                                 Value,
	vowel_from, vowel_to:                                 Vowel,
	vibrato_rate, vibrato_cents, jitter, shimmer, breath: Value,
}

Bubble_Source :: struct {
	radius:        Range, // per bubble
	count, spread: Value,
}

Source :: union #no_nil {
	Noise_Source,
	Tone_Source,
	Click_Source,
	Modal_Source,
	Granular_Source,
	Formant_Source,
	Bubble_Source,
}

Layer :: struct {
	name:     string,
	source:   Source,
	envelope: Envelope,
	filter:   Layer_Filter,
	level_db: Value,
	delay:    Value, // s
	pitch:    Value, // a ratio on every frequency in the layer
}

Eq_Kind :: enum u8 {
	Low_Shelf,
	High_Shelf,
	Peak,
}

Eq :: struct {
	kind:    Eq_Kind,
	freq, q: Value,
	gain_db: Value,
}

Sound :: struct {
	name:      string,
	class:     Class,
	variants:  int,
	seed:      u64,
	length:    f64, // the most the sound may last, s (0: as long as its layers)
	gain_db:   f64, // the peak, dBFS
	character: Character,
	loop:      f64, // 0, or the crossfade of a seamless loop, s
	layers:    [dynamic]Layer,
	eqs:       [dynamic]Eq,
	ranges:    [dynamic]Range, // one per slot, in the order they appear
}

MAX_LENGTH :: 12.0 // s: the longest any sound may be
DEFAULT_GAIN_DB :: -2.0

@(private)
Ctx :: struct {
	drawn: []f64,
	rng:   base.Rng,
}

@(private)
val :: #force_inline proc "contextless" (c: ^Ctx, v: Value) -> f64 {
	if v.slot >= 0 {return c.drawn[v.slot]}
	return v.lo
}

@(private)
// layer_duration: how long a layer's source runs, s.
layer_duration :: proc "contextless" (e: Envelope, c: ^Ctx) -> f64 {
	d := val(c, e.attack) + val(c, e.hold) + val(c, e.decay) * (1.0 if e.linear else 1.5)
	return clamp(d, 0.001, MAX_LENGTH)
}

// draw_ranges draws every per-variant range, in the order they appear.
@(private)
draw_ranges :: proc(s: ^Sound, rng: ^base.Rng, allocator: mem.Allocator) -> []f64 {
	drawn := make([]f64, len(s.ranges), allocator)
	for r, i in s.ranges {drawn[i] = range_draw(rng, r)}
	return drawn
}

// generate makes one variant of a sound: mono samples at RATE, as f32.
generate :: proc(s: ^Sound, variant: int, allocator := context.allocator) -> []f32 {
	c := Ctx {
		rng = base.rng_make(s.seed * 64 + u64(variant)),
	}
	c.drawn = draw_ranges(s, &c.rng, context.temp_allocator)
	defer delete(c.drawn, context.temp_allocator)

	// Lengths first: the mix is as long as the longest layer, up to `length`.
	longest := 0.0
	for &l in s.layers {
		longest = max(longest, val(&c, l.delay) + layer_duration(l.envelope, &c))
	}
	longest = min(longest, MAX_LENGTH)
	if s.length > 0 {longest = min(longest, s.length)}
	n := max(int(longest * RATE), 1)
	mix := make([]f64, n, context.temp_allocator)
	defer delete(mix, context.temp_allocator)

	for &l in s.layers {layer_render(mix, &l, &c)}

	for e in s.eqs {
		f: Biquad
		freq, gain := val(&c, e.freq), val(&c, e.gain_db)
		switch e.kind {
		case .Low_Shelf:
			f = low_shelf(freq, gain)
		case .High_Shelf:
			f = high_shelf(freq, gain)
		case .Peak:
			f = peaking(freq, val(&c, e.q), gain)
		}
		for &x in mix {x = biquad_run(&f, x)}
	}
	dc := highpass(10, 0.7071)
	for &x in mix {x = biquad_run(&dc, x)}

	out := mix
	if s.loop > 0 {out = loop_crossfade(mix, s.loop)} else {fade_ends(mix)}

	peak := 0.0
	for x in out {peak = max(peak, abs(x))}
	scale := from_db_amp(s.gain_db) / peak if peak > 0 else 0
	result := make([]f32, len(out), allocator)
	for x, i in out {result[i] = f32(x * scale)}
	return result
}

// fade_ends ramps the first and last millisecond (a raised cosine cubed).
@(private)
fade_ends :: proc(x: []f64) {
	n := min(RATE / 1000, len(x) / 2)
	for i in 0 ..< n {
		// Cubed, so the first samples of a loud onset are far under -60 dB.
		w := hann(f64(i) / f64(2 * n))
		w = w * w * w
		x[i] *= w
		x[len(x) - 1 - i] *= w
	}
}

// loop_crossfade: the last `fade` seconds blend into the first, so playing
// the result again and again has no seam. Shorter by the fade.
@(private)
loop_crossfade :: proc(x: []f64, fade: f64) -> []f64 {
	f := min(int(fade * RATE), len(x) / 2)
	n := len(x) - f
	for i in 0 ..< f {
		u := f64(i) / f64(max(f, 1))
		// Equal power: the head fades in over the tail's fade-out.
		x[i] = x[i] * base.sin(u * PI / 2) + x[n + i] * base.cos(u * PI / 2)
	}
	return x[:n]
}

@(private)
layer_render :: proc(mix: []f64, l: ^Layer, c: ^Ctx) {
	delay := int(val(c, l.delay) * RATE)
	if delay >= len(mix) {return}
	n := min(int(layer_duration(l.envelope, c) * RATE), len(mix) - delay)
	if n <= 0 {return}
	buf := make([]f64, n, context.temp_allocator)
	defer delete(buf, context.temp_allocator)
	pitch := val(c, l.pitch)

	switch &src in l.source {
	case Noise_Source:
		st: Noise_State
		for &x in buf {x = noise_next(&st, &c.rng, src.color)}
	case Tone_Source:
		from, to := val(c, src.from) * pitch, val(c, src.to) * pitch
		phase: f64
		for &x, i in buf {
			f := from + (to - from) * f64(i) / f64(n)
			phase += 2 * PI * f / RATE
			x = base.sin(phase)
		}
	case Click_Source:
		lp := lowpass(exciter_cutoff(val(c, src.hardness)), 0.7071)
		peak := 0.0
		for &x, i in buf {
			x = biquad_run(&lp, 1.0 if i == 0 else 0)
			peak = max(peak, abs(x))
		}
		if peak > 0 {for &x in buf {x /= peak}}
	case Modal_Source:
		modal_render(
			buf,
			{
				material = src.material,
				hardness = val(c, src.hardness),
				modes = int(val(c, src.modes)),
				spread = val(c, src.spread),
				decay = val(c, src.decay),
				brightness = val(c, src.brightness),
				length = val(c, src.length),
			},
			pitch,
		)
	case Granular_Source:
		granular_render(
			buf,
			{
				kind = src.kind,
				material = src.material,
				count = int(val(c, src.count)),
				spread = val(c, src.spread),
				density = src.density,
				size = src.size,
				pitch = src.pitch,
				gain_db = src.gain,
			},
			&c.rng,
			pitch,
		)
	case Formant_Source:
		formant_render(
			buf,
			{
				pitch_from = val(c, src.pitch_from),
				pitch_to = val(c, src.pitch_to),
				vowel_from = src.vowel_from,
				vowel_to = src.vowel_to,
				vibrato_rate = val(c, src.vibrato_rate),
				vibrato_cents = val(c, src.vibrato_cents),
				jitter = val(c, src.jitter),
				shimmer = val(c, src.shimmer),
				breath = val(c, src.breath),
			},
			&c.rng,
			pitch,
		)
	case Bubble_Source:
		bubble_render(
			buf,
			{radius = src.radius, count = int(val(c, src.count)), spread = val(c, src.spread)},
			&c.rng,
			pitch,
		)
	}

	// Envelope.
	attack := int(val(c, l.envelope.attack) * RATE)
	hold := int(val(c, l.envelope.hold) * RATE)
	decay := max(val(c, l.envelope.decay), 1e-4) * RATE
	step := from_db_amp(-60 / decay) // exp: -60 dB over the decay
	gain := 1.0
	for &x, i in buf {
		g: f64
		switch {
		case i < attack:
			g = f64(i) / f64(attack)
		case i < attack + hold:
			g = 1
		case l.envelope.linear:
			g = max(1 - f64(i - attack - hold) / decay, 0)
		case:
			g = gain
			gain *= step
		}
		x *= g
	}

	if l.filter.kind != .None {
		freq, q := val(c, l.filter.freq) * pitch, val(c, l.filter.q)
		f: Biquad
		switch l.filter.kind {
		case .None:
		case .Lowpass:
			f = lowpass(freq, q)
		case .Highpass:
			f = highpass(freq, q)
		case .Bandpass:
			f = bandpass(freq, q)
		}
		for &x in buf {x = biquad_run(&f, x)}
	}

	level := from_db_amp(val(c, l.level_db))
	for x, i in buf {mix[delay + i] += x * level}
}
