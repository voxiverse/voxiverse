package audio

import "core:math"
import "core:testing"

// Tests for M32e's inspector engine: freeze, solo, mute, the monitor.

@(private = "file")
Rig :: struct {
	m:    ^Mixer,
	tone: Sound_Id,
	bell: Sound_Id,
}

@(private = "file")
rig_new :: proc() -> (r: Rig) {
	r.m = new(Mixer)
	mixer_init(r.m, 48000)
	tone := make([]f32, 4800)
	bell := make([]f32, 24000)
	for i in 0 ..< len(tone) {tone[i] = 0.3 * f32(math.sin(2 * math.PI * 300 * f64(i) / 48000))}
	for i in 0 ..< len(bell) {
		bell[i] =
			0.5 * f32(math.sin(2 * math.PI * 1100 * f64(i) / 48000) * math.exp(-f64(i) / 9000))
	}
	r.tone = add_sound(r.m, {samples = tone, rate = 48000})
	r.bell = add_sound(r.m, {samples = bell, rate = 48000})
	capture_start_ring(r.m, 1 << 12)
	return
}

@(private = "file")
rig_free :: proc(r: Rig) {
	capture_destroy(capture_stop(r.m))
	delete(r.m.sounds[r.tone].samples)
	delete(r.m.sounds[r.bell].samples)
	free(r.m)
}

// run: the game's side: a tone on Ambience, a bell on Effects, then a second second.
@(private = "file")
rig_run :: proc(r: Rig) {
	out := make([]f32, 2 * 480)
	defer delete(out)
	for call in 0 ..< 100 {
		if call == 0 {
			play(r.m, {sound = r.tone, gain = {0.5, 0.5}, loop = true, bus = .Ambience})
		}
		if call == 20 {
			play(r.m, {sound = r.bell, gain = {0.8, 0.8}, bus = .Effects, priority = 4})
		}
		mix(r.m, out)
	}
}

@(private = "file")
level :: proc(x: []f32) -> f64 {
	sum: f64
	for v in x {sum += f64(v) * f64(v)}
	return math.sqrt(sum / f64(max(len(x), 1)))
}

@(test)
test_inspect_freeze_lists_voices_and_replays :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	rig_run(r)
	fz := inspect_freeze(r.m)
	testing.expect(t, fz != nil)
	if fz == nil {return}
	defer inspect_destroy(fz)
	testing.expect_value(t, len(fz.voices), 2)
	testing.expect_value(t, len(fz.loop), 2 * 24000)
	testing.expect(t, level(fz.loop) > 0.01, "the loop has the mix in it")
	buses: bit_set[Bus]
	for v in fz.voices {buses += {v.bus}}
	testing.expect(t, buses == {.Ambience, .Effects})
	// the ring goes on recording after a freeze
	testing.expect(t, sync_load_capture(r.m))
}

@(private = "file")
sync_load_capture :: proc(m: ^Mixer) -> bool {
	return m.capture != nil
}

@(test)
test_inspect_solo_and_mute :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	rig_run(r)
	fz := inspect_freeze(r.m)
	if fz == nil {
		testing.expect(t, false, "no freeze")
		return
	}
	defer inspect_destroy(fz)
	all := level(fz.loop)
	// Solo the bell's bus: the tone goes, the bell stays.
	testing.expect(t, inspect_pick(fz, {mode = .Solo, bus = .Effects}))
	solo := level(fz.loop)
	testing.expect(t, solo > 0 && solo < all, "solo of Effects is quieter than all")
	for v in fz.voices {testing.expect_value(t, v.heard, v.bus == .Effects)}
	testing.expect_value(t, fz.an.peak[.Ambience], 0)
	testing.expect(t, fz.an.peak[.Effects] > 0)
	// Muting the Effects bus leaves the tone.
	testing.expect(t, inspect_pick(fz, {mode = .Mute, bus = .Effects}))
	for v in fz.voices {testing.expect_value(t, v.heard, v.bus != .Effects)}
	// Solo of one voice by id.
	id := fz.voices[0].id
	testing.expect(t, inspect_pick(fz, {mode = .Solo, voice = true, id = id}))
	for v in fz.voices {testing.expect_value(t, v.heard, v.id == id)}
	// Off: back to the whole.
	testing.expect(t, inspect_pick(fz, {}))
	testing.expect_value(t, level(fz.loop), all)
}

@(test)
test_monitor_replaces_the_output :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	rig_run(r)
	mon := Monitor {
		samples = make([]f32, 2 * 100),
	}
	defer delete(mon.samples)
	for i in 0 ..< 100 {mon.samples[2 * i], mon.samples[2 * i + 1] = f32(i), -f32(i)}
	monitor_set(r.m, &mon)
	out := make([]f32, 2 * 250)
	defer delete(out)
	mix(r.m, out)
	testing.expect_value(t, out[2 * 7], 7)
	testing.expect_value(t, out[2 * 7 + 1], -7)
	testing.expect_value(t, out[2 * 150], 50) // looped
	monitor_set(r.m, nil)
	mix(r.m, out)
	testing.expect(t, out[2 * 7] != 7)
}

@(test)
test_freeze_without_a_ring_is_nil :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	testing.expect(t, inspect_freeze(m) == nil)
}
