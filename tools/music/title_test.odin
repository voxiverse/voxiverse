package music_tool

import "common:game"
import "core:slice"
import "core:testing"

// The title (owner, 2026-11-07): its own hook, stated three times, building,
// then the theme within about 20 s; it loops.

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

// TITLE_HOOK: the hook's notes (g4 c5 e5 d5 c5 d5 e5 ...), the first six the
// same in both its statements.
@(private = "file")
TITLE_HOOK := [?]u8{67, 72, 76, 74, 72, 74}

@(test)
test_title_hook_three_times_then_the_theme :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, msg, ok := score_parse(SCORE_TITLE, "title.score")
	if !testing.expectf(t, ok, "%s", msg) {return}
	m := title_melody(&p)
	if !testing.expect(t, len(m) > 30, "a melody") {return}
	testing.expectf(t, ticks_to_seconds(&p, f64(m[0].start)) < 2, "the hook starts at once")
	// The hook's opening, counted before the theme begins (its first low note,
	// under the hook's register).
	theme := 0
	for n, i in m {if n.key < 67 {theme = i; break}}
	testing.expect(t, theme > 0, "the theme follows the hook")
	count := 0
	for i := 0; i + len(TITLE_HOOK) <= theme; i += 1 {
		match := true
		for k, j in TITLE_HOOK {if m[i + j].key != k {match = false; break}}
		if match {count += 1}
	}
	testing.expect_value(t, count, 3)
	at := ticks_to_seconds(&p, f64(m[theme].start))
	testing.expectf(t, at < 25, "the theme starts at %v s, not within 25 s", at)
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
test_title_loops :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, msg, ok := score_parse(SCORE_TITLE, "title.score")
	if !testing.expectf(t, ok, "%s", msg) {return}
	s := ticks_to_seconds(&p, f64(p.end))
	testing.expectf(t, s > 60 && s < 210, "the title is %v s", s)
	testing.expect(t, p.loop, "the title loops")
}
