package audio

import "core:math"
import "core:testing"

@(private = "file")
peak :: proc(out: []f32, channel: int) -> f32 {
	p: f32
	for i := channel; i < len(out); i += 2 {p = max(p, abs(out[i]))}
	return p
}

// A sound plays once, at its pitch, through the gains it was given, and
// stops at its end.
@(test)
test_mixer_plays_once :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 48000)
	ones := make([]f32, 4800) // 0.1 s at 48 kHz
	defer delete(ones)
	for &s in ones {s = 0.5}
	id := add_sound(m, {ones, 48000})
	testing.expect(t, play(m, {id, {1, 0.25}, 1}))
	out := make([]f32, 2 * 9600)
	defer delete(out)
	mix(m, out)
	testing.expect(t, abs(out[0] - 0.5) < 1e-6 && abs(out[1] - 0.125) < 1e-6, "gains apply")
	testing.expect(t, out[2 * 4790] != 0 && out[2 * 4800] == 0, "stops at its end")
	mix(m, out)
	testing.expect_value(t, peak(out, 0), 0) // and does not play again

	// Twice the pitch: half as long.
	play(m, {id, {1, 1}, 2})
	mix(m, out)
	testing.expect(t, out[2 * 2390] != 0 && out[2 * 2400] == 0)
}

// More sounds than voices: the quietest give way to louder ones; a
// quieter newcomer is the one dropped.
@(test)
test_mixer_steals_quietest :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 1000)
	long := make([]f32, 10_000)
	defer delete(long)
	for &s in long {s = 0.01}
	id := add_sound(m, {long, 1000})
	for i in 0 ..< MAX_VOICES {play(m, {id, {0.1 + f32(i) * 0.01, 0}, 1})}
	out: [2 * 16]f32
	mix(m, out[:])
	play(m, {id, {0.01, 0}, 1}) // quieter than all: dropped
	play(m, {id, {5, 0}, 1}) // louder: replaces the quietest (0.1)
	mix(m, out[:])
	total: f32
	for v in m.voices {if v.active {total += v.gain[0]}}
	want: f32 = 5
	for i in 1 ..< MAX_VOICES {want += 0.1 + f32(i) * 0.01}
	testing.expectf(t, abs(total - want) < 1e-4, "voices sum to %v, want %v", total, want)
}

// The ring never blocks: a flood is dropped and counted, not waited on.
@(test)
test_mixer_command_ring :: proc(t: ^testing.T) {
	m := new(Mixer)
	defer free(m)
	mixer_init(m, 1000)
	s := []f32{1, 1, 1, 1}
	id := add_sound(m, {s, 1000})
	accepted := 0
	for _ in 0 ..< COMMAND_RING + 10 {if play(m, {id, {1, 1}, 1}) {accepted += 1}}
	testing.expect_value(t, accepted, COMMAND_RING)
	testing.expect_value(t, m.dropped, 10)
	out: [8]f32
	mix(m, out[:])
	testing.expect(t, play(m, {id, {1, 1}, 1}), "room again once mixed")
}

// Loud mixes are bent under 1 (no wrap-around crackle); quiet ones pass.
@(test)
test_mixer_soft_clip :: proc(t: ^testing.T) {
	testing.expect_value(t, soft_clip(0.5), 0.5)
	testing.expect_value(t, soft_clip(-0.5), -0.5)
	for x in ([]f32{0.9, 2, 10, 1000}) {
		y := soft_clip(x)
		testing.expectf(t, y > 0.8 && y < 1 && soft_clip(-x) == -y, "soft_clip(%v) = %v", x, y)
	}
	testing.expect(t, soft_clip(2) < soft_clip(3), "still rises")
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
