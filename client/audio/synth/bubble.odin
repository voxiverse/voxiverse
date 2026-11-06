package synth

import "common:base"

// Minnaert bubbles: an air bubble of radius r metres in water rings at
// 3.26 / r Hz and its pitch rises about 10% as it decays: the sound of water.

MINNAERT :: 3.26

Bubble_Params :: struct {
	radius: Range, // m, drawn per bubble
	count:  int,
	spread: f64, // bubbles start within this many seconds
}

bubble_render :: proc(out: []f64, p: Bubble_Params, rng: ^base.Rng, pitch: f64) {
	for _ in 0 ..< p.count {
		start := int(base.rng_f64(rng) * p.spread * RATE)
		f0 := MINNAERT / max(range_draw(rng, p.radius), 1e-4) * pitch
		if start >= len(out) || f0 >= 0.45 * RATE {continue}
		tau := 15 / f0 // e-fold decay: fifteen cycles
		n := min(int(8 * tau * RATE), len(out) - start)
		phase: f64
		for i in 0 ..< n {
			t := f64(i) / RATE
			f := f0 * (1 + 0.1 * (1 - base.exp(-t / tau)))
			phase += 2 * PI * f / RATE
			out[start + i] += base.sin(phase) * base.exp(-t / tau) * min(f64(i) / 24, 1)
		}
	}
}
