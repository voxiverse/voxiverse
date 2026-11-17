package ui

import "core:math"

// Easing: how a thing that moves or grows over a moment gets there, as a curve from 0 at
// its start to 1 at its end, so a HUD element pops or slides in rather than appears. Each
// takes t, the fraction of the moment gone (clamped to 0 ..= 1), and is 0 at 0 and 1 at 1.

Ease :: enum u8 {
	Linear,
	Out_Quad, // fast, then settling: a fade
	Out_Cubic, // faster, then settling longer: a slide
	In_Out, // slow, fast, slow: a move from one place to another
	Out_Back, // past the end a little, then back: a pop
	Out_Elastic, // past the end and back a few times, smaller each: a bounce
}

// BACK_OVERSHOOT: how far Out_Back goes past its end (about a tenth).
BACK_OVERSHOOT :: 1.70158

// ease: the curve e at a fraction of its moment (0 ..= 1, clamped).
ease :: proc(e: Ease, fraction: f32) -> f32 {
	t := clamp(fraction, 0, 1)
	switch e {
	case .Linear:
		return t
	case .Out_Quad:
		u := 1 - t
		return 1 - u * u
	case .Out_Cubic:
		u := 1 - t
		return 1 - u * u * u
	case .In_Out:
		return t * t * (3 - 2 * t)
	case .Out_Back:
		u := t - 1
		return 1 + u * u * ((BACK_OVERSHOOT + 1) * u + BACK_OVERSHOOT)
	case .Out_Elastic:
		if t == 0 || t == 1 {return t}
		return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * math.TAU / 3) + 1
	}
	return t
}
