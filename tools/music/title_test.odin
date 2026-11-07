package music_tool

import "common:game"
import "core:slice"
import "core:testing"

// The title piece is built on Earth's hook: its melody part opens with it.

@(private = "file")
title_melody :: proc(p: ^Piece) -> []Note {
	mp := melody_part(p)
	out := make([dynamic]Note)
	for n in p.notes {
		if int(n.part) == mp {append(&out, n)}
	}
	slice.sort_by(out[:], proc(a, b: Note) -> bool {return a.start < b.start})
	return out[:]
}

@(test)
test_title_opens_with_the_hook :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, msg, ok := score_parse(SCORE_TITLE, "title.score")
	if !testing.expectf(t, ok, "%s", msg) {return}
	m := title_melody(&p)
	if !testing.expect(t, len(m) >= game.MOTIF_NOTES, "the melody has the hook's notes") {return}
	testing.expectf(
		t,
		ticks_to_seconds(&p, f64(m[0].start)) < 5,
		"the first melody note starts at %v s, not within 5 s",
		ticks_to_seconds(&p, f64(m[0].start)),
	)
	hook := game.motif_of(game.earth_address())
	eighth := u32(PPQ / 2)
	for h, i in hook {
		testing.expectf(
			t,
			m[i].key == h.pitch,
			"note %d: key %d, the hook has %d",
			i,
			m[i].key,
			h.pitch,
		)
		testing.expectf(
			t,
			m[i].start == m[0].start + u32(h.start) * eighth,
			"note %d starts off the hook's rhythm",
			i,
		)
		testing.expectf(
			t,
			m[i].length == u32(h.length) * eighth,
			"note %d: length %d, the hook has %d eighths",
			i,
			m[i].length,
			h.length,
		)
	}
}

@(test)
test_earth_hook_is_singable :: proc(t: ^testing.T) {
	hook := game.motif_of(game.earth_address())
	lo, hi := 127, 0
	longest := 0
	for h, i in hook {
		lo = min(lo, int(h.pitch))
		hi = max(hi, int(h.pitch))
		longest = max(longest, int(h.length))
		if i > 0 {
			leap := abs(int(h.pitch) - int(hook[i - 1].pitch))
			testing.expectf(t, leap <= 9, "leap of %d semitones before note %d", leap, i)
		}
	}
	testing.expectf(t, hi - lo <= 18, "range of %d semitones", hi - lo)
	testing.expect_value(t, int(hook[game.MOTIF_NOTES - 1].length), longest)
	for h, i in hook[:game.MOTIF_NOTES - 1] {
		testing.expectf(t, int(h.length) < longest, "note %d is as long as the last", i)
	}
}

@(test)
test_title_is_about_three_minutes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, msg, ok := score_parse(SCORE_TITLE, "title.score")
	if !testing.expectf(t, ok, "%s", msg) {return}
	s := ticks_to_seconds(&p, f64(p.end))
	testing.expectf(t, s > 150 && s < 210, "the title is %v s", s)
	testing.expect(t, p.loop, "the title loops")
}
