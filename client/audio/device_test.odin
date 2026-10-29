package audio

import "core:math"
import "core:os"
import "core:slice"
import "core:testing"

// The file device, which needs no sound card. (The null device, paced by the
// clock, is tested in smoke/.)

@(private = "file")
tone_mixer :: proc() -> (m: ^Mixer, id: Sound_Id, samples: []f32) {
	m = new(Mixer)
	mixer_init(m, 48000)
	samples = make([]f32, 4800)
	for i in 0 ..< len(samples) {
		samples[i] = 0.3 * f32(math.sin(2 * math.PI * 300 * f64(i) / 48000))
	}
	id = add_sound(m, {samples = samples, rate = 48000})
	return
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
	testing.expect(t, device_render(&d, 48000 * 4 + 17))
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
