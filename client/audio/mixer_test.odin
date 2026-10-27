package audio

import "core:math"
import "core:testing"

@(private = "file")
peak :: proc(out: []f32, channel: int) -> f32 {
	p: f32
	for i := channel; i < len(out); i += 2 {p = max(p, abs(out[i]))}
	return p
}

@(private = "file")
new_mixer :: proc(rate: u32) -> ^Mixer {
	m := new(Mixer)
	mixer_init(m, rate)
	return m
}

// mix_frames mixes that many frames (in blocks of the device's size) and
// returns them; the caller deletes.
@(private = "file")
mix_frames :: proc(m: ^Mixer, frames: int) -> []f32 {
	out := make([]f32, 2 * frames)
	for at := 0; at < frames; at += 480 {
		mix(m, out[2 * at:][:2 * min(480, frames - at)])
	}
	return out
}

@(private = "file")
constant :: proc(n: int, v: f32) -> []f32 {
	s := make([]f32, n)
	for &x in s {x = v}
	return s
}

// A sound plays once, at its pitch, through the gains it was given, and
// stops at its end (everything arrives `latency` frames late, the limiter's
// look-ahead).
@(test)
test_mixer_plays_once :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	ones := constant(4800, 0.5) // 0.1 s at 48 kHz
	defer delete(ones)
	id := add_sound(m, {samples = ones, rate = 48000})
	testing.expect(t, play(m, {sound = id, gain = {1, 0.25}, pitch = 1}) != 0)
	late := latency(m)
	out := mix_frames(m, 9600)
	defer delete(out)
	testing.expect(
		t,
		abs(out[2 * late] - 0.5) < 1e-6 && abs(out[2 * late + 1] - 0.125) < 1e-6,
		"gains apply",
	)
	testing.expect(
		t,
		out[2 * (4790 + late)] != 0 && out[2 * (4800 + late)] == 0,
		"stops at its end",
	)
	out2 := mix_frames(m, 9600)
	defer delete(out2)
	testing.expect_value(t, peak(out2, 0), 0) // and does not play again

	// Twice the pitch: half as long.
	play(m, {sound = id, gain = {1, 1}, pitch = 2})
	out3 := mix_frames(m, 9600)
	defer delete(out3)
	testing.expect(t, out3[2 * (2390 + late)] != 0 && out3[2 * (2400 + late)] == 0)
}

// The command ring never blocks: a flood is dropped and counted, not waited on.
@(test)
test_mixer_command_ring :: proc(t: ^testing.T) {
	m := new_mixer(1000)
	defer free(m)
	id := add_sound(m, {samples = []f32{1, 1, 1, 1}, rate = 1000})
	for _ in 0 ..< COMMAND_RING + 10 {set_bus_gain(m, .Music, 0.5)}
	testing.expect_value(t, m.dropped, 10)
	out: [8]f32
	mix(m, out[:])
	testing.expect(
		t,
		play(m, {sound = id, gain = {1, 1}, pitch = 1}) != 0,
		"room again once mixed",
	)
}

// Handles: a stale one does nothing, a stopped voice is silent at once, the
// end comes back on the return ring, and a slot is not reused before it has.
@(test)
test_voice_handles :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	long := constant(48000, 0.5)
	defer delete(long)
	id := add_sound(m, {samples = long, rate = 48000})
	a := play(m, {sound = id, gain = {1, 1}, pitch = 1})
	testing.expect(t, alive(m, a))
	out := mix_frames(m, 960)
	delete(out)
	late := latency(m)
	stop(m, a)
	out = mix_frames(m, 960)
	testing.expect(
		t,
		out[2 * late] == 0 || out[0] == 0.5,
		"the limiter's tail is all that is left",
	)
	for i in 2 * (late + 1) ..< len(out) {testing.expect_value(t, out[i], 0)}
	delete(out)
	e, ok := poll(m)
	testing.expect(t, ok && e.voice == a && e.reason == .Stopped, "the stop is reported")
	testing.expect(t, !alive(m, a))
	b := play(m, {sound = id, gain = {1, 1}, pitch = 1})
	testing.expect(t, b != a, "a new generation")
	set_voice_gain(m, a, {0, 0}) // stale: does nothing to b
	stop(m, a)
	out = mix_frames(m, 960)
	defer delete(out)
	testing.expect(t, out[2 * (late + 100)] > 0.4, "b plays on")
	testing.expect(t, alive(m, b))
	// Played to its end: reported as Ended.
	out2 := mix_frames(m, 48000)
	defer delete(out2)
	e, ok = poll(m)
	testing.expect(t, ok && e.voice == b && e.reason == .Ended)
}

// A sound with no handle left is dropped (and counted), and handles come
// back as the ends are read.
@(test)
test_voice_table_full :: proc(t: ^testing.T) {
	m := new_mixer(1000)
	defer free(m)
	long := constant(10_000, 0.01)
	defer delete(long)
	id := add_sound(m, {samples = long, rate = 1000})
	ids: [MAX_VOICES]Voice_Id
	for i in 0 ..< MAX_VOICES {
		ids[i] = play(m, {sound = id, gain = {0.1, 0.1}, pitch = 1})
		testing.expect(t, ids[i] != 0)
		if i % COMMAND_RING == COMMAND_RING - 1 {
			out: [64]f32
			mix(m, out[:])
		}
	}
	testing.expect_value(t, play(m, {sound = id, gain = {1, 1}, pitch = 1}), 0)
	testing.expect_value(t, m.dropped, 1)
	stop(m, ids[5])
	out: [64]f32
	mix(m, out[:])
	testing.expect(
		t,
		play(m, {sound = id, gain = {1, 1}, pitch = 1}) != 0,
		"room after an end is read",
	)
}

// A loop plays gapless: 100 loops of a whole number of cycles equal the
// sine, sample for sample.
@(test)
test_loop_gapless :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	N :: 480
	cycle := make([]f32, N)
	defer delete(cycle)
	for i in 0 ..< N {cycle[i] = 0.5 * f32(math.sin(2 * math.PI * 5 * f64(i) / N))}
	id := add_sound(m, {samples = cycle, rate = 48000})
	play(m, {sound = id, gain = {1, 1}, pitch = 1, loop = true})
	frames := 100 * N
	out := mix_frames(m, frames)
	defer delete(out)
	late := latency(m)
	worst: f32
	for f in late ..< frames {
		want := cycle[(f - late) % N]
		worst = max(worst, abs(out[2 * f] - want))
	}
	testing.expectf(t, worst < 1e-6, "loops seamlessly (worst error %v)", worst)
	// Pitched by a fraction, the seam still has no step: the largest jump
	// between samples stays near the sine's own slope.
	m2 := new_mixer(48000)
	defer free(m2)
	id2 := add_sound(m2, {samples = cycle, rate = 48000})
	play(m2, {sound = id2, gain = {1, 1}, pitch = 1.0137, loop = true})
	out2 := mix_frames(m2, frames)
	defer delete(out2)
	jump: f32
	for f in late + 1 ..< frames {jump = max(jump, abs(out2[2 * f] - out2[2 * f - 2]))}
	slope := 0.5 * 2 * math.PI * 5 / N * 1.0137
	testing.expectf(
		t,
		f64(jump) < f64(slope) * 1.02,
		"no click at the seam (jump %v, slope %v)",
		jump,
		slope,
	)
}

// More voices than fit: the audible ones are mixed, the quiet ones go
// virtual, keep their place in time, and resume at the right sample.
@(test)
test_virtual_voices :: proc(t: ^testing.T) {
	m := new_mixer(1000)
	defer free(m)
	ramp := make([]f32, 100_000)
	defer delete(ramp)
	for &x, i in ramp {x = f32(i) / 100_000}
	id := add_sound(m, {samples = ramp, rate = 1000})
	loud := constant(100_000, 0.001)
	defer delete(loud)
	lid := add_sound(m, {samples = loud, rate = 1000})
	// 64 loud voices fill the real ones; the ramp is quieter, so virtual.
	for _ in 0 ..< REAL_VOICES {play(m, {sound = lid, gain = {1, 1}, pitch = 1})}
	quiet := play(m, {sound = id, gain = {0.01, 0.01}, pitch = 1})
	out := mix_frames(m, 2000)
	delete(out)
	s := stats(m)
	testing.expect_value(t, s.voices, REAL_VOICES + 1)
	testing.expect_value(t, s.real, REAL_VOICES)
	v := &m.voices[int(quiet & 0xff)]
	testing.expect(t, v.virtual && abs(v.pos - 2000) < 1e-6, "virtual, and 2000 samples on")
	// Silence the loud ones: the ramp becomes real and plays from where it is.
	for i in 0 ..< REAL_VOICES {set_voice_gain(m, Voice_Id(m.voices[i].id), {0, 0})}
	set_voice_gain(m, quiet, {1, 1})
	out = mix_frames(m, 1200)
	defer delete(out)
	s = stats(m)
	testing.expect_value(t, s.real, 1)
	late := latency(m)
	// 1200 frames from 2000: the last frame heard is sample ~3200.
	want := f32(2000 + 1200 - 1 - late) / 100_000
	got := out[2 * 1199]
	testing.expectf(
		t,
		abs(got - want) < 2e-5,
		"resumed at the right sample: got %v want %v",
		got,
		want,
	)
}

// Priority beats loudness when voices run out.
@(test)
test_priority_keeps_important :: proc(t: ^testing.T) {
	m := new_mixer(1000)
	defer free(m)
	long := constant(10_000, 0.01)
	defer delete(long)
	id := add_sound(m, {samples = long, rate = 1000})
	for _ in 0 ..< REAL_VOICES {play(m, {sound = id, gain = {1, 1}, pitch = 1})}
	vip := play(m, {sound = id, gain = {0.05, 0.05}, pitch = 1, priority = 200})
	out := mix_frames(m, 64)
	delete(out)
	testing.expect(t, !m.voices[int(vip & 0xff)].virtual, "the quiet vip is real")
	testing.expect_value(t, stats(m).real, REAL_VOICES)
}

// Fades hit their gains: a fade-in is half way half way, a stop with a fade
// ends exactly at zero and is reported.
@(test)
test_fades :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	long := constant(96000, 0.5)
	defer delete(long)
	id := add_sound(m, {samples = long, rate = 48000})
	a := play(m, {sound = id, gain = {1, 1}, pitch = 1, fade_in = 0.1})
	out := mix_frames(m, 9600)
	defer delete(out)
	late := latency(m)
	testing.expectf(
		t,
		abs(out[2 * (2400 + late)] - 0.25) < 1e-3,
		"quarter way: %v",
		out[2 * (2400 + late)],
	)
	testing.expectf(
		t,
		abs(out[2 * (4800 + late)] - 0.5) < 1e-3,
		"in at the end: %v",
		out[2 * (4800 + late)],
	)
	testing.expect(t, abs(out[2 * (6000 + late)] - 0.5) < 1e-6, "fully in")
	stop(m, a, 0.05)
	out2 := mix_frames(m, 4800)
	defer delete(out2)
	testing.expect(t, abs(out2[2 * (1200 + late)] - 0.25) < 2e-3, "half way down")
	testing.expect_value(t, out2[2 * (2400 + late + 2)], 0)
	e, ok := poll(m)
	testing.expect(t, ok && e.reason == .Stopped)
}

// Ducking: while the effects play, the music is lowered by the set amount
// within the attack, and comes back within the release.
@(test)
test_ducking :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	music := constant(480_000, 0.2)
	defer delete(music)
	fx := constant(48_000, 0.3)
	defer delete(fx)
	mid := add_sound(m, {samples = music, rate = 48000})
	fid := add_sound(m, {samples = fx, rate = 48000})
	set_duck(
		m,
		0,
		{
			active = true,
			trigger = .Effects,
			target = .Music,
			threshold = 0.05,
			amount = 0.25,
			attack = 0.02,
			release = 0.05,
		},
	)
	play(m, {sound = mid, gain = {1, 1}, pitch = 1, bus = .Music, loop = true})
	out := mix_frames(m, 4800)
	delete(out)
	play(m, {sound = fid, gain = {1, 1}, pitch = 1, bus = .World})
	out = mix_frames(m, 24000) // 0.5 s of effect
	// Music alone is 0.2; with the effect on top it is 0.2 * 0.25 + 0.3.
	late := latency(m)
	testing.expectf(
		t,
		abs(out[2 * (20000 + late)] - (0.3 + 0.05)) < 0.01,
		"ducked: %v",
		out[2 * (20000 + late)],
	)
	delete(out)
	out = mix_frames(m, 48000) // the effect is long over; the release
	defer delete(out)
	testing.expectf(t, abs(out[2 * 47000] - 0.2) < 0.005, "back: %v", out[2 * 47000])
}

// A snapshot crossfades bus gains and cutoffs, and not instantly.
@(test)
test_snapshot :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	tone := constant(480_000, 0.4)
	defer delete(tone)
	id := add_sound(m, {samples = tone, rate = 48000})
	play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .Ambience, loop = true})
	out := mix_frames(m, 4800)
	delete(out)
	snap := snapshot_neutral()
	snap.gain[.Ambience] = 0.5
	set_snapshot(m, snap, 0.1)
	out = mix_frames(m, 9600)
	defer delete(out)
	late := latency(m)
	mid := out[2 * (2400 + late)]
	testing.expectf(t, mid < 0.39 && mid > 0.21, "half way through the fade: %v", mid)
	testing.expectf(
		t,
		abs(out[2 * (8000 + late)] - 0.2) < 1e-4,
		"arrived: %v",
		out[2 * (8000 + late)],
	)
}

// A bus mute fades out in a few milliseconds, and a muted bus is silent.
@(test)
test_bus_mute_and_gain :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	tone := constant(480_000, 0.2)
	defer delete(tone)
	id := add_sound(m, {samples = tone, rate = 48000})
	play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .Music, loop = true})
	play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .UI, loop = true})
	set_bus_gain(m, .Music, 0.5)
	set_bus_mute(m, .UI, true)
	out := mix_frames(m, 4800)
	defer delete(out)
	late := latency(m)
	testing.expectf(
		t,
		abs(out[2 * (4000 + late)] - 0.1) < 1e-5,
		"music at half, ui muted: %v",
		out[2 * (4000 + late)],
	)
	set_bus_gain(m, .Master, 0.5)
	out2 := mix_frames(m, 4800)
	defer delete(out2)
	testing.expectf(t, abs(out2[2 * 4000] - 0.05) < 1e-5, "master half: %v", out2[2 * 4000])
}

// A bus low-pass dulls a high tone and leaves a low one.
@(test)
test_bus_cutoff :: proc(t: ^testing.T) {
	rate :: 48000
	tone :: proc(hz: f64) -> []f32 {
		s := make([]f32, rate)
		for &x, i in s {x = 0.5 * f32(math.sin(2 * math.PI * hz * f64(i) / rate))}
		return s
	}
	rms :: proc(out: []f32) -> f64 {
		sum: f64
		for i := len(out) / 2; i < len(out); i += 2 {sum += f64(out[i]) * f64(out[i])}
		return math.sqrt(sum / f64(len(out) / 4))
	}
	for hz, k in ([]f64{200, 8000}) {
		m := new_mixer(rate)
		defer free(m)
		s := tone(hz)
		defer delete(s)
		id := add_sound(m, {samples = s, rate = rate})
		set_bus_cutoff(m, .Music, 1000)
		play(m, {sound = id, gain = {1, 1}, pitch = 1, bus = .Music, loop = true})
		out := mix_frames(m, rate)
		defer delete(out)
		r := rms(out)
		if k == 0 {
			testing.expectf(t, abs(r - 0.5 / math.SQRT_TWO) < 0.01, "200 Hz passes: %v", r)
		} else {
			testing.expectf(t, r < 0.5 / math.SQRT_TWO / 30, "8 kHz is cut: %v", r)
		}
	}
}

// A voice low-pass does the same, and its cutoff can be swept without a step.
@(test)
test_voice_cutoff_sweep :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	saw := make([]f32, 480)
	defer delete(saw)
	for &x, i in saw {x = 0.8 * (f32(i) / 240 - 1 if i < 480 else 0)}
	id := add_sound(m, {samples = saw, rate = 48000})
	v := play(m, {sound = id, gain = {1, 1}, pitch = 1, loop = true, cutoff = 100})
	out := make([]f32, 2 * 48000)
	defer delete(out)
	for at := 0; at < 48000; at += 480 {
		set_voice_cutoff(m, v, 100 * math.pow(f32(100), f32(at) / 48000)) // 100 Hz to 10 kHz
		mix(m, out[2 * at:][:2 * 480])
	}
	// Each tooth of the saw steps at its wrap; the filter softens it, and the
	// sweep itself adds no jump bigger than the saw's own wrap.
	worst: f32
	for f in 1 ..< 48000 {worst = max(worst, abs(out[2 * f] - out[2 * f - 2]))}
	testing.expectf(t, worst <= 1.6 + 1e-3, "no step beyond the saw's own (%v)", worst)
}

// A sound with NaN in it never reaches the device; it is counted.
@(test)
test_nan_guard :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	bad := constant(4800, 0.5)
	defer delete(bad)
	bad[100] = math.nan_f32()
	bad[200] = math.inf_f32(1)
	id := add_sound(m, {samples = bad, rate = 48000})
	play(m, {sound = id, gain = {1, 1}, pitch = 1})
	out := mix_frames(m, 4800)
	defer delete(out)
	for x in out {testing.expect(t, x == x && abs(x) <= 1)}
	testing.expect(t, stats(m).nan_guarded >= 2, "counted")
}

// The silent engine is digital zero, with and without voices that ended.
@(test)
test_silence_is_zero :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	out := mix_frames(m, 4800)
	defer delete(out)
	for x in out {if x != 0 {testing.fail_now(t, "not exactly zero")}}
	short := constant(100, 0.5)
	defer delete(short)
	id := add_sound(m, {samples = short, rate = 48000})
	play(m, {sound = id, gain = {1, 1}, pitch = 1})
	out2 := mix_frames(m, 48000)
	defer delete(out2)
	for x in out2[2 * 2000:] {if x != 0 {testing.fail_now(t, "not zero after the sound")}}
}

// The same commands give the same samples, twice (no clock, no randomness).
@(test)
test_mix_is_deterministic :: proc(t: ^testing.T) {
	run :: proc() -> []f32 {
		m := new_mixer(48000)
		defer free(m)
		s := make([]f32, 3000)
		defer delete(s)
		for &x, i in s {x = 0.7 * f32(math.sin(f64(i) * 0.05)) * f32(math.sin(f64(i) * 0.0007))}
		id := add_sound(m, {samples = s, rate = 44100})
		for k in 0 ..< 20 {
			play(
				m,
				{
					sound = id,
					gain = {0.5, 0.3},
					pitch = 0.8 + 0.05 * f32(k),
					bus = Bus(k % 3),
					cutoff = f32(500 + 300 * k),
				},
			)
		}
		return mix_frames(m, 20000)
	}
	a := run()
	b := run()
	defer delete(a)
	defer delete(b)
	for i in 0 ..< len(a) {if a[i] != b[i] {testing.fail_now(t, "differs")}}
}

@(test)
test_spatial_gain :: proc(t: ^testing.T) {
	right := [3]f32{1, 0, 0}
	ahead := spatial_gain({0, 0, -5}, right, 1, 16)
	testing.expect(t, abs(ahead[0] - ahead[1]) < 1e-5, "ahead: centred")
	on_right := spatial_gain({5, 0, 0}, right, 1, 16)
	testing.expect(
		t,
		on_right[1] > 2 * on_right[0] && on_right[0] > 0,
		"right: louder right, not silent left",
	)
	testing.expect(
		t,
		abs(
			on_right[0] * on_right[0] +
			on_right[1] * on_right[1] -
			ahead[0] * ahead[0] -
			ahead[1] * ahead[1],
		) <
		1e-4,
		"same distance, same power",
	)
	far := spatial_gain({0, 0, -12}, right, 1, 16)
	testing.expect(t, far[0] < ahead[0], "further is quieter")
	testing.expect_value(t, spatial_gain({0, 0, -20}, right, 1, 16), [2]f32{})
	here := spatial_gain({0, 0, 0}, right, 0.5, 16)
	testing.expect(t, abs(here[0] - 0.5) < 1e-5 && abs(here[1] - 0.5) < 1e-5)
	_ = math.PI
}
