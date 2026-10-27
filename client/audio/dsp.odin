package audio

import "core:math"

// DSP blocks that need no mixer: a state-variable filter, a look-ahead
// limiter and a BS.1770 loudness meter. All run on the audio thread (or
// offline in tests): no allocation, no locks, state in f64 where it
// accumulates.

// Svf: a zero-delay-feedback state-variable filter (Zavalishin). Stable
// when its cutoff is swept, and its response is the analog prototype's at
// the warped frequency (the tests check it against the formula).
Svf :: struct {
	ic1, ic2:   f64,
	a1, a2, a3: f64,
	k:          f64, // 1 / Q
}

// svf_set sets the cutoff (Hz) and Q of f for sample rate `rate`; the
// state is kept, so it can be called every block.
svf_set :: proc "contextless" (f: ^Svf, cutoff, q: f64, rate: f64) {
	g := math.tan(math.PI * clamp(cutoff, 1, 0.49 * rate) / rate)
	f.k = 1 / q
	f.a1 = 1 / (1 + g * (g + f.k))
	f.a2 = g * f.a1
	f.a3 = g * f.a2
}

Svf_Out :: struct {
	low, band, high: f32,
}

svf_run :: #force_inline proc "contextless" (f: ^Svf, x: f32) -> Svf_Out {
	v0 := f64(x)
	v3 := v0 - f.ic2
	v1 := f.a1 * f.ic1 + f.a2 * v3
	v2 := f.ic2 + f.a2 * f.ic1 + f.a3 * v3
	f.ic1 = 2 * v1 - f.ic1
	f.ic2 = 2 * v2 - f.ic2
	return {f32(v2), f32(v1), f32(v0 - f.k * v1 - v2)}
}

svf_lowpass :: #force_inline proc "contextless" (f: ^Svf, x: f32) -> f32 {
	return svf_run(f, x).low
}

// svf_flush zeroes state too small to matter (denormals are slow).
svf_flush :: proc "contextless" (f: ^Svf) {
	if abs(f.ic1) < 1e-25 {f.ic1 = 0}
	if abs(f.ic2) < 1e-25 {f.ic2 = 0}
}

// Limiter: look-ahead peak limiter on a stereo pair. The gain is the
// running minimum of the wanted gain over the look-ahead window, averaged
// over the same window (so it is already down when the peak arrives and
// never steps), and recovers with a release time. The peak it watches is the
// true peak: the signal 8x oversampled by a windowed-sinc FIR (seven
// interpolated points between samples), so what a DAC reconstructs between
// samples stays under `ceiling` too. The output is delayed by `limiter_delay`
// frames.
LIMITER_MAX :: 256
TP_POINTS :: 7 // between two samples
TP_TAPS :: 32 // per interpolated point
TP_LAG :: 16 // the detector sees a point this many frames after it happened

Limiter :: struct {
	n:       int, // window, frames
	ceiling: f32, // linear
	release: f32, // per-frame recovery of the gap to 1
	g:       f32, // gain applied last
	t:       u64, // frames seen
	delay:   [LIMITER_MAX + TP_LAG][2]f32,
	hist:    [2][64]f32, // the last input samples, per channel
	l1:      f32, // the largest sum of |taps| of any row of tp: a point is at most this times the largest sample
	recent:  [8]f32, // largest |sample| in each of the last 8 groups of 8 frames (both channels)
	group:   int, // frames into the current group
	tp:      [TP_POINTS][TP_TAPS]f32, // FIR for the points at 1/8 .. 7/8
	ring:    [LIMITER_MAX]f32, // the window-minimum history, for the average
	sum:     f64,
	dq_t:    [LIMITER_MAX]u64, // monotonic deque of (frame, wanted gain)
	dq_g:    [LIMITER_MAX]f32,
	head:    u64,
	tail:    u64,
	lowest:  f32, // the lowest gain since taken (stats)
}

// limiter_init: look-ahead `lookahead_s` seconds (at least 2 frames),
// ceiling in dBFS, release in seconds.
limiter_init :: proc "contextless" (
	l: ^Limiter,
	rate: f64,
	lookahead_s, ceiling_db, release_s: f64,
) {
	l^ = {}
	l.n = clamp(int(rate * lookahead_s), 2, LIMITER_MAX)
	l.ceiling = f32(math.pow(10, ceiling_db / 20))
	l.release = f32(1 - math.exp(-1 / (release_s * rate)))
	l.g = 1
	l.lowest = 1
	for i in 0 ..< l.n {l.ring[i] = 1}
	l.sum = f64(l.n)
	for p in 0 ..< TP_POINTS {
		frac := f64(p + 1) / (TP_POINTS + 1)
		for k in 0 ..< TP_TAPS {
			u := f64(k - TP_TAPS / 2 + 1) - frac // taps are samples a-15 .. a+16
			x := math.PI * u
			l.tp[p][k] = f32(math.sin(x) / x * kaiser(u / (TP_TAPS / 2), 6))
		}
		sum: f32
		for k in 0 ..< TP_TAPS {sum += abs(l.tp[p][k])}
		l.l1 = max(l.l1, sum)
	}
}

// limiter_set_ceiling changes the ceiling (dBFS) while running.
limiter_set_ceiling :: proc "contextless" (l: ^Limiter, ceiling_db: f64) {
	l.ceiling = f32(math.pow(10, ceiling_db / 20))
}

// limiter_delay: how many frames later the input comes out.
limiter_delay :: proc "contextless" (l: ^Limiter) -> int {
	return l.n - 1 + TP_LAG
}

// limiter_run limits interleaved stereo in place.
limiter_run :: proc "contextless" (l: ^Limiter, buf: []f32) {
	n := u64(l.n)
	span := u64(l.n + TP_LAG)
	for f in 0 ..< len(buf) / 2 {
		x := [2]f32{buf[2 * f], buf[2 * f + 1]}
		peak: f32
		// The points between samples cannot pass the ceiling when the largest of
		// the last 32..39 samples times the FIR's largest gain does not: then
		// only the lagged sample itself is looked at (the same answer, without
		// the FIR; the loudest mixes are the only ones that need it).
		l.recent[(l.t / 8) & 7] = max(
			l.recent[(l.t / 8) & 7] if l.group != 0 else 0,
			abs(x[0]),
			abs(x[1]),
		)
		l.group = (l.group + 1) & 7
		bound: f32
		for r in l.recent {bound = max(bound, r)}
		interpolate := bound * l.l1 > l.ceiling
		for c in 0 ..< 2 {
			h := &l.hist[c]
			h[l.t & 63] = x[c]
			peak = max(peak, abs(h[(l.t - TP_LAG) & 63]))
			if !interpolate {continue}
			for p in 0 ..< TP_POINTS {
				acc: f32
				for k in 0 ..< TP_TAPS {acc += l.tp[p][k] * h[(l.t - (TP_TAPS - 1) + u64(k)) & 63]}
				peak = max(peak, abs(acc))
			}
		}
		want: f32 = 1
		if peak > l.ceiling {want = l.ceiling / peak}
		// The window minimum.
		for l.tail != l.head && l.dq_g[(l.tail - 1) % LIMITER_MAX] >= want {l.tail -= 1}
		l.dq_t[l.tail % LIMITER_MAX] = l.t
		l.dq_g[l.tail % LIMITER_MAX] = want
		l.tail += 1
		for l.dq_t[l.head % LIMITER_MAX] + n <= l.t {l.head += 1}
		low := l.dq_g[l.head % LIMITER_MAX]
		// Averaged over the window: never above the gain wanted for the sample
		// that is about to come out.
		slot := l.t % n
		l.sum += f64(low) - f64(l.ring[slot])
		l.ring[slot] = low
		average := f32(l.sum / f64(n))
		l.g = min(average, l.g + (1 - l.g) * l.release)
		l.delay[l.t % span] = x
		out := l.delay[(l.t + 1) % span]
		buf[2 * f] = out[0] * l.g
		buf[2 * f + 1] = out[1] * l.g
		l.lowest = min(l.lowest, l.g)
		l.t += 1
	}
	if abs(1 - l.g) < 1e-9 {l.g = 1}
}

// Meter: loudness after ITU-R BS.1770 / EBU R128 (K-weighting, 400 ms
// blocks every 100 ms, the -70 LUFS and relative -10 LU gates), for stereo.
// The integrated figure comes from a histogram of 0.1 LU bins, so the meter
// runs forever in fixed memory.
METER_BINS :: 800 // -70 .. +10 LUFS

Biquad :: struct {
	b0, b1, b2, a1, a2: f64,
	z1, z2:             f64,
}

Meter :: struct {
	shelf, high: [2]Biquad, // per channel
	sub:         int, // frames in a 100 ms sub-block
	filled:      int,
	sum:         f64, // K-weighted squares, both channels, in the sub-block
	last:        [4]f64, // mean squares of the last four sub-blocks
	count:       int, // sub-blocks seen
	momentary:   f32, // LUFS of the last 400 ms (-inf until there is one)
	bins:        [METER_BINS]u32,
	energy:      [METER_BINS]f64,
}

@(private)
biquad_step :: #force_inline proc "contextless" (b: ^Biquad, x: f64) -> f64 {
	y := b.b0 * x + b.z1
	b.z1 = b.b1 * x - b.a1 * y + b.z2
	b.z2 = b.b2 * x - b.a2 * y
	return y
}

meter_init :: proc "contextless" (m: ^Meter, rate: f64) {
	m^ = {}
	m.sub = max(int(rate / 10), 1)
	m.momentary = -math.INF_F32
	// The two K-weighting stages, as libebur128 derives them for any rate.
	{
		f0 :: 1681.974450955533
		gain_db :: 3.999843853973347
		q :: 0.7071752369554196
		k := math.tan(math.PI * f0 / rate)
		vh := math.pow(10, gain_db / 20)
		vb := math.pow(vh, 0.4996667741545416)
		a0 := 1 + k / q + k * k
		s := Biquad {
			b0 = (vh + vb * k / q + k * k) / a0,
			b1 = 2 * (k * k - vh) / a0,
			b2 = (vh - vb * k / q + k * k) / a0,
			a1 = 2 * (k * k - 1) / a0,
			a2 = (1 - k / q + k * k) / a0,
		}
		m.shelf = {s, s}
	}
	{
		f0 :: 38.13547087602444
		q :: 0.5003270373238773
		k := math.tan(math.PI * f0 / rate)
		a0 := 1 + k / q + k * k
		h := Biquad {
			b0 = 1,
			b1 = -2,
			b2 = 1,
			a1 = 2 * (k * k - 1) / a0,
			a2 = (1 - k / q + k * k) / a0,
		}
		m.high = {h, h}
	}
}

@(private)
lufs :: proc "contextless" (mean_square: f64) -> f64 {
	return -0.691 + 10 * math.log10(max(mean_square, 1e-30))
}

// meter_push measures interleaved stereo.
meter_push :: proc "contextless" (m: ^Meter, buf: []f32) {
	for f in 0 ..< len(buf) / 2 {
		for c in 0 ..< 2 {
			y := biquad_step(&m.high[c], biquad_step(&m.shelf[c], f64(buf[2 * f + c])))
			m.sum += y * y
		}
		m.filled += 1
		if m.filled < m.sub {continue}
		m.last[m.count % 4] = m.sum / f64(m.sub)
		m.count += 1
		m.sum, m.filled = 0, 0
		if m.count < 4 {continue}
		ms := (m.last[0] + m.last[1] + m.last[2] + m.last[3]) / 4
		l := lufs(ms)
		m.momentary = f32(l) if ms > 0 else -math.INF_F32
		if l > -70 {
			bin := clamp(int((l + 70) * 10), 0, METER_BINS - 1)
			m.bins[bin] += 1
			m.energy[bin] += ms
		}
	}
}

// meter_integrated: loudness of everything measured, gated; -inf when
// there was nothing above the absolute gate.
meter_integrated :: proc "contextless" (m: ^Meter) -> f32 {
	total: f64
	n: u64
	for b in 0 ..< METER_BINS {
		total += m.energy[b]
		n += u64(m.bins[b])
	}
	if n == 0 {return -math.INF_F32}
	threshold := lufs(total / f64(n)) - 10
	total, n = 0, 0
	for b in 0 ..< METER_BINS {
		if f64(b) / 10 - 70 < threshold {continue}
		total += m.energy[b]
		n += u64(m.bins[b])
	}
	if n == 0 {return -math.INF_F32}
	return f32(lufs(total / f64(n)))
}
