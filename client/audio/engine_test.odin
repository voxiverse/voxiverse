package audio

import "core:math"
import "core:testing"

// Tests for M32a: the true-peak limiter, the compressor, the reverb, the
// windowed-sinc resampler, scheduled starts and the listener's options.

@(private = "file")
engine :: proc(rate: u32) -> ^Mixer {
	m := new(Mixer)
	mixer_init(m, rate)
	return m
}

@(private = "file")
render :: proc(m: ^Mixer, frames: int, block := 480) -> []f32 {
	out := make([]f32, 2 * frames)
	for at := 0; at < frames; at += block {
		mix(m, out[2 * at:][:2 * min(block, frames - at)])
	}
	return out
}

@(private = "file")
tone :: proc(n: int, rate, hz, amp: f64, phase := 0.0) -> []f32 {
	s := make([]f32, n)
	for i in 0 ..< n {s[i] = f32(amp * math.sin(2 * math.PI * hz * f64(i) / rate + phase))}
	return s
}

@(private = "file")
rms :: proc(x: []f32) -> f64 {
	sum: f64
	for v in x {sum += f64(v) * f64(v)}
	return math.sqrt(sum / f64(max(len(x), 1)))
}

// true_peak measures a mono signal independently of the limiter's own
// detector: 8x, a 64-taps-a-side Kaiser sinc.
@(private = "file")
true_peak :: proc(x: []f32) -> f64 {
	peak: f64
	kern: [8][129]f64
	for p in 0 ..< 8 {
		for j in -64 ..= 64 {
			u := f64(j) - f64(p) / 8
			k := 1.0 if u == 0 else math.sin(math.PI * u) / (math.PI * u)
			kern[p][j + 64] = k * kaiser(u / 65, 9)
		}
	}
	for i in 80 ..< len(x) - 80 {
		for p in 0 ..< 8 {
			acc: f64
			for j in -64 ..= 64 {acc += f64(x[i + j]) * kern[p][j + 64]}
			peak = max(peak, abs(acc))
		}
	}
	return peak
}

// Inter-sample peaks: a sine whose samples stay under the ceiling but whose
// waveform does not. The true-peak limiter holds it under -1 dBTP.
@(test)
test_limiter_true_peak :: proc(t: ^testing.T) {
	rate :: 48000.0
	for hz, i in ([]f64{rate / 4, 0.4 * rate, 0.1 * rate, 0.3 * rate}) {
		l: Limiter
		limiter_init(&l, rate, 0.002, -1, 0.15)
		s := tone(48000, rate, hz, 1.2, math.PI / 4 + 0.3 * f64(i))
		defer delete(s)
		buf := make([]f32, 2 * len(s))
		defer delete(buf)
		for v, k in s {buf[2 * k], buf[2 * k + 1] = v, v}
		limiter_run(&l, buf)
		mono := make([]f32, len(s))
		defer delete(mono)
		for k in 0 ..< len(s) {mono[k] = buf[2 * k]}
		// The first part is the limiter settling in; its gain is already down
		// before the signal's first peak, so all of it counts.
		tp := true_peak(mono)
		limit := math.pow(10, -1.0 / 20) * 1.006 // 0.05 dB for the measuring
		testing.expectf(t, tp <= limit, "%v Hz: true peak %v dBTP", hz, 20 * math.log10(tp))
		// And it did not flatten the signal more than it had to.
		testing.expectf(t, tp > 0.8, "%v Hz: true peak only %v", hz, tp)
	}
}

// compress_sine runs a 1 kHz sine of `db` dBFS peak through the compressor
// and returns the gain in dB it settled at.
@(private = "file")
settled_gain :: proc(c: ^Compressor, db: f64) -> f64 {
	rate :: 48000.0
	s := tone(48000, rate, 1000, math.pow(10, db / 20))
	defer delete(s)
	buf := make([]f32, 2 * len(s))
	defer delete(buf)
	for v, k in s {buf[2 * k], buf[2 * k + 1] = v, v}
	compressor_run(c, buf)
	tail := 2 * 9600
	got := make([]f32, 9600)
	defer delete(got)
	for k in 0 ..< 9600 {got[k] = buf[2 * len(s) - tail + 2 * k]}
	return 20 * math.log10(rms(got) / rms(s[len(s) - 9600:]))
}

// The static curve: unity below the threshold, 1/ratio of the excess above.
@(test)
test_compressor_static :: proc(t: ^testing.T) {
	c: Compressor
	compressor_init(&c, 48000, -20, 4, 0, 0, 0.005, 0.1)
	below := settled_gain(&c, -30)
	testing.expectf(t, abs(below) < 0.01, "below the threshold: %v dB", below)
	compressor_init(&c, 48000, -20, 4, 0, 0, 0.005, 0.1)
	above := settled_gain(&c, -10)
	testing.expectf(t, abs(above - -7.5) < 0.5, "10 dB over at 4:1 wants -7.5 dB: %v", above)
	// The curve itself, exactly (with a knee: continuous and below the line).
	compressor_init(&c, 48000, -20, 4, 6, 0, 0.005, 0.1)
	testing.expect_value(t, compressor_curve(&c, -30), 0)
	testing.expectf(t, abs(compressor_curve(&c, -10) - -7.5) < 1e-4, "above the knee")
	at := compressor_curve(&c, -20)
	testing.expectf(t, at < 0 && at > -1, "inside the knee: %v", at)
}

// Attack and release follow their time constants.
@(test)
test_compressor_timing :: proc(t: ^testing.T) {
	rate :: 48000.0
	c: Compressor
	compressor_init(&c, rate, -20, 4, 0, 0, 0.010, 0.100)
	loud := make([]f32, 2 * 48000)
	defer delete(loud)
	for k in 0 ..< 48000 {loud[2 * k], loud[2 * k + 1] = 0.5, 0.5}
	final := compressor_curve(&c, f32(20 * math.log10(0.5)))
	// Step in: after one attack time constant, 63% of the way.
	head := make([]f32, 2 * 480)
	defer delete(head)
	for k in 0 ..< 480 {head[2 * k], head[2 * k + 1] = 0.5, 0.5}
	compressor_run(&c, head)
	frac := f64(c.env / final)
	testing.expectf(t, abs(frac - 0.632) < 0.03, "after one attack constant: %v", frac)
	compressor_run(&c, loud)
	testing.expectf(t, abs(f64(c.env - final)) < 0.01, "settled: %v want %v", c.env, final)
	// Step out: the peak follower lets go after ~8 ms (5 ms * ln 5 from 0.5 to the
	// threshold), then one release constant later 37% of the reduction is left.
	quiet := make([]f32, 2 * int(0.1 * 48000 + 0.0080 * 48000))
	defer delete(quiet)
	compressor_run(&c, quiet)
	left := f64(c.env / final)
	testing.expectf(t, abs(left - 0.368) < 0.03, "after one release constant: %v", left)
}

// The RT60 of the tail: Schroeder's backward integration of an impulse
// response, the slope between -5 and -25 dB extended to 60.
@(private = "file")
measure_rt60 :: proc(rt60: f32, damping: f32) -> f64 {
	rate :: 48000.0
	r := new(Reverb)
	defer free(r)
	reverb_init(r, rate)
	reverb_set(r, rt60, damping, 1, 0)
	n := int(f64(rt60) * rate * 1.6)
	x := make([]f32, 2 * n)
	defer delete(x)
	x[0], x[1] = 1, 1
	out := make([]f32, 2 * n)
	defer delete(out)
	for at := 0; at < n; at += 480 {
		span := min(480, n - at)
		reverb_run(r, x[2 * at:][:2 * span], out[2 * at:][:2 * span])
	}
	edc := make([]f64, n)
	defer delete(edc)
	sum: f64
	for i := n - 1; i >= 0; i -= 1 {
		sum += f64(out[2 * i]) * f64(out[2 * i]) + f64(out[2 * i + 1]) * f64(out[2 * i + 1])
		edc[i] = sum
	}
	t5, t25: f64
	for i in 0 ..< n {
		db := 10 * math.log10(edc[i] / edc[0])
		if t5 == 0 && db <= -5 {t5 = f64(i) / rate}
		if t25 == 0 && db <= -25 {t25 = f64(i) / rate}
	}
	return 3 * (t25 - t5)
}

@(test)
test_reverb_rt60 :: proc(t: ^testing.T) {
	for want in ([]f32{0.5, 1.5, 3}) {
		got := measure_rt60(want, 0)
		testing.expectf(t, abs(got / f64(want) - 1) < 0.1, "RT60 %v s measured %v s", want, got)
	}
	// Damping shortens the tail (the highs die first).
	plain := measure_rt60(1.5, 0)
	damped := measure_rt60(1.5, 0.6)
	testing.expectf(t, damped < plain, "damped %v vs plain %v", damped, plain)
}

// The reverb is linear: twice the input is exactly twice the output, so it
// adds no distortion of its own, and silence in is silence out.
@(test)
test_reverb_linear :: proc(t: ^testing.T) {
	rate :: 48000.0
	a, b := new(Reverb), new(Reverb)
	defer free(a)
	defer free(b)
	reverb_init(a, rate)
	reverb_init(b, rate)
	s := tone(9600, rate, 440, 0.2)
	defer delete(s)
	x1, x2 := make([]f32, 2 * len(s)), make([]f32, 2 * len(s))
	defer delete(x1)
	defer delete(x2)
	for v, k in s {
		x1[2 * k], x1[2 * k + 1] = v, v
		x2[2 * k], x2[2 * k + 1] = 2 * v, 2 * v
	}
	y1, y2 := make([]f32, 2 * len(s)), make([]f32, 2 * len(s))
	defer delete(y1)
	defer delete(y2)
	reverb_run(a, x1, y1)
	reverb_run(b, x2, y2)
	worst: f32
	for i in 0 ..< len(y1) {worst = max(worst, abs(y2[i] - 2 * y1[i]))}
	testing.expectf(t, worst == 0, "not linear: %v", worst)
	silent := make([]f32, 960)
	defer delete(silent)
	out := make([]f32, 960)
	defer delete(out)
	c := new(Reverb)
	defer free(c)
	reverb_init(c, rate)
	reverb_run(c, silent, out)
	testing.expect_value(t, rms(out), 0)
}

// fit_residual: what is left of x after removing the best-fitting sine at
// `cycles` per sample (least squares, so a part of a cycle is no matter),
// relative to the sine's level, in dB.
@(private = "file")
fit_residual :: proc(x: []f32, cycles: f64) -> f64 {
	cc, ss, cs, xc, xs: f64
	for v, i in x {
		c, s := math.cos(2 * math.PI * cycles * f64(i)), math.sin(2 * math.PI * cycles * f64(i))
		cc += c * c
		ss += s * s
		cs += c * s
		xc += f64(v) * c
		xs += f64(v) * s
	}
	det := cc * ss - cs * cs
	a := (xc * ss - xs * cs) / det
	b := (xs * cc - xc * cs) / det
	res: f64
	for v, i in x {
		fit :=
			a * math.cos(2 * math.PI * cycles * f64(i)) +
			b * math.sin(2 * math.PI * cycles * f64(i))
		res += (f64(v) - fit) * (f64(v) - fit)
	}
	res = math.sqrt(res / f64(len(x)))
	return 20 * math.log10(max(res, 1e-12) / (math.sqrt(a * a + b * b) / math.SQRT_TWO))
}

// resample_tone reads a sine of `cycles` per source sample at `step` source
// samples per output frame and returns the middle of the result.
@(private = "file")
resample_tone :: proc(table: ^Sinc_Table, cycles, step: f64) -> []f32 {
	src := make([]f32, 8192)
	defer delete(src)
	for i in 0 ..< len(src) {src[i] = f32(0.5 * math.sin(2 * math.PI * cycles * f64(i) + 0.4))}
	n := 2048
	out := make([]f32, n)
	for i in 0 ..< n {out[i] = sinc_read(table, src, 2048 + 0.37 + f64(i) * step, step, 0, 0, false)}
	return out
}

// Neither the passband nor the stop-band is touched: a tone up to 0.38 of the
// source rate keeps its level within 0.1 dB, and what resampling would alias or
// image is under -90 dB.
@(test)
test_sinc_response :: proc(t: ^testing.T) {
	table := new(Sinc_Table)
	defer free(table)
	sinc_table_init(table)
	for cycles in ([]f64{0.01, 0.1, 0.2, 0.3, 0.38}) {
		// Step 1: a fractional shift only. Compared with the analytic tone.
		got := resample_tone(table, cycles, 1)
		defer delete(got)
		worst: f64
		for v, i in got {
			want := 0.5 * math.sin(2 * math.PI * cycles * (2048 + 0.37 + f64(i)) + 0.4)
			worst = max(worst, abs(f64(v) - want))
		}
		testing.expectf(
			t,
			worst < 0.5 * 0.0115,
			"%v: shift error %v (0.1 dB is 0.0115)",
			cycles,
			worst,
		)
	}
	// Slowing down (images) and speeding up (aliases): pitched voices.
	for tc in ([][2]f64{{0.3, 0.5}, {0.2, 0.9}, {0.38, 0.8}, {0.1, 0.37}}) {
		got := resample_tone(table, tc[0], tc[1])
		defer delete(got)
		res := fit_residual(got, tc[0] * tc[1])
		testing.expectf(t, res < -90, "step %v of %v: residual %v dB", tc[1], tc[0], res)
	}
	for tc in ([][2]f64{{0.35, 1.5}, {0.25, 2.5}, {0.45, 1.2}}) {
		// The tone lands above the output's Nyquist: the stretched kernel removes it.
		got := resample_tone(table, tc[0], tc[1])
		defer delete(got)
		level := 20 * math.log10(rms(got) / (0.5 / math.SQRT_TWO))
		testing.expectf(t, level < -90, "step %v of %v: leaked %v dB", tc[1], tc[0], level)
	}
}

// resample_sound converts a rate offline and the tone survives.
@(test)
test_resample_sound :: proc(t: ^testing.T) {
	s := tone(44100, 44100, 1000, 0.5)
	defer delete(s)
	out := resample_sound({s, 44100}, 48000)
	defer delete(out.samples, context.allocator)
	testing.expect_value(t, out.rate, u32(48000))
	testing.expectf(t, abs(len(out.samples) - 48000) <= 1, "length %v", len(out.samples))
	mid := out.samples[2000:40000]
	res := fit_residual(mid, 1000.0 / 48000)
	testing.expectf(t, res < -90, "converted tone residual %v dB", res)
	same := resample_sound({s, 44100}, 44100)
	defer delete(same.samples, context.allocator)
	testing.expect_value(t, len(same.samples), len(s))
}

// A voice at another rate goes through the sinc path in the mixer: a clean
// tone at the right pitch comes out.
@(test)
test_mixer_rate_conversion :: proc(t: ^testing.T) {
	m := engine(48000)
	defer free(m)
	s := tone(44100, 44100, 1000, 0.4)
	defer delete(s)
	id := add_sound(m, {s, 44100})
	play(m, {sound = id, gain = {1, 1}, pitch = 1})
	out := render(m, 40000)
	defer delete(out)
	left := make([]f32, 30000)
	defer delete(left)
	for i in 0 ..< len(left) {left[i] = out[2 * (3000 + i)]}
	res := fit_residual(left, 1000.0 / 48000)
	testing.expectf(t, res < -85, "mixed tone residual %v dB", res)
}

// A scheduled sound begins on exactly its frame, in any block layout, also
// an hour into the run; one scheduled in the past starts at once and is counted.
@(test)
test_scheduled_start :: proc(t: ^testing.T) {
	hour := u64(3600 * 48000)
	for block in ([]int{480, 1000, 97, 2048}) {
		m := engine(48000)
		defer free(m)
		m.clock = hour
		m.stats.frames = hour
		step := make([]f32, 4000)
		defer delete(step)
		for &v in step {v = 0.25}
		id := add_sound(m, {step, 48000})
		starts := []u64{hour + 1000, hour + 1001, hour + 2047, hour + 5003}
		for s in starts {
			play(m, {sound = id, gain = {1, 1}, pitch = 1, start_frame = s})
		}
		out := render(m, 12000, block)
		defer delete(out)
		testing.expect_value(t, clock(m), hour + 12000)
		late := latency(m)
		// The first start is alone until the next; look at the very edge of each.
		at := int(starts[0] - hour) + late
		testing.expectf(
			t,
			out[2 * (at - 1)] == 0,
			"block %v: before the edge: %v",
			block,
			out[2 * (at - 1)],
		)
		testing.expectf(
			t,
			abs(out[2 * at] - 0.25) < 1e-6,
			"block %v: on the edge: %v",
			block,
			out[2 * at],
		)
		// The second joins exactly one frame later: 0.5.
		testing.expectf(
			t,
			abs(out[2 * (at + 1)] - 0.5) < 1e-6,
			"block %v: one later: %v",
			block,
			out[2 * (at + 1)],
		)
		stats := stats(m)
		testing.expect_value(t, stats.late, 0)
		testing.expect_value(t, stats.played, 4)
	}
	// In the past: starts with the next mix.
	m := engine(48000)
	defer free(m)
	m.clock = hour
	tick := constant_sound(2000, 0.25)
	defer delete(tick)
	id := add_sound(m, {tick, 48000})
	play(m, {sound = id, gain = {1, 1}, pitch = 1, start_frame = hour - 50})
	out := render(m, 480)
	defer delete(out)
	testing.expect_value(t, stats(m).late, 1)
	late := latency(m)
	testing.expectf(t, abs(out[2 * (late + 10)] - 0.25) < 1e-6, "late start heard")
}

@(private = "file")
constant_sound :: proc(n: int, v: f32) -> []f32 {
	s := make([]f32, n)
	for &x in s {x = v}
	return s
}

// A bus that sends to the reverb is heard after the sound ends; one that does
// not is silent then; the return is bounded.
@(test)
test_mixer_reverb_send :: proc(t: ^testing.T) {
	for send in ([]f32{0, 0.5}) {
		m := engine(48000)
		defer free(m)
		burst := tone(2400, 48000, 800, 0.3)
		defer delete(burst)
		id := add_sound(m, {burst, 48000})
		set_reverb(m, 1.5, 0.3, 1, 0.5)
		set_bus_reverb(m, .Effects, send)
		play(m, {sound = id, gain = {1, 1}, pitch = 1})
		out := render(m, 48000)
		defer delete(out)
		tail := rms(out[2 * 9600:][:2 * 9600])
		if send == 0 {
			testing.expect_value(t, tail, 0)
		} else {
			testing.expectf(t, tail > 1e-3 && tail < 0.3, "the tail: %v", tail)
		}
		testing.expect_value(t, stats(m).nan_guarded, 0)
	}
	// The tail dies out and the mixer stops running the reverb.
	m := engine(48000)
	defer free(m)
	burst := tone(480, 48000, 800, 0.3)
	defer delete(burst)
	id := add_sound(m, {burst, 48000})
	set_reverb(m, 0.4, 0.3, 1, 0.5)
	set_bus_reverb(m, .Effects, 1)
	play(m, {sound = id, gain = {1, 1}, pitch = 1})
	set_bus_reverb(m, .Effects, 0)
	out := render(m, 96000)
	defer delete(out)
	testing.expectf(t, m.reverb.tail == 0, "reverb still running: %v", m.reverb.tail)
}

// Mono, swap and the ceiling.
@(test)
test_listener_options :: proc(t: ^testing.T) {
	rate :: 48000
	m := engine(rate)
	defer free(m)
	s := constant_sound(20000, 0.3)
	defer delete(s)
	id := add_sound(m, {s, rate})
	play(m, {sound = id, gain = {1, 0.5}, pitch = 1, loop = true})
	set_listener(m, {swap = true})
	out := render(m, 8000)
	defer delete(out)
	late := latency(m)
	testing.expectf(
		t,
		abs(out[2 * (5000 + late)] - 0.15) < 1e-4,
		"swapped left: %v",
		out[2 * (5000 + late)],
	)
	testing.expectf(t, abs(out[2 * (5000 + late) + 1] - 0.3) < 1e-4, "swapped right")
	set_listener(m, {mono = true})
	out2 := render(m, 8000)
	defer delete(out2)
	testing.expectf(t, abs(out2[2 * 6000] - 0.225) < 1e-4, "mono: %v", out2[2 * 6000])
	testing.expect_value(t, out2[2 * 6000], out2[2 * 6000 + 1])
	// Cross-feed keeps a centered signal's level and moves some of the lows across.
	set_listener(m, {crossfeed = 0.4})
	out3 := render(m, 8000)
	defer delete(out3)
	l, r := out3[2 * 7000], out3[2 * 7000 + 1]
	testing.expectf(t, abs(l - (0.3 + 0.4 * 0.15) / 1.4) < 1e-3, "cross-fed left %v", l)
	testing.expectf(t, abs(r - (0.15 + 0.4 * 0.3) / 1.4) < 1e-3, "cross-fed right %v", r)
}

@(test)
test_listener_ceiling_and_night :: proc(t: ^testing.T) {
	rate :: 48000
	s := tone(rate * 2, rate, 440, 0.9)
	defer delete(s)
	peak_of :: proc(x: []f32) -> f32 {
		p: f32
		for v in x {p = max(p, abs(v))}
		return p
	}
	// A safety ceiling of -12 dBFS: nothing above 0.2512, not even the first frames.
	m := engine(rate)
	defer free(m)
	id := add_sound(m, {s, rate})
	set_listener(m, {ceiling_db = -12})
	play(m, {sound = id, gain = {1, 1}, pitch = 1})
	out := render(m, rate * 2)
	defer delete(out)
	p := peak_of(out)
	testing.expectf(t, p <= 0.2512 * 1.001, "ceiling -12 dBFS: peak %v", p)
	testing.expectf(t, p > 0.2, "and the sound is still there: %v", p)
	// Night mode lowers loud things: the steady level is below the plain mix's.
	plain := engine(rate)
	defer free(plain)
	id2 := add_sound(plain, {s, rate})
	play(plain, {sound = id2, gain = {1, 1}, pitch = 1})
	a := render(plain, rate * 2)
	defer delete(a)
	night := engine(rate)
	defer free(night)
	id3 := add_sound(night, {s, rate})
	set_listener(night, {night = true})
	play(night, {sound = id3, gain = {1, 1}, pitch = 1})
	b := render(night, rate * 2)
	defer delete(b)
	loud := rms(a[2 * rate:][:2 * 9600])
	calm := rms(b[2 * rate:][:2 * 9600])
	testing.expectf(t, calm < 0.6 * loud, "night: %v against %v", calm, loud)
}
