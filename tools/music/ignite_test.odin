package music_tool

import "common:game"
import "core:slice"
import "core:testing"

// The Ignite cue's loudest second falls where the planet appears: 1.6 s after
// the cue starts. Source: client/screen/ignite.odin, IGNITE_PHASES = 0.8, 0.4,
// 0.4, 0.6, 0.3 s for Wind, Flash, Streaks, Dive, Fade; the Dive starts at
// 0.8 + 0.4 + 0.4 = 1.6 s. This is the proxy for the render check; step 5
// measures the rendered audio.
IGNITE_PLANET_SECONDS :: 1.6

// ignite_loudest_window: the start (s) of the one-second window, slid in 0.1 s
// steps, holding the most velocity-weighted sounding time of the notes.
ignite_loudest_window :: proc(p: ^Piece) -> f64 {
	best, at := -1.0, 0.0
	for i in 0 ..< 200 {
		w0 := f64(i) * 0.1
		sum := 0.0
		for n in p.notes {
			s := ticks_to_seconds(p, f64(n.start))
			e := ticks_to_seconds(p, f64(n.start + n.length))
			ov := min(e, w0 + 1) - max(s, w0)
			if ov > 0 {sum += ov * f64(n.velocity)}
		}
		if sum > best {best, at = sum, w0}
	}
	return at
}

@(test)
test_ignite_peaks_at_the_planet :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, msg, ok := score_parse(SCORE_IGNITE, "ignite.score")
	if !testing.expectf(t, ok, "%s", msg) {return}
	centre := ignite_loudest_window(&p) + 0.5
	testing.expectf(
		t,
		abs(centre - IGNITE_PLANET_SECONDS) <= 0.5,
		"the loudest second is centred at %v s, the planet appears at 1.6 s",
		centre,
	)
	s := ticks_to_seconds(&p, f64(p.end))
	testing.expectf(t, s > 10 && s < 14, "the cue is %v s", s)
	testing.expect(t, !p.loop, "the cue does not loop")
}

@(test)
test_ignite_opens_with_the_hook :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, msg, ok := score_parse(SCORE_IGNITE, "ignite.score")
	if !testing.expectf(t, ok, "%s", msg) {return}
	m := make([dynamic]Note)
	mp := melody_part(&p)
	for n in p.notes {
		if int(n.part) == mp {append(&m, n)}
	}
	slice.sort_by(m[:], proc(a, b: Note) -> bool {return a.start < b.start})
	if !testing.expect(t, len(m) >= game.MOTIF_NOTES) {return}
	hook := game.motif_of(game.earth_address())
	for h, i in hook {
		testing.expectf(
			t,
			m[i].key == h.pitch,
			"note %d: key %d, the hook has %d",
			i,
			m[i].key,
			h.pitch,
		)
	}
	last := m[len(m) - 1]
	testing.expect_value(t, last.key % 12, u8(0))
}
