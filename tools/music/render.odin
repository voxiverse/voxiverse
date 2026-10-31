package music_tool

import "core:math"

import "client:audio"
import "common:base"

RATE :: 48000
FADE_SECONDS :: 0.02 // an exclusive class's cut
MIN_RELEASE :: 0.001
SILENCE :: 1e-5 // -100 dB: where a release ends

Voice :: struct {
	zone:        Zone_Params,
	start:       int, // frames
	release:     int, // frame the note is let go (pedal included)
	cut:         int, // frame an exclusive class cuts it (-1: never)
	gain:        f64,
	left, right: f64,
	step:        f64,
	class_key:   int, // part * 65536 + exclusive class
}

// Envelope: the volume envelope of a voice, one frame at a time. The attack
// is linear in amplitude; the decay and the release fall in dB at 100 dB per
// their time (so a release ends at -100 dB and passes -60 dB at 0.6 of it).
Env_Phase :: enum {
	Delay,
	Attack,
	Hold,
	Decay,
	Sustain,
	Release,
	Done,
}

Envelope :: struct {
	phase:               Env_Phase,
	n:                   int, // frames in the phase
	delay, attack, hold: int,
	sustain:             f64,
	decay_k, release_k:  f64, // per-frame factors
	gain:                f64,
}

envelope_init :: proc(e: ^Envelope, z: Zone_Params, rate: f64) {
	e^ = {}
	e.delay, e.attack, e.hold =
		int(z.delay * rate + 0.5), int(z.attack * rate + 0.5), int(z.hold * rate + 0.5)
	e.sustain = z.sustain
	e.decay_k = 0 if z.decay * rate < 1 else math.pow(10, -5 / (z.decay * rate))
	e.release_k = math.pow(10, -5 / (max(z.release, MIN_RELEASE) * rate))
	e.phase = .Delay
	if e.delay == 0 {envelope_enter(e, .Attack)}
}

@(private = "file")
envelope_enter :: proc(e: ^Envelope, phase: Env_Phase) {
	e.phase = phase
	e.n = 0
	#partial switch phase {
	case .Attack:
		if e.attack == 0 {e.gain = 1; envelope_enter(e, .Hold)}
	case .Hold:
		e.gain = 1
		if e.hold == 0 {envelope_enter(e, .Decay)}
	case .Decay:
		if e.decay_k == 0 || e.sustain >= 1 {
			e.gain = e.sustain
			envelope_enter(e, .Sustain)
		}
	}
}

envelope_release :: proc(e: ^Envelope) {
	if e.phase == .Delay || e.phase == .Done {
		e.phase = .Done
		return
	}
	e.phase = .Release
}

// envelope_next returns the gain of the next frame.
envelope_next :: proc(e: ^Envelope) -> f64 {
	switch e.phase {
	case .Delay:
		e.n += 1
		if e.n >= e.delay {envelope_enter(e, .Attack)}
		return 0
	case .Attack:
		e.n += 1
		e.gain = f64(e.n) / f64(e.attack)
		if e.n >= e.attack {envelope_enter(e, .Hold)}
		return e.gain
	case .Hold:
		e.n += 1
		if e.n >= e.hold {envelope_enter(e, .Decay)}
		return 1
	case .Decay:
		e.gain *= e.decay_k
		if e.gain <= e.sustain {
			e.gain = e.sustain
			e.phase = .Sustain
		}
		return e.gain
	case .Sustain:
		return e.gain
	case .Release:
		e.gain *= e.release_k
		if e.gain < SILENCE {e.phase = .Done}
		return e.gain
	case .Done:
		return 0
	}
	return 0
}

// frames_of maps ticks to a frame (fractional) through the tempo map.
frame_of :: proc(p: ^Piece, tick: f64, rate: f64) -> f64 {
	return ticks_to_seconds(p, tick) * rate
}

@(private = "file")
balance :: proc(pan: f32) -> (l, r: f64) {
	l, r = 1, 1
	c := math.cos(f64(abs(pan)) * math.PI / 2)
	if pan > 0 {l = c} else {r = c}
	return
}

// render plays the piece through the soundfont: interleaved stereo at `rate`,
// the dry sound, then the reverb added, to the end of the last voice and the
// reverb's tail. Two renders of the same input are identical.
render :: proc(p: ^Piece, sf: ^Soundfont, rate := RATE) -> []f32 {
	rf := f64(rate)
	rng := base.rng_make(p.seed)
	end_frame := int(frame_of(p, f64(p.end), rf) + 0.5)

	// The pedal's down spans per part, in frames.
	Span :: struct {
		from, to: int,
	}
	spans := make([][dynamic]Span, len(p.parts))
	for e in p.pedals {
		f := int(frame_of(p, f64(e.at), rf) + 0.5)
		sp := &spans[e.part]
		if e.down {
			if len(sp) == 0 || sp[len(sp) - 1].to >= 0 {append(sp, Span{f, -1})}
		} else if len(sp) > 0 && sp[len(sp) - 1].to < 0 {
			sp[len(sp) - 1].to = f
		}
	}
	presets := make([]int, len(p.parts))
	for part, i in p.parts {presets[i] = sf_find_preset(sf, part.bank, part.program)}

	voices: [dynamic]Voice
	zones: [dynamic]Zone_Params
	for n in p.notes {
		jitter := base.rng_f32_range(&rng, -p.humanize_ms, p.humanize_ms)
		vj := base.rng_int_range(&rng, -int(p.humanize_vel), int(p.humanize_vel) + 1)
		vel := clamp(int(n.velocity) + vj, 1, 127)
		from := frame_of(p, f64(n.start), rf)
		to := frame_of(p, f64(n.start + n.length), rf)
		start := max(int(from + f64(jitter) * rf / 1000 + 0.5), 0)
		off := start + max(int(to - from + 0.5), 1)
		release := off
		for s in spans[n.part] {
			if off >= s.from && (s.to < 0 || off < s.to) {
				release = max(end_frame, off) if s.to < 0 else s.to
				break
			}
		}
		part := p.parts[n.part]
		clear(&zones)
		sf_zones(sf, presets[n.part], int(n.key), vel, &zones)
		bl, br := balance(part.pan)
		pg := math.pow(10, f64(part.volume_db) / 20)
		for z in zones {
			ang := (z.pan + 1) * math.PI / 4
			v := Voice {
				zone      = z,
				start     = start,
				release   = release,
				cut       = -1,
				gain      = pg * math.pow(10, z.gain_db / 20),
				left      = math.cos(ang) * bl,
				right     = math.sin(ang) * br,
				step      = math.pow(2, z.semitones / 12) * z.rate / rf,
				class_key = (int(n.part) << 16 | z.exclusive) if z.exclusive != 0 else -1,
			}
			append(&voices, v)
		}
	}
	// An exclusive class: a voice is cut where the next of its (part, class) starts.
	{
		next := make(map[int]int)
		for i := len(voices) - 1; i >= 0; i -= 1 {
			k := voices[i].class_key
			if k < 0 {continue}
			if at, ok := next[k]; ok && at > voices[i].start {voices[i].cut = at}
			next[k] = voices[i].start
		}
	}

	table := new(audio.Sinc_Table)
	audio.sinc_table_init(table)
	left, right: [dynamic]f64
	for &v in voices {render_voice(&v, sf, table, rf, &left, &right)}

	reverb_frames := 0
	if p.reverb_wet > 0 {reverb_frames = int(f64(p.reverb_rt60) * 1.7 * rf)}
	frames := len(left) + reverb_frames
	dry := make([]f32, 2 * frames)
	for i in 0 ..< len(left) {
		dry[2 * i] = f32(left[i])
		dry[2 * i + 1] = f32(right[i])
	}
	if p.reverb_wet <= 0 {return dry}
	out := make([]f32, 2 * frames)
	copy(out, dry)
	r := new(audio.Reverb)
	audio.reverb_init(r, rf)
	audio.reverb_set(r, p.reverb_rt60, 0.3, p.reverb_wet, 0.3)
	audio.reverb_run(r, dry, out)
	return out
}

@(private = "file")
render_voice :: proc(
	v: ^Voice,
	sf: ^Soundfont,
	table: ^audio.Sinc_Table,
	rate: f64,
	left, right: ^[dynamic]f64,
) {
	z := v.zone
	s := sf.data[z.start:z.end]
	loop_start, loop_end := z.loop_start - z.start, z.loop_end - z.start
	looping := z.mode != 0
	pos: f64
	env: Envelope
	envelope_init(&env, z, rate)
	filter: audio.Svf
	use_filter := z.fc_cents < 13500
	if use_filter {
		hz := 8.176 * math.pow(2, z.fc_cents / 1200)
		audio.svf_set(&filter, hz, 0.7071 * math.pow(10, z.q_cb / 200), rate)
	}
	fade_n := int(FADE_SECONDS * rate)
	fade := -1 // frames into a cut's fade
	released := false
	for f := v.start; f - v.start < 60 * int(rate); f += 1 {
		if !released && f >= v.release {
			released = true
			envelope_release(&env)
			if z.mode == 3 {looping = false}
		}
		if v.cut >= 0 && f >= v.cut && fade < 0 {fade = 0}
		g := envelope_next(&env)
		if env.phase == .Done {break}
		if g != 0 {
			x := audio.sinc_read(table, s, pos, v.step, loop_start, loop_end, looping)
			if use_filter {x = audio.svf_lowpass(&filter, x)}
			a := f64(x) * g * v.gain
			if fade >= 0 {
				a *= 1 - f64(fade) / f64(fade_n)
				fade += 1
				if fade >= fade_n {break}
			}
			for len(left) <= f {
				append(left, 0)
				append(right, 0)
			}
			left[f] += a * v.left
			right[f] += a * v.right
		}
		if env.phase != .Delay {
			pos += v.step
			if looping {
				for pos >= f64(loop_end) {pos -= f64(loop_end - loop_start)}
			} else if pos >= f64(len(s)) {
				break
			}
		}
	}
}
