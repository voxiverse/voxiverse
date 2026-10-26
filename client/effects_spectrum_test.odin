package client

import "core:log"
import "core:math"
import "core:testing"

import "../audio"

// M32c's exit check "old effects heard as before": a fixed scene of the
// block sounds (a break, a place, a step, a landing, at two pitches) is
// mixed offline and its energy in third-octave bands compared with the
// numbers taken before the streams and the capture hook went in. The mixer
// may change how it works; what the player hears of these may not move by
// more than 1 dB in any band that matters.

SPECTRUM_RATE :: 48000
SPECTRUM_BANDS :: 24 // third octaves from 50 Hz to 12.5 kHz
SPECTRUM_FLOOR :: -60.0 // dB under the loudest band: quieter bands are not compared

// EFFECTS_BANDS: dB of each band, from the mix before M32c (what the
// listener heard through M32a); see effects_scene.
@(rodata)
EFFECTS_BANDS := [SPECTRUM_BANDS]f64 {
	-51.05,
	-55.23,
	-49.44,
	-49.04,
	-47.12,
	-50.16,
	-50.19,
	-46.86,
	-39.80,
	-55.12,
	-56.34,
	-52.09,
	-47.70,
	-54.31,
	-51.99,
	-48.34,
	-41.83,
	-47.83,
	-43.52,
	-51.82,
	-47.48,
	-55.93,
	-54.65,
	-79.76,
}

@(private = "file")
effects_scene :: proc() -> []f32 {
	m := new(audio.Mixer)
	defer free(m)
	audio.mixer_init(m, SPECTRUM_RATE)
	bank := new(Sound_Bank)
	defer {sounds_destroy(bank); free(bank)}
	sounds_init(bank, m)
	gain := [2]f32{0.6, 0.5}
	at :: proc(seconds: f64) -> u64 {return u64(seconds * SPECTRUM_RATE) + 4800}
	audio.play(m, {sound = bank.block[.Stone][.Break][0], gain = gain, start_frame = at(0)})
	audio.play(
		m,
		{sound = bank.block[.Wood][.Place][0], gain = gain, pitch = 0.9, start_frame = at(0.5)},
	)
	audio.play(
		m,
		{sound = bank.block[.Grass][.Step][0], gain = gain, pitch = 1.1, start_frame = at(1.0)},
	)
	audio.play(m, {sound = bank.block[.Gravel][.Step][1], gain = gain, start_frame = at(1.3)})
	audio.play(
		m,
		{sound = bank.player[.Land][0], gain = gain, bus = .Player, start_frame = at(1.6)},
	)
	audio.play(
		m,
		{sound = bank.block[.Glass][.Break][0], gain = gain, pitch = 1.1, start_frame = at(2.2)},
	)
	frames := 3 * SPECTRUM_RATE
	out := make([]f32, 2 * frames)
	for k := 0; k < frames; k += 480 {audio.mix(m, out[2 * k:][:2 * 480])}
	mono := make([]f32, frames)
	for i in 0 ..< frames {mono[i] = 0.5 * (out[2 * i] + out[2 * i + 1])}
	delete(out)
	return mono
}

// fft: in-place radix-2 on re, im (length a power of two).
@(private = "file")
fft :: proc(re, im: []f64) {
	n := len(re)
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for ; j & bit != 0; bit >>= 1 {j ~= bit}
		j ~= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		ang := -2 * math.PI / f64(size)
		wr, wi := math.cos(ang), math.sin(ang)
		for start := 0; start < n; start += size {
			cr, ci := 1.0, 0.0
			for k in 0 ..< size / 2 {
				a, b := start + k, start + k + size / 2
				tr := re[b] * cr - im[b] * ci
				ti := re[b] * ci + im[b] * cr
				re[b], im[b] = re[a] - tr, im[a] - ti
				re[a], im[a] = re[a] + tr, im[a] + ti
				cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
			}
		}
	}
}

// third_octaves: dB (power) in each of SPECTRUM_BANDS bands from 50 Hz.
@(private = "file")
third_octaves :: proc(x: []f32) -> (bands: [SPECTRUM_BANDS]f64) {
	n := 1
	for n < len(x) {n <<= 1}
	re := make([]f64, n)
	im := make([]f64, n)
	defer {delete(re); delete(im)}
	for v, i in x {re[i] = f64(v)}
	fft(re, im)
	for b in 0 ..< SPECTRUM_BANDS {
		centre := 50 * math.pow(2, f64(b) / 3)
		lo := int(centre / math.pow(2, 1.0 / 6) * f64(n) / SPECTRUM_RATE)
		hi := int(centre * math.pow(2, 1.0 / 6) * f64(n) / SPECTRUM_RATE)
		sum: f64
		for k in lo ..< hi {sum += re[k] * re[k] + im[k] * im[k]}
		bands[b] = 10 * math.log10(max(sum, 1e-20) / f64(n) / f64(n))
	}
	return
}

@(test)
test_effects_heard_as_before :: proc(t: ^testing.T) {
	scene := effects_scene()
	defer delete(scene)
	bands := third_octaves(scene)
	top := bands[0]
	for b in bands {top = max(top, b)}
	if EFFECTS_BANDS[0] == 0 && EFFECTS_BANDS[10] == 0 {
		log.infof("BANDS %v", bands)
		testing.fail_now(t, "no baseline yet")
	}
	for b in 0 ..< SPECTRUM_BANDS {
		if EFFECTS_BANDS[b] < top + SPECTRUM_FLOOR && bands[b] < top + SPECTRUM_FLOOR {continue}
		testing.expectf(
			t,
			abs(bands[b] - EFFECTS_BANDS[b]) <= 1,
			"band %d (%.0f Hz): %.2f dB, was %.2f",
			b,
			50 * math.pow(2, f64(b) / 3),
			bands[b],
			EFFECTS_BANDS[b],
		)
	}
}
