package synth

import "common:base"

// Granular synthesis: `count` short Hann-windowed grains scattered in time,
// each of noise, a tone or a one-mode resonator, with its own start, size,
// pitch and gain drawn from the recipe's ranges.

Grain_Kind :: enum u8 {
	Noise,
	Tone,
	Modal,
}

Density :: enum u8 {
	Flat, // uniform over the spread
	Front, // most grains early
	Back, // most grains late
}

Range :: struct {
	lo, hi: f64,
}

Granular_Params :: struct {
	kind:     Grain_Kind,
	material: Material, // for Modal
	count:    int,
	spread:   f64, // grains start within this many seconds
	density:  Density,
	size:     Range, // s
	pitch:    Range, // Hz for noise (band-pass centre; 0: unfiltered) and tone; a ratio of the material's base for modal
	gain_db:  Range,
}

// range_draw draws one value of r from rng.
range_draw :: proc "contextless" (r: ^base.Rng, v: Range) -> f64 {
	if v.hi <= v.lo {return v.lo}
	return base.rng_f64_range(r, v.lo, v.hi)
}

// granular_render adds the grains to out.
granular_render :: proc(out: []f64, p: Granular_Params, rng: ^base.Rng, pitch: f64) {
	table := MATERIAL_MODES
	for _ in 0 ..< p.count {
		u := base.rng_f64(rng)
		switch p.density {
		case .Flat:
		case .Front:
			u *= u
		case .Back:
			u = 1 - u * u
		}
		start := int(u * p.spread * RATE)
		size := max(int(range_draw(rng, p.size) * RATE), 2)
		freq := range_draw(rng, p.pitch)
		gain := from_db_amp(range_draw(rng, p.gain_db))
		if start >= len(out) {continue}
		n := min(size, len(out) - start)
		switch p.kind {
		case .Noise:
			f := bandpass(freq * pitch, 2)
			for i in 0 ..< n {
				x := noise_white(rng)
				if freq > 0 {x = biquad_run(&f, x) * 2}
				out[start + i] += x * gain * hann(f64(i) / f64(size))
			}
		case .Tone:
			w := 2 * PI * freq * pitch / RATE
			phase := base.rng_f64(rng) * 2 * PI
			for i in 0 ..< n {
				out[start + i] += base.sin(phase + w * f64(i)) * gain * hann(f64(i) / f64(size))
			}
		case .Modal:
			// A one-mode resonator struck by a unit click, ringing the grain's size.
			b: Bank
			m := table[p.material]
			bank_add(&b, m.base * freq * pitch, f64(size) / RATE, 1)
			for i in 0 ..< n {
				x := 1.0 if i == 0 else 0
				out[start + i] += bank_run(&b, x) * 8 * gain * hann(f64(i) / f64(size))
			}
		}
	}
}
