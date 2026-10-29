package audio

import "core:math"
import "core:testing"
import ma "vendor:miniaudio"

// Tests for M32c's streams: what comes out of a stream voice is the file's
// decode, loops have no seam, a starved decoder is counted and never skipped
// over, and a stream is one voice among the rest.

@(rodata)
TONE := #load("testdata/tone.ogg") // 3 s, 44.1 kHz, 440 Hz left and 660 Hz right

@(private = "file")
new_mixer :: proc(rate: u32) -> ^Mixer {
	m := new(Mixer)
	mixer_init(m, rate)
	return m
}

@(private = "file")
mix_frames :: proc(m: ^Mixer, frames: int, block := 480) -> []f32 {
	out := make([]f32, 2 * frames)
	for at := 0; at < frames; at += block {
		mix(m, out[2 * at:][:2 * min(block, frames - at)])
	}
	return out
}

// reference: the file decoded in one go by a decoder of its own (two channels).
@(private = "file")
reference :: proc() -> (left, right: []f32) {
	cfg := ma.decoder_config_init(.f32, 2, 0)
	d: ma.decoder
	assert(ma.decoder_init_memory(raw_data(TONE), uint(len(TONE)), &cfg, &d) == .SUCCESS)
	defer ma.decoder_uninit(&d)
	n: u64
	ma.decoder_get_length_in_pcm_frames(&d, &n)
	both := make([]f32, 2 * n)
	defer delete(both)
	got: u64
	ma.decoder_read_pcm_frames(&d, raw_data(both), n, &got)
	left, right = make([]f32, got), make([]f32, got)
	for i in 0 ..< int(got) {
		left[i], right[i] = both[2 * i], both[2 * i + 1]
	}
	return
}

@(private = "file")
max_diff :: proc(a, b: []f32) -> f32 {
	d: f32
	for i in 0 ..< min(len(a), len(b)) {d = max(d, abs(a[i] - b[i]))}
	return d
}

// A stream voice plays what the decoder gives, sample for sample, and ends
// where the file does. (The same through a decoder thread is in smoke/.)
@(test)
test_stream_equals_decode :: proc(t: ^testing.T) {
	ref, ref_r := reference()
	defer delete(ref)
	defer delete(ref_r)
	m := new_mixer(44100)
	defer free(m)
	id, ok := add_stream(m, TONE, inline = true)
	defer streams_close(m)
	testing.expect(t, ok)
	v := play(m, {sound = id, gain = {1, 1}, pitch = 1})
	late := latency(m)
	total := len(ref) + 4410 + late
	out := mix_frames(m, total)
	defer delete(out)
	// (the last sample is not played, as with any sound)
	left := make([]f32, len(ref) - 1)
	defer delete(left)
	right := make([]f32, len(left))
	defer delete(right)
	for i in 0 ..< len(left) {
		left[i] = out[2 * (i + late)]
		right[i] = out[2 * (i + late) + 1]
	}
	testing.expectf(
		t,
		max_diff(left, ref) < 1e-5 && max_diff(right, ref_r) < 1e-5,
		"differs by %v, %v",
		max_diff(left, ref),
		max_diff(right, ref_r),
	)
	testing.expect_value(t, stream_underruns(m, id), 0)
	e, got := poll(m)
	testing.expect(t, got && e.voice == v && e.reason == .Ended, "ends with the file")
	testing.expect_value(t, out[2 * (len(ref) + late + 100)], 0)
}

@(private = "file")
sync_written :: proc(m: ^Mixer, id: Sound_Id) -> u64 {
	return m.streams[id].written
}

// A loop with a crossfade has no seam: nothing in several loops jumps more
// than the signal does anywhere, and no underrun.
@(test)
test_stream_loop_seamless :: proc(t: ^testing.T) {
	m := new_mixer(44100)
	defer free(m)
	id, ok := add_stream(m, TONE, loop = true, crossfade = 0.05, inline = true)
	defer streams_close(m)
	testing.expect(t, ok)
	v := play(m, {sound = id, gain = {1, 1}, pitch = 1})
	out := mix_frames(m, 44100 * 9)
	defer delete(out)
	late := latency(m)
	plain, worst: f32
	for i in late + 1 ..< 44100 {plain = max(plain, abs(out[2 * i] - out[2 * (i - 1)]))}
	for i in late + 1 ..< len(out) / 2 {worst = max(worst, abs(out[2 * i] - out[2 * (i - 1)]))}
	testing.expectf(t, plain > 0.001, "the signal moves (%v)", plain)
	testing.expectf(t, worst <= plain * 3, "a seam: step %v against %v", worst, plain)
	testing.expect(t, alive(m, v), "still playing after three loops")
	testing.expect_value(t, stream_underruns(m, id), 0)
	// The loop is the file less the crossfade: the sound repeats at that period.
	period := 3 * 44100 - int(0.05 * 44100)
	// (after the first pass every pass is the same samples)
	a, b := late + period + 4410, late + 2 * period + 4410
	testing.expectf(
		t,
		max_diff(out[2 * a:][:2 * 20000], out[2 * b:][:2 * 20000]) < 1e-5,
		"passes differ by %v",
		max_diff(out[2 * a:][:2 * 20000], out[2 * b:][:2 * 20000]),
	)
}

// A stream goes through the same sinc as every sound: at another pitch it
// lasts the right time, and a stop with a fade ends it as stopped.
@(test)
test_stream_is_a_voice :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	id, ok := add_stream(m, TONE, inline = true)
	defer streams_close(m)
	testing.expect(t, ok)
	v := play(m, {sound = id, gain = {1, 1}, pitch = 1.5})
	out := mix_frames(m, 48000 * 3)
	defer delete(out)
	e, got := poll(m)
	testing.expect(t, got && e.voice == v && e.reason == .Ended)
	// 3 s of 44.1 kHz at 1.5x on a 48 kHz mixer: 3 * 44100 / 48000 / 1.5 s.
	last := 0
	late := latency(m)
	for i in 0 ..< len(out) / 2 {if abs(out[2 * i]) > 1e-4 {last = i - late}}
	want := int(3 * 44100.0 / (44100.0 / 48000 * 1.5))
	testing.expectf(t, abs(last - want) < 400, "ended at %v, expected %v", last, want)
	// Stopped with a fade.
	w := play(m, {sound = id, gain = {1, 1}, cutoff = 2000})
	delete(mix_frames(m, 4800))
	stop(m, w, 0.05)
	tail := mix_frames(m, 9600)
	delete(tail)
	e, got = poll(m)
	testing.expect(t, got && e.voice == w && e.reason == .Stopped)
	// The stream starts over for the next voice and plays the same again.
	x := play(m, {sound = id, gain = {1, 1}, pitch = 1.5})
	again := mix_frames(m, 48000 * 3)
	defer delete(again)
	diff := max_diff(out, again)
	testing.expectf(t, diff < 1e-5, "a second play differs by %v", diff)
	_ = x
}

// A stream has one voice at a time: a second play while one is playing is
// dropped and counted.
@(test)
test_stream_one_voice :: proc(t: ^testing.T) {
	m := new_mixer(44100)
	defer free(m)
	id, ok := add_stream(m, TONE, inline = true)
	defer streams_close(m)
	testing.expect(t, ok)
	a := play(m, {sound = id, gain = {1, 1}})
	b := play(m, {sound = id, gain = {1, 1}})
	out := mix_frames(m, 4410)
	defer delete(out)
	testing.expect_value(t, m.dropped, 1)
	e, got := poll(m)
	testing.expect(t, got && e.voice == b, "the second is told it ended")
	testing.expect(t, alive(m, a))
}

@(test)
test_stream_rejects_garbage :: proc(t: ^testing.T) {
	m := new_mixer(44100)
	defer free(m)
	junk := []byte{'O', 'g', 'g', 'S', 0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	_, ok := add_stream(m, junk)
	testing.expect(t, !ok)
	_, ok = add_stream(m, TONE[:200])
	testing.expect(t, !ok, "a truncated file")
	testing.expect_value(t, m.count, 0)
}

// The decoder starved 200 ms (paused: an inline one is not run) while the
// voice plays: the ring holds enough, nothing is missed. Starved past the ring, the underrun is
// counted, the voice holds its place and goes on from it.
@(test)
test_stream_starved_decoder :: proc(t: ^testing.T) {
	ref, ref_r := reference()
	defer delete(ref)
	defer delete(ref_r)
	m := new_mixer(44100)
	defer free(m)
	id, ok := add_stream(m, TONE, inline = true)
	defer streams_close(m)
	testing.expect(t, ok)
	for stream_pump(m.streams[id]) {} 	// the ring is full when the decoder stops
	testing.expect(t, sync_written(m, id) >= STREAM_RING - 4096)
	stream_pause(m, id, true)
	v := play(m, {sound = id, gain = {1, 1}})
	late := latency(m)
	part := mix_frames(m, 44100 / 5) // 200 ms, the decoder asleep
	defer delete(part)
	testing.expect_value(t, stream_underruns(m, id), 0)
	left := make([]f32, len(part) / 2 - late)
	defer delete(left)
	for i in 0 ..< len(left) {left[i] = part[2 * (i + late)]}
	testing.expect(t, max_diff(left, ref) < 1e-5, "what played is the file")
	// Starved past what the ring holds: the voice runs dry.
	dry := mix_frames(m, 44100 * 2)
	defer delete(dry)
	testing.expect(t, stream_underruns(m, id) > 0, "the underrun is counted")
	testing.expect(t, alive(m, v), "the voice waits, it does not end")
	// The decoder wakes: the voice goes on and plays all of the file, once.
	stream_pause(m, id, false)
	energy: f64
	for e in part {energy += f64(e) * f64(e)}
	for e in dry {energy += f64(e) * f64(e)}
	for step := 0; step < 2000 && alive(m, v); step += 1 {
		more := mix_frames(m, 441)
		for e in more {energy += f64(e) * f64(e)}
		delete(more)
		drain(m)
	}
	testing.expect(t, !alive(m, v), "it finished")
	// The mixed part, the dry part and the rest: the file's energy, once.
	want: f64
	for x in ref {want += f64(x) * f64(x)}
	for x in ref_r {want += f64(x) * f64(x)}
	testing.expectf(t, abs(energy / want - 1) < 0.01, "energy %v of %v", energy, want)
}

@(test)
test_denormals_flushed :: proc(t: ^testing.T) {
	flush_denormals()
	when ODIN_ARCH == .amd64 {
		testing.expect(t, denormals_flushed())
		tiny := f32(1e-30)
		x := tiny * tiny // would be a denormal-or-zero either way; with FTZ it is zero
		testing.expect_value(t, x, 0)
	}
	_ = math.PI
}

// goertzel: the amplitude of `freq` in x[from:to] (a Hann window).
@(private = "file")
goertzel :: proc(x: []f32, stride, offset, from, to: int, freq, rate: f64) -> f64 {
	re, im, wsum: f64
	n := to - from
	for i in 0 ..< n {
		w := 0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / f64(n))
		a := 2 * math.PI * freq * f64(i) / rate
		v := f64(x[(from + i) * stride + offset]) * w
		re += v * math.cos(a)
		im += v * math.sin(a)
		wsum += w
	}
	return 2 * math.sqrt(re * re + im * im) / wsum
}

// A two-channel stream keeps its channels: 440 Hz stays on the left and
// 660 Hz on the right, each other's tone at least 60 dB down.
@(test)
test_stream_stereo_channels :: proc(t: ^testing.T) {
	{
		m := new_mixer(48000)
		defer free(m)
		id, ok := add_stream(m, TONE, inline = true)
		defer streams_close(m)
		testing.expect(t, ok)
		testing.expect_value(t, m.streams[id].channels, 2)
		play(m, {sound = id, gain = {1, 1}, pitch = 1})
		frames := 48000
		out := make([]f32, 2 * frames)
		defer delete(out)
		for at := 0; at < frames; at += 480 {
			mix(m, out[2 * at:][:2 * 480])
		}
		from, to := 24000, 48000 - 2400 // past the limiter's delay
		l440 := goertzel(out, 2, 0, from, to, 440, 48000)
		l660 := goertzel(out, 2, 0, from, to, 660, 48000)
		r440 := goertzel(out, 2, 1, from, to, 440, 48000)
		r660 := goertzel(out, 2, 1, from, to, 660, 48000)
		testing.expectf(t, l440 > 0.01 && r660 > 0.01, "tones %v %v", l440, r660)
		testing.expectf(t, 20 * math.log10(l440 / l660) > 60, "left: %v vs %v", l440, l660)
		testing.expectf(t, 20 * math.log10(r660 / r440) > 60, "right: %v vs %v", r660, r440)
		testing.expect_value(t, stream_underruns(m, id), 0)
	}
}

// A stereo memory sound looped is seamless, and a stereo voice is not panned
// by anything but its own gain: each channel keeps its own samples.
@(test)
test_stereo_sound_loop :: proc(t: ^testing.T) {
	m := new_mixer(48000)
	defer free(m)
	n := 4800 // 10 whole cycles of 100 Hz and 200 Hz
	l, r := make([]f32, n), make([]f32, n)
	defer delete(l)
	defer delete(r)
	for i in 0 ..< n {
		l[i] = 0.5 * f32(math.sin(2 * math.PI * 100 * f64(i) / 48000))
		r[i] = 0.5 * f32(math.sin(2 * math.PI * 200 * f64(i) / 48000))
	}
	id := add_sound(m, {samples = l, rate = 48000, right = r})
	play(m, {sound = id, gain = {1, 1}, pitch = 1, loop = true})
	frames := 48000
	out := mix_frames(m, frames)
	defer delete(out)
	from, to := 9600, 48000 - 2400
	// Whole windows of the loop: the tone's amplitude through several wraps.
	testing.expect(t, goertzel(out, 2, 0, from, to, 100, 48000) > 0.4)
	testing.expect(t, goertzel(out, 2, 1, from, to, 200, 48000) > 0.4)
	testing.expect(t, goertzel(out, 2, 0, from, to, 200, 48000) < 0.005)
	testing.expect(t, goertzel(out, 2, 1, from, to, 100, 48000) < 0.005)
	// No seam: no sample-to-sample step far past the tones' own (the loop wraps 10 times).
	worst: f32
	for i in from ..< to - 1 {
		worst = max(
			worst,
			abs(out[2 * (i + 1)] - out[2 * i]),
			abs(out[2 * (i + 1) + 1] - out[2 * i + 1]),
		)
	}
	testing.expectf(t, worst < 0.03, "step %v", worst)
}
