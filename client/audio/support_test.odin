package audio

import "core:math"

// The helpers the package's tests share.

new_mixer :: proc(rate: u32) -> ^Mixer {
	m := new(Mixer)
	mixer_init(m, rate)
	return m
}

// mix_frames mixes that many frames (in blocks of the device's size) and
// returns them; the caller deletes.
mix_frames :: proc(m: ^Mixer, frames: int, block := 480) -> []f32 {
	out := make([]f32, 2 * frames)
	for at := 0; at < frames; at += block {
		mix(m, out[2 * at:][:2 * min(block, frames - at)])
	}
	return out
}

// constant: n samples of v.
constant :: proc(n: int, v: f32) -> []f32 {
	s := make([]f32, n)
	for &x in s {x = v}
	return s
}

rms :: proc(x: []f32) -> f64 {
	sum: f64
	for v in x {sum += f64(v) * f64(v)}
	return math.sqrt(sum / f64(max(len(x), 1)))
}
