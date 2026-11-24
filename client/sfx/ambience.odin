package sfx

import "core:math"

// Ambience: long loops for the beds the client's atmosphere mixes by where
// the listener is (client/atmosphere), and thunder. Synthesized like the
// effects, at RATE, but not crushed to BITS: a bed plays for minutes at a
// low level, where 8-bit grain would be a hiss of its own.
//
// A bed is made a little longer than LOOP_SECONDS and its tail is faded into
// its head with equal power, so it loops without a seam; its tones have a
// whole number of cycles in the loop (frequencies in steps of 1 /
// LOOP_SECONDS hertz), so they do not beat at the join.
//
//	samples := sfx.bed_sound(.Rain, allocator)   // loop the whole of it

LOOP_SECONDS :: 6
@(private = "file")
LOOP :: LOOP_SECONDS * RATE
@(private = "file")
JOIN :: RATE / 2 // the tail faded into the head: half a second

Bed :: enum u8 {
	Wind, // filtered noise in slow gusts
	Rain, // a hiss of drops on the ground and leaves
	Water, // a stream's babble and bubbles: shores and rivers
	Cave, // a low drone and a drip now and then: underground
	Insects, // crickets: warm nights
	Birds, // chirps and short phrases: fair days
	Hum, // a deep, beating hum: near what a game marked as humming
}

THUNDER_SECONDS :: 6

// bed_sound makes a bed's loop (LOOP_SECONDS long, peak 0.9).
bed_sound :: proc(b: Bed, allocator := context.allocator) -> []f32 {
	n := LOOP + JOIN
	buf := make([]f32, n, context.temp_allocator)
	rng := seed(u32(b) * 7919 + 101)
	switch b {
	case .Wind:
		wind(buf, &rng)
	case .Rain:
		rain(buf, &rng)
	case .Water:
		water(buf, &rng)
	case .Cave:
		cave(buf, &rng)
	case .Insects:
		insects(buf, &rng)
	case .Birds:
		birds(buf, &rng)
	case .Hum:
		hum(buf, &rng)
	}
	return loop_finish(buf, 0.9, allocator)
}

// thunder_sound: a strike's thunder: a crack (strongest in variant 0, the near one),
// then a rumble that rolls and swells and dies over THUNDER_SECONDS.
thunder_sound :: proc(variant: int, allocator := context.allocator) -> []f32 {
	n := THUNDER_SECONDS * RATE
	buf := make([]f32, n, context.temp_allocator)
	rng := seed(u32(variant) * 31 + 9001)
	crack := f32(1) - 0.4 * f32(variant)
	// The crack: a few sharp broadband bursts.
	for k in 0 ..< 3 {
		at := int(rand_range(&rng, 0, 0.08) * RATE) + k * int(RATE * 0.03)
		f := highpass(600)
		for i in 0 ..< int(0.12 * RATE) {
			if at + i >= n {break}
			t := f32(i) / RATE
			buf[at + i] += biquad(&f, rand_range(&rng, -1, 1)) * math.exp(-t / 0.03) * crack
		}
	}
	// The rumble: low noise, with swells at random times.
	lo1, lo2 := lowpass(220), lowpass(140)
	swells: [6][2]f32 // time, strength
	for &s in swells {s = {rand_range(&rng, 0.1, 3.5), rand_range(&rng, 0.4, 1)}}
	for i in 0 ..< n {
		t := f32(i) / RATE
		env := min(t / 0.15, 1) * math.exp(-t / 1.6)
		for s in swells {
			d := (t - s[0]) / 0.5
			env += s[1] * 0.6 * math.exp(-d * d) * math.exp(-t / 2.5)
		}
		x := biquad(&lo2, biquad(&lo1, rand_range(&rng, -1, 1)))
		buf[i] += x * env * 3
	}
	fade := RATE / 2
	for i in 0 ..< fade {buf[n - 1 - i] *= f32(i) / f32(fade)}
	return normalized(buf, 0.9, allocator)
}

// wind: band-passed noise whose centre wanders and whose level gusts, over a low roar.
@(private = "file")
wind :: proc(buf: []f32, rng: ^u32) {
	gust := smooth_noise(len(buf), 1.2, rng) // a value a 1.2 s apart, eased
	sweep := smooth_noise(len(buf), 2.0, rng)
	roar := lowpass(160)
	f := bandpass(400, 1.2)
	for i in 0 ..< len(buf) {
		if i % 64 == 0 {f = with_state(bandpass(260 + 520 * sweep[i], 1.4), f)}
		x := rand_range(rng, -1, 1)
		level := 0.35 + 0.65 * gust[i]
		buf[i] = biquad(&f, x) * level * 1.6 + biquad(&roar, x) * (0.5 + 0.5 * gust[i])
	}
}

// rain: a high hiss, and thousands of drops: tiny bright ticks at random.
@(private = "file")
rain :: proc(buf: []f32, rng: ^u32) {
	hi, lo := highpass(900), lowpass(6500)
	for i in 0 ..< len(buf) {
		buf[i] = biquad(&lo, biquad(&hi, rand_range(rng, -1, 1))) * 0.35
	}
	drops := len(buf) / RATE * 900
	for _ in 0 ..< drops {
		at := int(rand_range(rng, 0, f32(len(buf) - 1)))
		f := bandpass(rand_range(rng, 1800, 6000), 2.5)
		gain := rand_range(rng, 0.1, 0.6)
		tau := rand_range(rng, 0.002, 0.006)
		for i in 0 ..< int(tau * 5 * RATE) {
			if at + i >= len(buf) {break}
			t := f32(i) / RATE
			buf[at + i] += biquad(&f, rand_range(rng, -1, 1)) * gain * math.exp(-t / tau)
		}
	}
}

// water: a babble (noise in a moving band, quickly modulated) and Minnaert bubbles
// (rising sine chirps).
@(private = "file")
water :: proc(buf: []f32, rng: ^u32) {
	wobble := smooth_noise(len(buf), 0.07, rng)
	sweep := smooth_noise(len(buf), 0.4, rng)
	f := bandpass(600, 2)
	for i in 0 ..< len(buf) {
		if i % 32 == 0 {f = with_state(bandpass(350 + 900 * sweep[i], 2.2), f)}
		buf[i] = biquad(&f, rand_range(rng, -1, 1)) * (0.25 + 0.75 * wobble[i]) * 1.2
	}
	bubbles := len(buf) / RATE * 40
	for _ in 0 ..< bubbles {
		at := int(rand_range(rng, 0, f32(len(buf) - 1)))
		hz := rand_range(rng, 400, 1400)
		tau := rand_range(rng, 0.01, 0.03)
		gain := rand_range(rng, 0.1, 0.4)
		phase: f32
		for i in 0 ..< int(tau * 5 * RATE) {
			if at + i >= len(buf) {break}
			t := f32(i) / RATE
			phase += math.TAU * hz * (1 + 4 * t) / RATE // (a bubble's pitch rises as it closes)
			buf[at + i] += math.sin(phase) * gain * math.exp(-t / tau)
		}
	}
}

// cave: three low tones beating slowly against each other, a low rumble, and a drip
// every second or two that rings a little.
@(private = "file")
cave :: proc(buf: []f32, rng: ^u32) {
	tones := [?][2]f32 {
		{55, 0.5},
		{55 + 1.0 / LOOP_SECONDS, 0.4},
		{82.5, 0.25},
		{110 + 2.0 / LOOP_SECONDS, 0.15},
	}
	rumble := lowpass(90)
	for i in 0 ..< len(buf) {
		t := f32(i) / RATE
		x: f32
		for tone in tones {x += math.sin(math.TAU * tone[0] * t) * tone[1]}
		buf[i] = x * 0.5 + biquad(&rumble, rand_range(rng, -1, 1)) * 0.6
	}
	at := f32(0.3)
	for at < f32(LOOP_SECONDS) {
		hz := rand_range(rng, 900, 1700)
		gain := rand_range(rng, 0.2, 0.5)
		first := int(at * RATE)
		for i in 0 ..< int(0.25 * RATE) {
			if first + i >= len(buf) {break}
			t := f32(i) / RATE
			buf[first + i] +=
				math.sin(math.TAU * hz * (1 + 0.6 * t) * t) * gain * math.exp(-t / 0.05)
		}
		at += rand_range(rng, 0.9, 2.2)
	}
}

// insects: three crickets, each a carrier near 4-5 kHz pulsed in chirps of a few
// pulses at its own rate, and a faint shimmer.
@(private = "file")
insects :: proc(buf: []f32, rng: ^u32) {
	for c in 0 ..< 3 {
		hz := rand_range(rng, 3900, 5200)
		period := rand_range(rng, 0.45, 0.9) // between chirps
		pulses := 2 + int(rand_range(rng, 0, 3))
		gain := rand_range(rng, 0.3, 0.8) / f32(c + 1)
		at := rand_range(rng, 0, period)
		for at < f32(LOOP_SECONDS) {
			for p in 0 ..< pulses {
				first := int((at + f32(p) * 0.032) * RATE)
				for i in 0 ..< int(0.018 * RATE) {
					if first + i >= len(buf) {break}
					t := f32(i) / RATE
					env := math.sin(math.PI * t / 0.018)
					buf[first + i] += math.sin(math.TAU * hz * t) * env * gain
				}
			}
			at += period * rand_range(rng, 0.92, 1.08)
		}
	}
	shimmer := bandpass(6500, 4)
	for i in 0 ..< len(buf) {buf[i] += biquad(&shimmer, rand_range(rng, -1, 1)) * 0.05}
}

// birds: now and then a phrase of a few quick chirps, each a sine swept and warbled.
@(private = "file")
birds :: proc(buf: []f32, rng: ^u32) {
	at := rand_range(rng, 0, 0.8)
	for at < f32(LOOP_SECONDS) {
		notes := 2 + int(rand_range(rng, 0, 5))
		base := rand_range(rng, 2200, 4200)
		gain := rand_range(rng, 0.3, 1)
		for k in 0 ..< notes {
			length := rand_range(rng, 0.04, 0.11)
			from := base * rand_range(rng, 0.85, 1.2)
			to := from * rand_range(rng, 0.7, 1.5)
			first := int(at * RATE)
			phase: f32
			for i in 0 ..< int(length * RATE) {
				if first + i >= len(buf) {break}
				t := f32(i) / RATE
				u := t / length
				hz := from + (to - from) * u + 180 * math.sin(math.TAU * 38 * t)
				phase += math.TAU * hz / RATE
				buf[first + i] += math.sin(phase) * math.sin(math.PI * u) * gain
			}
			at += length + rand_range(rng, 0.02, 0.07)
			_ = k
		}
		at += rand_range(rng, 0.7, 2.4)
	}
}

// hum: a deep fundamental and its harmonics, two of them a hair apart so the hum
// beats slowly, and a faint high whine.
@(private = "file")
hum :: proc(buf: []f32, rng: ^u32) {
	partials := [?][2]f32 {
		{48, 0.6},
		{48 + 0.5, 0.35}, // beating every 2 s
		{96, 0.3},
		{144 + 1.0 / LOOP_SECONDS, 0.15},
		{192, 0.08},
		{1152, 0.015},
	}
	breath := lowpass(300)
	for i in 0 ..< len(buf) {
		t := f32(i) / RATE
		x: f32
		for p in partials {x += math.sin(math.TAU * p[0] * t) * p[1]}
		buf[i] = x + biquad(&breath, rand_range(rng, -1, 1)) * 0.08
	}
}

// smooth_noise: n values that wander between random levels (0..1) every `every`
// seconds, eased between them.
@(private = "file")
smooth_noise :: proc(n: int, every: f32, rng: ^u32) -> []f32 {
	out := make([]f32, n, context.temp_allocator)
	step := max(int(every * RATE), 1)
	a, b := rand_range(rng, 0, 1), rand_range(rng, 0, 1)
	for i in 0 ..< n {
		if i > 0 && i % step == 0 {a, b = b, rand_range(rng, 0, 1)}
		u := f32(i % step) / f32(step)
		out[i] = a + (b - a) * u * u * (3 - 2 * u)
	}
	return out
}

// with_state: new coefficients, the old filter's memory (a filter swept without clicks).
@(private = "file")
with_state :: proc(coefficients, old: Biquad) -> Biquad {
	f := coefficients
	f.x1, f.x2, f.y1, f.y2 = old.x1, old.x2, old.y1, old.y2
	return f
}

// loop_finish: the first LOOP samples, the tail past them faded into the head with
// equal power, scaled to peak.
@(private = "file")
loop_finish :: proc(buf: []f32, peak: f32, allocator := context.allocator) -> []f32 {
	out := make([]f32, LOOP, context.temp_allocator)
	copy(out, buf[:LOOP])
	for i in 0 ..< JOIN {
		u := f32(i) / JOIN
		out[i] = out[i] * math.sin(u * math.PI / 2) + buf[LOOP + i] * math.cos(u * math.PI / 2)
	}
	return normalized(out, peak, allocator)
}

@(private = "file")
normalized :: proc(buf: []f32, peak: f32, allocator := context.allocator) -> []f32 {
	loudest: f32
	for x in buf {loudest = max(loudest, abs(x))}
	scale := peak / loudest if loudest > 0 else 0
	out := make([]f32, len(buf), allocator)
	for x, i in buf {out[i] = x * scale}
	return out
}
