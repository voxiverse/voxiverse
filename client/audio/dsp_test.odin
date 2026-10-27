package audio

import "core:math"
import "core:testing"

// The state-variable filter matches its analytic response (the analog
// prototype at the warped frequency) at test frequencies.
@(test)
test_svf_response :: proc(t: ^testing.T) {
	rate :: 48000.0
	cutoff :: 1000.0
	for q in ([]f64{0.7071, 2}) {
		for hz in ([]f64{100, 500, 1000, 2000, 8000}) {
			f: Svf
			svf_set(&f, cutoff, q, rate)
			w := math.tan(math.PI * hz / rate) / math.tan(math.PI * cutoff / rate)
			want_low := 1 / math.sqrt((1 - w * w) * (1 - w * w) + w * w / (q * q))
			want_high := w * w * want_low
			low_sq, high_sq: f64
			N :: 48000
			for i in 0 ..< N {
				x := f32(math.sin(2 * math.PI * hz * f64(i) / rate))
				o := svf_run(&f, x)
				if i >= N / 2 {
					low_sq += f64(o.low * o.low)
					high_sq += f64(o.high * o.high)
				}
			}
			got_low := math.sqrt(2 * low_sq / (N / 2))
			got_high := math.sqrt(2 * high_sq / (N / 2))
			testing.expectf(
				t,
				abs(got_low / want_low - 1) < 0.01,
				"low q=%v %v Hz: %v want %v",
				q,
				hz,
				got_low,
				want_low,
			)
			testing.expectf(
				t,
				abs(got_high / want_high - 1) < 0.01,
				"high q=%v %v Hz: %v want %v",
				q,
				hz,
				got_high,
				want_high,
			)
		}
	}
}

// A swept filter stays stable (no blow-up) and finite.
@(test)
test_svf_sweep_stable :: proc(t: ^testing.T) {
	f: Svf
	peak: f32
	for i in 0 ..< 200_000 {
		svf_set(&f, 20 * math.pow(1000, f64(i % 20000) / 20000), 4, 48000)
		o := svf_run(&f, 0.5 if (i / 100) % 2 == 0 else -0.5)
		peak = max(peak, abs(o.low), abs(o.band), abs(o.high))
	}
	testing.expect(t, peak < 20 && peak == peak, "bounded")
}

// The limiter never passes its ceiling, for a full-scale burst or a
// sustained overload, and leaves quiet signals unchanged (delayed).
@(test)
test_limiter :: proc(t: ^testing.T) {
	l: Limiter
	limiter_init(&l, 48000, 0.002, -1, 0.15)
	ceiling := f32(math.pow(10, -1.0 / 20))
	buf := make([]f32, 2 * 48000)
	defer delete(buf)
	for i in 0 ..< 48000 {
		burst := i >= 10000 && i < 10200
		x: f32 =
			4 * f32(math.sin(f64(i) * 0.3)) if burst || i >= 30000 else 0.3 * f32(math.sin(f64(i) * 0.1))
		buf[2 * i], buf[2 * i + 1] = x, -x
	}
	quiet := make([]f32, 2 * 4000)
	defer delete(quiet)
	copy(quiet, buf[:2 * 4000])
	limiter_run(&l, buf)
	for x in buf {testing.expectf(t, abs(x) <= ceiling * 1.00001, "over the ceiling: %v", x)}
	// The quiet start passes at unity, `delay` frames late.
	d := limiter_delay(&l)
	for i in 0 ..< 3000 {
		testing.expect(t, abs(buf[2 * (i + d)] - quiet[2 * i]) < 1e-7)
	}
	// And it recovers: after the burst the quiet signal is back at full level.
	l2: Limiter
	limiter_init(&l2, 48000, 0.002, -1, 0.15)
	b2 := make([]f32, 2 * 48000)
	defer delete(b2)
	for i in 0 ..< 200 {b2[2 * i], b2[2 * i + 1] = 4, 4}
	for i in 200 ..< 48000 {b2[2 * i] = 0.3; b2[2 * i + 1] = 0.3}
	limiter_run(&l2, b2)
	testing.expectf(t, abs(b2[2 * 47000] - 0.3) < 1e-3, "released: %v", b2[2 * 47000])
}

// The meter reads a known sine at its known loudness: a 997 Hz stereo sine
// at -20 dBFS peak is -20 LUFS (EBU Tech 3341's reference).
@(test)
test_meter_known_sine :: proc(t: ^testing.T) {
	for rate in ([]f64{48000, 44100}) {
		m: Meter
		meter_init(&m, rate)
		n := int(rate * 10)
		buf := make([]f32, 2 * n)
		defer delete(buf)
		amp := f32(math.pow(10, -20.0 / 20))
		for i in 0 ..< n {
			x := amp * f32(math.sin(2 * math.PI * 997 * f64(i) / rate))
			buf[2 * i], buf[2 * i + 1] = x, x
		}
		meter_push(&m, buf)
		got := meter_integrated(&m)
		testing.expectf(t, abs(got + 20) < 0.1, "integrated at %v Hz: %v", rate, got)
		testing.expectf(t, abs(m.momentary + 20) < 0.1, "momentary: %v", m.momentary)
	}
}

// Gating: a long silence does not drag the integrated loudness down.
@(test)
test_meter_gating :: proc(t: ^testing.T) {
	m: Meter
	meter_init(&m, 48000)
	n := 48000 * 4
	buf := make([]f32, 2 * n)
	defer delete(buf)
	for i in 0 ..< n / 2 {
		x := 0.1 * f32(math.sin(2 * math.PI * 997 * f64(i) / 48000))
		buf[2 * i], buf[2 * i + 1] = x, x
	}
	meter_push(&m, buf)
	testing.expectf(
		t,
		abs(meter_integrated(&m) + 20) < 0.5,
		"silence gated out: %v",
		meter_integrated(&m),
	)
	m2: Meter
	meter_init(&m2, 48000)
	testing.expect_value(t, meter_integrated(&m2), -math.INF_F32)
}

// Mixer-level: the master meter and limiter work through mix.
@(test)
test_mixer_limits_and_meters :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	hot := make([]f32, 48000)
	defer delete(hot)
	for &x, i in hot {x = 0.9 * f32(math.sin(2 * math.PI * 997 * f64(i) / 48000))}
	id := add_sound(m, {samples = hot, rate = 48000})
	for _ in 0 ..< 8 {play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .Music, loop = true})}
	out := make([]f32, 2 * 480)
	defer delete(out)
	worst: f32
	for _ in 0 ..< 200 {
		mix(m, out)
		for x in out {worst = max(worst, abs(x))}
	}
	testing.expectf(t, worst <= 0.8914, "never above -1 dBFS: %v", worst)
	s := stats(m)
	testing.expect(t, s.reduction < 0.2, "the limiter is working")
	testing.expect(t, s.momentary > -5 && s.momentary < 0, "loudness is reported")
}
