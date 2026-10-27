package audio

import "core:math"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

// Tests for the two devices that need no sound card.

@(private = "file")
tone_mixer :: proc() -> (m: ^Mixer, id: Sound_Id, samples: []f32) {
	m = new(Mixer)
	mixer_init(m, 48000)
	samples = make([]f32, 4800)
	for i in 0 ..< len(samples) {
		samples[i] = 0.3 * f32(math.sin(2 * math.PI * 300 * f64(i) / 48000))
	}
	id = add_sound(m, {samples, 48000})
	return
}

// The null device mixes at real rate: a second of wall clock is about a
// second of frames, the callback's timing is measured, and nothing is lost.
@(test)
test_null_device_runs_in_real_time :: proc(t: ^testing.T) {
	m, id, samples := tone_mixer()
	defer {
		delete(samples)
		free(m)
	}
	d: Device
	testing.expect(t, device_open_null(&d, m))
	v := play(m, {sound = id, gain = {1, 1}, loop = true})
	testing.expect(t, v != 0)
	time.sleep(1200 * time.Millisecond)
	s := stats(m)
	device_close(&d)
	testing.expect_value(t, d.open, false)
	seconds := f64(s.frames) / 48000
	testing.expectf(t, seconds > 1.0 && seconds < 1.4, "mixed %.2f s in 1.2 s", seconds)
	testing.expect(t, s.callbacks > 100, "callbacks")
	testing.expect(t, s.cb_max_ns > 0, "timed")
	testing.expect_value(t, s.nan_guarded, 0)
	testing.expect_value(t, s.underruns, 0)
	testing.expect_value(t, stats(m).voices, 1)
}

// The file device mixes what it is told to, as fast as it can, and writes
// the WAV at close: the same samples as mixing by hand.
@(test)
test_file_device_writes_the_mix :: proc(t: ^testing.T) {
	m, id, samples := tone_mixer()
	by_hand, hs, hsamples := tone_mixer()
	defer {
		delete(samples)
		delete(hsamples)
		free(m)
		free(by_hand)
	}
	path := "build/test_file_device.wav"
	os.make_directory("build")
	d: Device
	testing.expect(t, device_open_file(&d, m, path))
	play(m, {sound = id, gain = {0.7, 0.3}, loop = true})
	play(by_hand, {sound = hs, gain = {0.7, 0.3}, loop = true})
	start := time.tick_now()
	testing.expect(t, device_render(&d, 48000 * 4 + 17))
	testing.expect(t, time.duration_seconds(time.tick_since(start)) < 3, "faster than real time")
	want := make([]f32, 2 * (48000 * 4 + 17))
	defer delete(want)
	for done := 0; done < 48000 * 4 + 17; {
		n := min(NULL_BLOCK, 48000 * 4 + 17 - done)
		mix(by_hand, want[2 * done:][:2 * n])
		done += n
	}
	device_close(&d)
	defer os.remove(path)
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil && len(data) == 44 + 4 * len(want))
	testing.expect(t, slice.equal(data[44:], slice.to_bytes(want)), "the file is the mix")
	testing.expect(t, string(data[:4]) == "RIFF" && string(data[8:12]) == "WAVE")
}
