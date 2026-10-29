package audio

import "base:runtime"
import "core:fmt"
import "core:math"

// Analysis: what a mix was, measured. A mixer with an analysis attached calls
// it after every block (the `probe` hook, which the game never sets): it
// keeps each bus's audio, meters each bus (BS.1770), and notes what the
// engine decided about each voice (started, made virtual, made real again,
// ended, dropped). `build audiodump` replays a capture through one; the
// baselines run scripted scenarios through one. Offline only: it allocates.

Decision_Kind :: enum u8 {
	Started,
	Virtualized, // not mixed: past the real voices, or too quiet to hear
	Restored, // mixed again
	Ended, // played to its end
	Stopped, // stopped on request
	Dropped, // the play did nothing: a stream already playing, or a sound without samples
}

Virtual_Reason :: enum u8 {
	None,
	Priority, // more audible voices of higher rank than REAL_VOICES
	Inaudible, // nothing to hear (gain or a bus at zero)
}

Decision :: struct {
	frame:    u64, // the mixer frame of the block it was seen in
	kind:     Decision_Kind,
	why:      Virtual_Reason, // of a Virtualized
	voice:    Voice_Id,
	sound:    Sound_Id,
	bus:      Bus,
	priority: u8,
	voices:   u32, // playing at the time
}

Analysis :: struct {
	rate:           u32,
	frames:         int,
	keep:           bit_set[Bus], // the buses whose audio is kept
	audio:          [Bus][dynamic]f32, // interleaved stereo
	decisions:      [dynamic]Decision,
	meters:         [Bus]Meter,
	momentary_max:  [Bus]f32, // LUFS, -inf if never above -70
	peak:           [Bus]f32, // sample peak, linear
	sum_ll:         [Bus]f64, // for the correlation of the ears
	sum_rr:         [Bus]f64,
	sum_lr:         [Bus]f64,
	plays:          [Bus]u32, // sounds started on each bus
	peak_voices:    [Bus]u32, // the most voices on a bus at once
	guarded:        u32, // samples the mixer's guard zeroed
	limiter_low:    f32, // lowest gain the limiter reached
	limiter_blocks: u32, // blocks in which it reduced
	voices_peak:    u32, // the most voices at once
	real_peak:      u32,
	seen:           [MAX_VOICES]Seen,
}

@(private = "file")
Seen :: struct {
	id:      Voice_Id,
	playing: bool,
	virtual: bool,
	done:    bool,
}

// analysis_attach makes m call a on every block. keep: the buses whose
// audio is kept (the meters run on all of them).
analysis_attach :: proc(m: ^Mixer, a: ^Analysis, keep: bit_set[Bus] = {.Master}) {
	a^ = {}
	a.rate = m.rate
	a.keep = keep
	a.limiter_low = 1
	for b in Bus {
		meter_init(&a.meters[b], f64(m.rate))
		a.momentary_max[b] = -math.INF_F32
	}
	m.probe = analysis_probe
	m.probe_user = a
}

// analysis_detach stops the calls.
analysis_detach :: proc(m: ^Mixer) {
	m.probe, m.probe_user = nil, nil
}

analysis_destroy :: proc(a: ^Analysis) {
	for &x in a.audio {delete(x)}
	delete(a.decisions)
	a^ = {}
}

@(private = "file")
analysis_probe :: proc "contextless" (m: ^Mixer, user: rawptr, n: int) {
	context = runtime.default_context()
	a := (^Analysis)(user)
	a.frames += n
	for b in Bus {
		buf := m.bus_buf[b][:2 * n]
		meter_push(&a.meters[b], buf)
		a.momentary_max[b] = max(a.momentary_max[b], a.meters[b].momentary)
		if b in a.keep {append(&a.audio[b], ..buf)}
		for f in 0 ..< n {
			l, r := f64(buf[2 * f]), f64(buf[2 * f + 1])
			a.sum_ll[b] += l * l
			a.sum_rr[b] += r * r
			a.sum_lr[b] += l * r
			a.peak[b] = max(a.peak[b], abs(buf[2 * f]), abs(buf[2 * f + 1]))
		}
	}
	if m.limiter.g < 1 {a.limiter_blocks += 1}
	a.limiter_low = min(a.limiter_low, m.limiter.lowest)
	m.limiter.lowest = 1
	total, real: u32
	on_bus: [Bus]u32
	for &v, i in m.voices {
		s := &a.seen[i]
		if v.state == .Free {
			s^ = {}
			continue
		}
		if v.state == .Playing {
			total += 1
			if !v.virtual {real += 1}
			on_bus[v.bus] += 1
		}
		note :: proc(
			a: ^Analysis,
			m: ^Mixer,
			v: ^Voice,
			kind: Decision_Kind,
			why := Virtual_Reason.None,
		) {
			append(
				&a.decisions,
				Decision {
					frame = m.clock,
					kind = kind,
					why = why,
					voice = v.id,
					sound = v.sound,
					bus = v.bus,
					priority = v.priority,
				},
			)
		}
		if s.id != v.id {s^ = {
				id = v.id,
			}}
		if v.state == .Playing {
			if !s.playing {
				s.playing = true
				a.plays[v.bus] += 1
				note(a, m, &v, .Started)
			}
			// A voice waiting for its frame is not counted as virtual.
			if v.virtual != s.virtual {
				s.virtual = v.virtual
				if v.virtual {
					note(a, m, &v, .Virtualized, .Inaudible if v.key <= 0 else .Priority)
				} else if s.playing {
					note(a, m, &v, .Restored)
				}
			}
		} else if v.state == .Done && !s.done {
			s.done = true
			if v.step == 0 {
				note(a, m, &v, .Dropped)
			} else {
				note(a, m, &v, .Ended if v.reason == .Ended else .Stopped)
			}
		}
	}
	for b in Bus {a.peak_voices[b] = max(a.peak_voices[b], on_bus[b])}
	a.voices_peak = max(a.voices_peak, total)
	a.real_peak = max(a.real_peak, real)
	// Decisions made in this block know how many were playing.
	for i := len(a.decisions) - 1; i >= 0 && a.decisions[i].frame == m.clock; i -= 1 {
		if a.decisions[i].voices == 0 {a.decisions[i].voices = total}
	}
}

// analyze_replay replays a capture through m (new, with the capture's sounds
// registered) and measures it. The audio of the buses in keep is kept.
analyze_replay :: proc(
	m: ^Mixer,
	f: ^Capture_File,
	keep: bit_set[Bus],
	a: ^Analysis,
) -> (
	ok: bool,
) {
	analysis_attach(m, a, keep)
	defer analysis_detach(m)
	out := make([]f32, 2 * capture_frames(f))
	defer delete(out)
	if !capture_replay(m, f, out) {return false}
	analysis_finish(m, a)
	return true
}

// analysis_finish takes the counters that only the mixer holds.
analysis_finish :: proc(m: ^Mixer, a: ^Analysis) {
	a.guarded = m.stats.nan_guarded
}

// Report: the numbers for one bus.
Report :: struct {
	integrated:  f32, // LUFS, gated; -inf if silent
	momentary:   f32, // LUFS, the loudest 400 ms
	range:       f32, // LU, of the 400 ms blocks (EBU 3342's way, on them instead of 3 s ones)
	true_peak:   f32, // dBTP
	peak:        f32, // dBFS, of the samples
	correlation: f32, // -1 .. 1 between the ears (0 for silence)
	silent:      bool,
}

// analysis_report: the numbers of bus b. Needs its audio kept for the true peak.
analysis_report :: proc(a: ^Analysis, b: Bus) -> (r: Report) {
	r.integrated = meter_integrated(&a.meters[b])
	r.momentary = a.momentary_max[b]
	r.range = loudness_range(&a.meters[b])
	r.peak = db(a.peak[b])
	r.true_peak = r.peak
	if b in a.keep {r.true_peak = db(true_peak(a.audio[b][:]))}
	r.silent = a.peak[b] == 0
	if den := math.sqrt(a.sum_ll[b] * a.sum_rr[b]); den > 0 {
		r.correlation = f32(a.sum_lr[b] / den)
	}
	return
}

@(private)
db :: proc(x: f32) -> f32 {
	if x <= 0 {return -math.INF_F32}
	return 20 * math.log10(x)
}

// loudness_range: the spread, in LU, between the 10th and 95th percentile of
// the 400 ms blocks that are within 20 LU of the gated mean.
loudness_range :: proc(m: ^Meter) -> f32 {
	total: f64
	n: u64
	for b in 0 ..< METER_BINS {
		total += m.energy[b]
		n += u64(m.bins[b])
	}
	if n == 0 {return 0}
	floor := lufs(total / f64(n)) - 20
	kept: u64
	for b in 0 ..< METER_BINS {
		if f64(b) / 10 - 70 >= floor {kept += u64(m.bins[b])}
	}
	if kept == 0 {return 0}
	at :: proc(m: ^Meter, floor: f64, kept: u64, p: f64) -> f64 {
		target := p * f64(kept)
		seen: f64
		for b in 0 ..< METER_BINS {
			if f64(b) / 10 - 70 < floor {continue}
			seen += f64(m.bins[b])
			if seen >= target {return f64(b) / 10 - 70}
		}
		return floor
	}
	return f32(at(m, floor, kept, 0.95) - at(m, floor, kept, 0.10))
}

// true_peak: the largest value of interleaved stereo x between its samples
// too, found with the limiter's own 8x interpolation filter; linear.
true_peak :: proc(x: []f32) -> f32 {
	l: Limiter
	limiter_init(&l, 48000, 0.002, -1, 0.15)
	frames := len(x) / 2
	best: f32
	for v in x {best = max(best, abs(v))}
	// Largest sample of the 32 around each frame, so the filter runs only where
	// it could beat `best`.
	for f in 0 ..< frames {
		lo, hi := max(f - TP_TAPS / 2 + 1, 0), min(f + TP_TAPS / 2, frames - 1)
		bound: f32
		for k in lo ..= hi {bound = max(bound, abs(x[2 * k]), abs(x[2 * k + 1]))}
		if bound * l.l1 <= best {continue}
		for c in 0 ..< 2 {
			for p in 0 ..< TP_POINTS {
				acc: f32
				for k in 0 ..< TP_TAPS {
					i := f - TP_TAPS / 2 + 1 + k
					if i < 0 || i >= frames {continue}
					acc += l.tp[p][k] * x[2 * i + c]
				}
				best = max(best, abs(acc))
			}
		}
	}
	return best
}

// BANDS: third octaves from 50 Hz to 12.5 kHz, for the baselines' spectra.
BANDS :: 24

// third_octaves: dB (power) of interleaved stereo x in each of BANDS bands
// from 50 Hz, on the mono sum.
third_octaves :: proc(x: []f32, rate: u32) -> (bands: [BANDS]f64) {
	frames := len(x) / 2
	n := 1
	for n < frames {n <<= 1}
	re := make([]f64, n)
	im := make([]f64, n)
	defer {delete(re); delete(im)}
	for i in 0 ..< frames {re[i] = 0.5 * f64(x[2 * i] + x[2 * i + 1])}
	fft(re, im)
	for b in 0 ..< BANDS {
		centre := 50 * math.pow(2, f64(b) / 3)
		lo := int(centre / math.pow(2, 1.0 / 6) * f64(n) / f64(rate))
		hi := min(int(centre * math.pow(2, 1.0 / 6) * f64(n) / f64(rate)), n / 2)
		sum: f64
		for k in lo ..< hi {sum += re[k] * re[k] + im[k] * im[k]}
		bands[b] = 10 * math.log10(max(sum, 1e-20) / f64(n) / f64(n))
	}
	return
}

// fft: in-place radix-2 on re, im (length a power of two).
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

// decay_time: milliseconds from the loudest 10 ms of x[from:to] (frames) until
// 10 ms windows stay 30 dB under it; the length of the span if they never do.
decay_time :: proc(x: []f32, rate: u32, from, to: int) -> f64 {
	win := max(int(rate) / 100, 1)
	lo, hi := clamp(from, 0, len(x) / 2), clamp(to, 0, len(x) / 2)
	count := (hi - lo) / win
	if count < 2 {return 0}
	level := make([]f64, count)
	defer delete(level)
	top, at := 0.0, 0
	for w in 0 ..< count {
		sum: f64
		for f in lo + w * win ..< lo + (w + 1) * win {
			sum += f64(x[2 * f]) * f64(x[2 * f]) + f64(x[2 * f + 1]) * f64(x[2 * f + 1])
		}
		level[w] = sum / f64(win)
		if level[w] > top {top, at = level[w], w}
	}
	if top == 0 {return 0}
	limit := top * 1e-3 // -30 dB
	last := at
	for w in at ..< count {
		if level[w] > limit {last = w}
	}
	return f64(last + 1 - at) * 10
}

// Row: one command of a capture, in words (the dump's timeline).
Row :: struct {
	frame:   u64,
	text:    string, // temp allocator unless said
	sound:   int, // of a play, else -1
	bus:     Bus, // of a play or a bus command
	is_play: bool,
}

// voice_label: a handle as the dump writes it: slot, generation.
voice_label :: proc(id: Voice_Id) -> string {
	return fmt.tprintf("v%d.%d", id & 0xff, id >> 8)
}

// capture_rows describes every command of f.
capture_rows :: proc(f: ^Capture_File, allocator := context.allocator) -> []Row {
	rows := make([dynamic]Row, 0, len(f.records), allocator)
	ms :: proc(frames: u32, rate: u32) -> f64 {return 1000 * f64(frames) / f64(rate)}
	rate := f.header.rate
	for r in f.records {
		if r.frames > 0 {continue}
		row := Row {
			frame = r.frame,
			sound = -1,
		}
		if r.drops > 0 {
			row.text = fmt.aprintf(
				"DROPPED %d commands (ring full, no free handle or a busy stream)",
				r.drops,
				allocator = allocator,
			)
			append(&rows, row)
			continue
		}
		switch c in r.cmd {
		case Play_Cmd:
			p := c.play
			buf: [SOUND_NAME_LEN + 8]u8
			name := sound_name(&f.sounds[p.sound].name, int(p.sound), buf[:])
			row.is_play, row.sound, row.bus = true, int(p.sound), p.bus
			extra := ""
			if p.loop {extra = fmt.tprintf("%s loop", extra)}
			if p.start_frame != 0 {extra = fmt.tprintf("%s at frame %d", extra, p.start_frame)}
			if p.fade_in > 0 {extra = fmt.tprintf("%s fade-in %.0f ms", extra, 1000 * p.fade_in)}
			if p.cutoff > 0 {extra = fmt.tprintf("%s cutoff %.0f Hz", extra, p.cutoff)}
			row.text = fmt.aprintf(
				"play    %-18s %s  bus %v  gain %.2f/%.2f  pitch %.2f  priority %d%s",
				name,
				voice_label(c.id),
				p.bus,
				p.gain[0],
				p.gain[1],
				p.pitch if p.pitch > 0 else 1,
				p.priority,
				extra,
				allocator = allocator,
			)
		case Voice_Param:
			row.text = fmt.aprintf(
				"%-7v %s  %.3f %.3f",
				c.which,
				voice_label(c.id),
				c.value[0],
				c.value[1],
				allocator = allocator,
			)
		case Stop_Cmd:
			row.text = fmt.aprintf(
				"stop    %s  fade %.0f ms",
				voice_label(c.id),
				ms(c.frames, rate),
				allocator = allocator,
			)
		case Fade_Cmd:
			row.text = fmt.aprintf(
				"fade    %s  to %.2f over %.0f ms",
				voice_label(c.id),
				c.to,
				ms(c.frames, rate),
				allocator = allocator,
			)
		case Bus_Cmd:
			row.bus = c.bus
			row.text = fmt.aprintf(
				"bus     %v %v %.3f over %.0f ms",
				c.bus,
				c.which,
				c.value,
				ms(c.frames, rate),
				allocator = allocator,
			)
		case Duck_Cmd:
			row.text = fmt.aprintf(
				"duck    rule %d: %v ducks %v to %.2f (%s)",
				c.index,
				c.duck.trigger,
				c.duck.target,
				c.duck.amount,
				"on" if c.duck.active else "off",
				allocator = allocator,
			)
		case Snapshot_Cmd:
			row.text = fmt.aprintf(
				"snapshot over %.0f ms",
				ms(c.frames, rate),
				allocator = allocator,
			)
		case Reverb_Cmd:
			row.text = fmt.aprintf(
				"reverb  rt60 %.2f s  damping %.2f  wet %.2f  early %.2f",
				c.rt60,
				c.damping,
				c.wet,
				c.early,
				allocator = allocator,
			)
		case Listener_Cmd:
			row.text = fmt.aprintf("listener %v", c.options, allocator = allocator)
		}
		append(&rows, row)
	}
	return rows[:]
}
