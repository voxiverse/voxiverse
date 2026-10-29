package smoke

import "core:math"
import "core:testing"
import "core:time"

import "../client/audio"

// What needs a device or a decoder thread, and the OS's clock: the null
// device's pacing, and a threaded stream against the inline one. The mixer's
// own tests (client/audio) run without either.

@(rodata)
TONE := #load("../client/audio/testdata/tone.ogg") // 3 s, 44.1 kHz, 440 Hz left and 660 Hz right

// The null device mixes at real rate: it never runs ahead of the wall clock
// (a second of frames takes at least a second), it reaches a second of
// frames however late a loaded machine schedules it, the callback's timing is
// measured, and nothing is lost. Only the pacing is asserted, never a rate
// over a fixed sleep: that depends on the scheduler, not on the device.
@(test)
test_null_device_runs_in_real_time :: proc(t: ^testing.T) {
	m := new(audio.Mixer)
	audio.mixer_init(m, 48000)
	samples := make([]f32, 4800)
	for i in 0 ..< len(samples) {
		samples[i] = 0.3 * f32(math.sin(2 * math.PI * 300 * f64(i) / 48000))
	}
	id := audio.add_sound(m, {samples = samples, rate = 48000})
	defer {
		delete(samples)
		free(m)
	}
	d: audio.Device
	start := time.tick_now()
	testing.expect(t, audio.device_open_null(&d, m))
	v := audio.play(m, {sound = id, gain = {1, 1}, loop = true})
	testing.expect(t, v != 0)
	s := audio.stats(m)
	for s.frames < 48000 && time.duration_seconds(time.tick_since(start)) < 30 {
		time.sleep(5 * time.Millisecond)
		s = audio.stats(m)
	}
	elapsed := time.duration_seconds(time.tick_since(start))
	audio.device_close(&d)
	testing.expect_value(t, d.open, false)
	seconds := f64(s.frames) / 48000
	testing.expectf(t, seconds >= 1.0, "mixed only %.2f s of audio in %.2f s", seconds, elapsed)
	// Never ahead of the clock: the mixed audio, less the block in flight,
	// is no more than the time that has passed.
	testing.expectf(
		t,
		seconds - f64(audio.NULL_BLOCK) / 48000 <= elapsed,
		"mixed %.3f s in %.3f s: ahead of real time",
		seconds,
		elapsed,
	)
	testing.expect(t, s.callbacks >= 100, "callbacks")
	testing.expect(t, s.cb_max_ns > 0, "timed")
	testing.expect_value(t, s.nan_guarded, 0)
	testing.expect_value(t, s.underruns, 0)
	testing.expect_value(t, audio.stats(m).voices, 1)
}

@(private = "file")
play_stream :: proc(inline: bool) -> (out: []f32, underruns: u32) {
	m := new(audio.Mixer)
	defer free(m)
	audio.mixer_init(m, 44100)
	id, ok := audio.add_stream(m, TONE, inline = inline)
	defer audio.streams_close(m)
	if !ok {return}
	if !inline {time.sleep(100 * time.Millisecond)} 	// (the decoder's head start)
	audio.play(m, {sound = id, gain = {1, 1}, pitch = 1})
	frames := 3 * 44100 + 4410
	out = make([]f32, 2 * frames)
	// The decoder thread works in real time at best: the mixing is paced (a
	// block of 10 ms every 5 ms), as a device would ask for it.
	for at := 0; at < frames; at += 441 {
		audio.mix(m, out[2 * at:][:2 * min(441, frames - at)])
		if !inline {time.sleep(5 * time.Millisecond)}
	}
	return out, audio.stream_underruns(m, id)
}

// A stream decoded by its thread plays what the inline one does.
@(test)
test_a_threaded_stream_equals_an_inline_one :: proc(t: ^testing.T) {
	want, _ := play_stream(true)
	got, underruns := play_stream(false)
	defer delete(want)
	defer delete(got)
	worst: f32
	for i in 0 ..< len(want) {worst = max(worst, abs(want[i] - got[i]))}
	testing.expectf(t, worst < 1e-5, "the threaded stream differs by %v", worst)
	testing.expect_value(t, underruns, 0)
}
