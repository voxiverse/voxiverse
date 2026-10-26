package audio

import "core:math"

// The compressor (Night mode, and anything that wants its dynamics tamed) and
// the reverb (a feedback delay network). Both run on the audio thread, in
// place, without allocation.

// Compressor: feed-forward, stereo-linked, a soft knee, one-pole attack and
// release on the gain reduction in dB. A ratio of 1 and no make-up gain is a
// bypass that still lets a reduction in progress release smoothly.
Compressor :: struct {
	threshold: f32, // dBFS
	ratio:     f32,
	knee:      f32, // dB
	makeup:    f32, // dB
	attack:    f32, // per-frame coefficient
	release:   f32,
	follow:    f32, // per-frame decay of the peak follower (5 ms)
	level:     f32, // the follower's peak, linear
	env:       f32, // gain reduction now, dB (<= 0)
	reduction: f32, // the lowest env since taken (stats)
}

compressor_init :: proc "contextless" (
	c: ^Compressor,
	rate: f64,
	threshold_db, ratio, knee_db, makeup_db: f32,
	attack_s, release_s: f64,
) {
	c^ = {
		threshold = threshold_db,
		ratio     = max(ratio, 1),
		knee      = max(knee_db, 0),
		makeup    = makeup_db,
		attack    = f32(math.exp(-1 / (max(attack_s, 1e-5) * rate))),
		release   = f32(math.exp(-1 / (max(release_s, 1e-5) * rate))),
		follow    = f32(math.exp(-1 / (0.005 * rate))),
	}
}

// compressor_active: whether running it can change anything.
compressor_active :: proc "contextless" (c: ^Compressor) -> bool {
	return c.ratio > 1 || c.makeup != 0 || c.env < -0.001
}

// compressor_curve: the gain reduction in dB for a level in dB.
compressor_curve :: proc "contextless" (c: ^Compressor, level: f32) -> f32 {
	over := level - c.threshold
	slope := 1 / c.ratio - 1
	if 2 * over < -c.knee {return 0}
	if 2 * abs(over) <= c.knee {
		x := over + c.knee / 2
		return slope * x * x / (2 * max(c.knee, 1e-6))
	}
	return slope * over
}

compressor_run :: proc "contextless" (c: ^Compressor, buf: []f32) {
	for f in 0 ..< len(buf) / 2 {
		// The level is a peak follower (instant up, 5 ms down), so the gain does not
		// ripple with the waveform's own cycle.
		c.level = max(abs(buf[2 * f]), abs(buf[2 * f + 1]), c.level * c.follow, 1e-9)
		want := compressor_curve(c, 20 * math.log10(c.level))
		coef := c.attack if want < c.env else c.release
		c.env = want + coef * (c.env - want)
		g := math.pow(10, (c.env + c.makeup) / 20)
		buf[2 * f] *= g
		buf[2 * f + 1] *= g
		c.reduction = min(c.reduction, c.env)
	}
	if c.env > -1e-6 {c.env = 0}
	if c.level < 1e-9 {c.level = 0}
}

// Reverb: eight delay lines with prime-ish lengths, fed by the input and
// mixed back through an orthogonal (Hadamard) matrix, each line attenuated so
// the tail falls 60 dB in `rt60` seconds, with a one-pole low-pass in the loop
// (`damping`, 0..1) so the highs die first. Output is two decorrelated sums
// of the lines plus a handful of early reflections. All lengths are in
// milliseconds, so the room sounds the same at any rate.
REVERB_LINES :: 8
REVERB_MAX :: 8192 // frames per line (96 kHz at 67 ms fits)
REVERB_EARLY :: 6

@(rodata)
REVERB_MS := [REVERB_LINES]f64{29.7, 37.1, 41.1, 43.7, 47.9, 53.3, 59.9, 67.3}

@(rodata)
EARLY_MS := [REVERB_EARLY]f64{7.0, 11.3, 16.7, 21.1, 27.9, 34.3}

@(rodata)
EARLY_GAIN := [REVERB_EARLY]f32{0.7, 0.55, 0.45, 0.35, 0.28, 0.2}

Reverb :: struct {
	rate:     f64,
	len:      [REVERB_LINES]int,
	line:     [REVERB_LINES][REVERB_MAX]f32,
	pos:      int, // one write index for all lines (each reads `len` behind)
	lp:       [REVERB_LINES]f32, // damping filter state
	gain:     [REVERB_LINES]f32, // per-pass attenuation for the rt60
	damping:  f32,
	early:    f32, // level of the early reflections
	wet:      f32, // level of the whole return
	rt60:     f32,
	pre:      [REVERB_MAX]f32, // the input history for the early taps
	pre_pos:  int,
	early_at: [REVERB_EARLY]int,
	tail:     f32, // peak of the last block's output
}

reverb_init :: proc "contextless" (r: ^Reverb, rate: f64) {
	r^ = {
		rate = rate,
	}
	for i in 0 ..< REVERB_LINES {r.len[i] = clamp(int(REVERB_MS[i] * 0.001 * rate), 16, REVERB_MAX - 1)}
	for i in 0 ..< REVERB_EARLY {r.early_at[i] = clamp(int(EARLY_MS[i] * 0.001 * rate), 1, REVERB_MAX - 1)}
	reverb_set(r, 1.5, 0.3, 0.25, 0.5)
}

// reverb_set: RT60 in seconds (live: the tail's decay changes at once),
// damping 0..1, the return level `wet` and the early reflections' level.
reverb_set :: proc "contextless" (r: ^Reverb, rt60, damping, wet, early: f32) {
	r.rt60 = clamp(rt60, 0.05, 30)
	r.damping = clamp(damping, 0, 0.98)
	r.wet = wet
	r.early = early
	for i in 0 ..< REVERB_LINES {
		r.gain[i] = f32(math.pow(10, -3 * f64(r.len[i]) / (f64(r.rt60) * r.rate)))
	}
}

// reverb_run adds the reverb of `input` (interleaved stereo) into `out`.
reverb_run :: proc "contextless" (r: ^Reverb, input, out: []f32) {
	peak: f32
	for f in 0 ..< len(input) / 2 {
		x := (input[2 * f] + input[2 * f + 1]) * 0.5
		d: [REVERB_LINES]f32
		for i in 0 ..< REVERB_LINES {
			at := r.pos - r.len[i]
			if at < 0 {at += REVERB_MAX}
			d[i] = r.line[i][at]
			r.lp[i] = (1 - r.damping) * d[i] + r.damping * r.lp[i]
		}
		// Hadamard: three butterfly stages, scaled to be orthogonal.
		h := r.lp
		for span := 1; span < REVERB_LINES; span *= 2 {
			for a := 0; a < REVERB_LINES; a += 2 * span {
				for b in a ..< a + span {
					u, v := h[b], h[b + span]
					h[b], h[b + span] = u + v, u - v
				}
			}
		}
		for i in 0 ..< REVERB_LINES {
			r.line[i][r.pos] = x * 0.35 + r.gain[i] * h[i] * 0.35355339 // 1/sqrt(8)
		}
		l, rr: f32
		for i in 0 ..< REVERB_LINES {
			if i % 2 == 0 {l += d[i]} else {rr += d[i]}
		}
		l *= 0.5
		rr *= 0.5
		r.pre[r.pre_pos] = x
		for i in 0 ..< REVERB_EARLY {
			at := r.pre_pos - r.early_at[i]
			if at < 0 {at += REVERB_MAX}
			e := r.pre[at] * EARLY_GAIN[i] * r.early
			if i % 2 == 0 {l += e} else {rr += e}
		}
		r.pos = (r.pos + 1) % REVERB_MAX
		r.pre_pos = (r.pre_pos + 1) % REVERB_MAX
		l *= r.wet
		rr *= r.wet
		out[2 * f] += l
		out[2 * f + 1] += rr
		peak = max(peak, abs(l), abs(rr))
	}
	r.tail = peak
	for i in 0 ..< REVERB_LINES {if abs(r.lp[i]) < 1e-25 {r.lp[i] = 0}}
}

// reverb_clear silences the lines (when the tail is inaudible, so denormals
// never build up and the next sound starts from silence).
reverb_clear :: proc "contextless" (r: ^Reverb) {
	r.line = {}
	r.pre = {}
	r.lp = {}
	r.tail = 0
}
