package audio

import "core:hash"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:testing"

// Tests for M32c's capture and the frames commands carry.

@(private = "file")
Scene :: struct {
	m:      ^Mixer,
	tone:   Sound_Id,
	bell:   Sound_Id,
	stream: Sound_Id,
}

// scene_new: a mixer with the scene's sounds (a looping tone, a decaying bell,
// an inline looping stream).
@(private = "file")
scene_new :: proc(rate: u32) -> (s: Scene) {
	s.m = new(Mixer)
	mixer_init(s.m, rate)
	tone := make([]f32, 4800)
	bell := make([]f32, 24000)
	for i in 0 ..< len(tone) {tone[i] = 0.3 * f32(math.sin(2 * math.PI * 300 * f64(i) / 48000))}
	for i in 0 ..< len(bell) {
		bell[i] =
			0.5 * f32(math.sin(2 * math.PI * 1100 * f64(i) / 48000) * math.exp(-f64(i) / 5000))
	}
	s.tone = add_sound(s.m, {tone, 48000})
	s.bell = add_sound(s.m, {bell, 48000})
	ok: bool
	s.stream, ok = add_stream(s.m, TONE, loop = true, crossfade = 0.1, inline = true)
	assert(ok)
	return
}

@(private = "file")
scene_free :: proc(s: Scene) {
	delete(s.m.sounds[s.tone].samples)
	delete(s.m.sounds[s.bell].samples)
	streams_close(s.m)
	free(s.m)
}

// scene_run: the game's side, a few seconds of it, in calls of uneven sizes.
@(private = "file")
scene_run :: proc(s: Scene, frames: int) -> []f32 {
	m := s.m
	out := make([]f32, 2 * frames)
	sizes := [?]int{100, 480, 777, 512, 1023, 64, 960, 333}
	at, call := 0, 0
	var_voice: Voice_Id
	for at < frames {
		n := min(sizes[call % len(sizes)], frames - at)
		switch call {
		case 0:
			set_reverb(m, 1.2, 0.5, 0.3, 0.2)
			set_bus_reverb(m, .Effects, 0.4)
			set_duck(
				m,
				0,
				{
					active = true,
					trigger = .Effects,
					target = .Music,
					threshold = 0.05,
					amount = 0.3,
					attack = 0.01,
					release = 0.2,
				},
			)
			play(m, {sound = s.stream, gain = {0.8, 0.8}, bus = .Music})
			var_voice = play(
				m,
				{sound = s.tone, gain = {0.5, 0.2}, loop = true, bus = .Ambience, cutoff = 1500},
			)
		case 3:
			play(m, {sound = s.bell, gain = {0.7, 0.7}, pitch = 1.3, bus = .World, priority = 5})
			play(
				m,
				{
					sound = s.bell,
					gain = {0.4, 0.6},
					pitch = 0.77,
					bus = .Player,
					start_frame = clock(m) + 5000,
				},
			)
		case 5:
			set_voice_gain(m, var_voice, {0.1, 0.6})
			set_voice_pitch(m, var_voice, 1.2)
			set_bus_gain(m, .Music, 0.5, at = clock(m) + 3000)
			set_snapshot(m, snapshot_neutral(), 0.1, at = clock(m) + 2500)
		case 8:
			set_listener(m, {crossfeed = 0.3, night = true})
			fade_voice(m, var_voice, 0.2, 0.3)
		case 12:
			play(m, {sound = s.bell, gain = {1, 1}, pitch = 2.1, bus = .UI})
			stop(m, var_voice, 0.2, at = clock(m) + 7000)
		case 16:
			set_listener(m, {mono = true, ceiling_db = -6})
		}
		mix(m, out[2 * at:][:2 * n])
		at += n
		call += 1
		drain(m)
	}
	return out
}

@(private = "file")
checksum :: proc(x: []f32) -> u64 {
	return hash.fnv64a(slice.to_bytes(x))
}

// What was recorded replays to the same samples, bit for bit, however the
// calls were cut; a saved and reloaded file does too.
@(test)
test_capture_replays_bit_identical :: proc(t: ^testing.T) {
	live := scene_new(48000)
	defer scene_free(live)
	testing.expect(t, capture_start(live.m, 4096))
	testing.expect(t, !capture_start(live.m, 10), "one recorder at a time")
	frames := 48000 * 2
	want := scene_run(live, frames)
	defer delete(want)
	cap := capture_stop(live.m)
	defer capture_destroy(cap)
	kept, lost := capture_records(cap)
	testing.expectf(t, kept > 40 && lost == 0, "kept %v, lost %v", kept, lost)

	data := capture_encode(live.m, cap)
	defer delete(data)
	file, ok := capture_parse(data)
	testing.expect(t, ok)
	defer capture_file_destroy(&file)
	testing.expect_value(t, capture_frames(&file), frames)

	replayed := scene_new(48000)
	defer scene_free(replayed)
	got := make([]f32, 2 * frames)
	defer delete(got)
	testing.expect(t, capture_replay(replayed.m, &file, got))
	// The same samples at every optimization level (checked: none to aggressive).
	// Held as a number only where the maths library is the one it was taken with.
	log.infof("capture scene checksum %x", checksum(got))
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		testing.expect_value(t, checksum(got), 0xee19b6e7f8cded19)
	}
	testing.expectf(
		t,
		checksum(got) == checksum(want),
		"replay differs (%x, %x)",
		checksum(got),
		checksum(want),
	)
	testing.expect(t, slice.equal(got, want), "replay is not bit-identical")

	// Through a file.
	path := "build/test_capture.vxac"
	os.make_directory("build")
	testing.expect(t, capture_save(live.m, cap, path))
	bytes, err := os.read_entire_file(path, context.allocator)
	defer delete(bytes)
	testing.expect(t, err == nil && slice.equal(bytes, data))
	os.remove(path)
}

// A mixer that is not the one captured is refused, as are damaged files:
// nothing in them is trusted until it has been checked.
@(test)
test_capture_refuses_what_does_not_match :: proc(t: ^testing.T) {
	live := scene_new(48000)
	defer scene_free(live)
	capture_start(live.m, 4096)
	out := scene_run(live, 24000)
	defer delete(out)
	cap := capture_stop(live.m)
	defer capture_destroy(cap)
	data := capture_encode(live.m, cap)
	defer delete(data)
	file, ok := capture_parse(data)
	testing.expect(t, ok)
	defer capture_file_destroy(&file)
	buf := make([]f32, 2 * capture_frames(&file))
	defer delete(buf)

	other := scene_new(44100)
	defer scene_free(other)
	testing.expect(t, !capture_replay(other.m, &file, buf), "another rate")
	again := scene_new(48000)
	defer scene_free(again)
	again.m.sounds[again.tone].samples[7] += 0.01
	testing.expect(t, !capture_replay(again.m, &file, buf), "another sound")
	fresh := scene_new(48000)
	defer scene_free(fresh)
	testing.expect(t, !capture_replay(fresh.m, &file, buf[:100]), "a buffer too small")
	delete(fresh.m.sounds[fresh.tone].samples)
	fresh.m.sounds[fresh.tone].samples = make([]f32, 4800)
	// Damage: a truncated file, a bad magic, a bus out of range, a record count too large.
	_, ok = capture_parse(data[:len(data) - 3])
	testing.expect(t, !ok, "truncated")
	_, ok = capture_parse(data[:10])
	testing.expect(t, !ok, "short")
	bad := slice.clone(data)
	defer delete(bad)
	bad[0] = 'X'
	_, ok = capture_parse(bad)
	testing.expect(t, !ok, "magic")
	copy(bad, data)
	h := (^Capture_Header)(raw_data(bad))
	h.record_count = 1 << 30
	_, ok = capture_parse(bad)
	testing.expect(t, !ok, "huge count")
	h.record_count = file.header.record_count
	// A play on a bus that does not exist.
	c := Play_Cmd {
		id = 1,
		play = {sound = 0, bus = Bus(200)},
	}
	kind, raw := command_raw(c)
	_, ok = command_from(kind, raw, 3)
	testing.expect(t, !ok, "a bus out of range")
	c.play.bus = .World
	c.play.sound = 9
	kind, raw = command_raw(c)
	_, ok = command_from(kind, raw, 3)
	testing.expect(t, !ok, "a sound that is not there")
	_, ok = command_from(5, raw[:3], 3)
	testing.expect(t, !ok, "the wrong size")
	_, ok = command_from(77, raw, 3)
	testing.expect(t, !ok, "an unknown kind")
}

// A recorder that is full counts what it lost and keeps what it has.
@(test)
test_capture_overflow_is_counted :: proc(t: ^testing.T) {
	s := scene_new(48000)
	defer scene_free(s)
	capture_start(s.m, 8)
	out := scene_run(s, 24000)
	defer delete(out)
	cap := capture_stop(s.m)
	defer capture_destroy(cap)
	kept, lost := capture_records(cap)
	testing.expect_value(t, kept, 8)
	testing.expect(t, lost > 0)
	data := capture_encode(s.m, cap)
	defer delete(data)
	file, ok := capture_parse(data)
	defer capture_file_destroy(&file)
	testing.expect(t, ok && file.header.overflow == lost)
}

// A command with a frame takes effect on that frame, in the middle of a
// call: the block is cut there. One whose frame has gone is applied at once
// and counted.
@(test)
test_command_lands_on_its_frame :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	long := make([]f32, 48000)
	defer delete(long)
	for &x in long {x = 0.3}
	id := add_sound(m, {long, 48000})
	v := play(m, {sound = id, gain = {1, 1}})
	late := latency(m)
	F :: 1234 // inside a call of 2000 frames
	stop(m, v, at = F)
	out := make([]f32, 2 * 4000)
	defer delete(out)
	mix(m, out[:2 * 2000])
	mix(m, out[2 * 2000:])
	testing.expect(t, out[2 * (F - 1 + late)] > 0.29, "still playing the frame before")
	testing.expect_value(t, out[2 * (F + late)], 0)
	e, got := poll(m)
	testing.expect(t, got && e.voice == v && e.reason == .Stopped)
	// Late: its frame is long gone.
	w := play(m, {sound = id, gain = {1, 1}})
	before := stats(m).late
	stop(m, w, at = 10)
	mix(m, out[:2 * 100])
	testing.expect_value(t, stats(m).late, before + 1)
	e, got = poll(m)
	testing.expect(t, got && e.voice == w, "applied at once")
}

// Held commands do not stop the ring: more waiting than the table holds go
// through as room is made.
@(test)
test_many_held_commands :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	for i in 0 ..< 300 {set_bus_gain(m, .Music, 0.5, at = u64(100 + i))}
	out := make([]f32, 2 * 1000)
	defer delete(out)
	mix(m, out)
	testing.expect_value(t, m.held_n, 0)
	testing.expect_value(t, m.dropped, 0)
}
