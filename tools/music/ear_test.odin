package music_tool

import "core:math"
import "core:strings"
import "core:testing"

EAR_HEAD :: `title "T"
tempo 120
meter 4/4
key c major
instrument piano preset 0:0
`

// ear_piece parses a score made of the header and the parts given.
ear_piece :: proc(t: ^testing.T, parts: string) -> (p: Piece, ok: bool) {
	src := strings.concatenate({EAR_HEAD, parts})
	msg: string
	p, msg, ok = score_parse(src, "t.score")
	testing.expectf(t, ok, "%s", msg)
	return
}

@(test)
test_ear_scale_is_stepwise :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := ear_piece(t, "part m piano\n  | c4:e d4 e4 f4 g4 a4 b4 c5 |\n")
	if !ok {return}
	e := listen(&p, "scale", "t.score")
	testing.expect_value(t, e.stepwise, 1.0)
	testing.expect_value(t, e.big_leaps, 0.0)
	testing.expect_value(t, e.range, 12)
	testing.expect_value(t, e.longest_run, 7)
	testing.expect_value(t, e.leap_recovered, 1.0) // no leaps: nothing unanswered
}

@(test)
test_ear_leaps :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// up an octave and a step back (answered), up a fifth and away (not), then a tenth
	p, ok := ear_piece(t, "part m piano\n  | c4:q c5 b4 b4 | g4:q d5 g5 g4 |\n")
	if !ok {return}
	e := listen(&p, "leaps", "t.score")
	// intervals: 12 -1 0 | 5... g4 after b4 is -4
	testing.expect(t, e.big_leaps > 0)
	testing.expect(t, e.leap_recovered > 0 && e.leap_recovered < 1)
	found := false
	for line in e.critique {
		if strings.contains(line, "t.score:7:") &&
		   strings.contains(line, "not answered") {found = true}
	}
	testing.expect(t, found, "a leap that is not answered is in the critique with its line")
}

@(test)
test_ear_motif_return :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	once, ok := ear_piece(t, "part m piano\n  | c4:q d4 f4 e4 | a3:q d4 g4 b3 |\n")
	if !ok {return}
	testing.expect_value(t, listen(&once, "once", "t.score").motif_return, 0.0)
	twice: Piece
	twice, ok = ear_piece(t, "part m piano\n  | c4:q d4 f4 e4 | a3:q c4 d4 f4 | e4:q r:h. |\n")
	if !ok {return}
	e := listen(&twice, "twice", "t.score")
	// 9 notes (c d f e a c d f e), 6 figures; the first and the last are one
	testing.expect(t, math.abs(e.motif_return - 2.0 / 6.0) < 1e-9, "a figure stated twice returns")
	// the same intervals in a different rhythm are another figure
	other, ok2 := ear_piece(
		t,
		"part m piano\n  | c4:q d4 f4 e4 | a3:q c4:q. d4:e f4:q | e4:q r:h. |\n",
	)
	if !ok2 {return}
	testing.expect(t, listen(&other, "other", "t.score").motif_return < e.motif_return)
}

@(test)
test_ear_accompaniment_variety :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := ear_piece(
		t,
		"part m piano melody\n  | c5:w | d5:w | e5:w | f5:w |\npart arp piano\n  | c3:q e3 g3 e3 | c3:q e3 g3 e3 | c3:q e3 g3 e3 | c3:q e3 g3 e3 |\n",
	)
	if !ok {return}
	e := listen(&p, "arp", "t.score")
	testing.expect_value(t, e.accomp_variety, 0.25)
	testing.expect_value(t, e.melody, "m")
}

@(test)
test_ear_melody_part_is_the_highest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := ear_piece(t, "part low piano\n  | c2:w |\npart high piano\n  | c6:w |\n")
	if !ok {return}
	testing.expect_value(t, listen(&p, "x", "t.score").melody, "high")
}

@(test)
test_ear_pedal_holds_a_note :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pedalled, ok := ear_piece(t, "part m piano\n  | ped c4:q r:q r:h | d4:q r:q r:h unped |\n")
	if !ok {return}
	plain: Piece
	plain, ok = ear_piece(t, "part m piano\n  | c4:q r:q r:h | d4:q r:q r:h |\n")
	if !ok {return}
	sp := sounding(&pedalled)
	testing.expect_value(t, sp[0].end, 480)
	testing.expect_value(t, sp[0].tail_end, 3840) // until unped
	testing.expect_value(t, sounding(&plain)[0].tail_end, 480)
	// the tail meets the next chord's note: a whole tone rubs, the dry notes do not
	rp, _ := roughness(sp)
	rd, _ := roughness(sounding(&plain))
	testing.expect(t, rp > 0)
	testing.expect_value(t, rd, 0.0)
	// and the tail counts in the bar after, at half weight
	w := weight_of(sp[0], 1920, 3840)
	testing.expect_value(t, w, 0.5 * 1920)
}

@(test)
test_ear_chord_fit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// C major under a melody that is on it, then a note off it on beat 3
	p, ok := ear_piece(
		t,
		"part m piano melody\n  | e5:h f#5:h |\npart b piano\n  | [c3 e3 g3]:w |\n",
	)
	if !ok {return}
	e := listen(&p, "fit", "t.score")
	testing.expect_value(t, e.strong_beats, 2)
	testing.expect_value(t, e.strong_beat_clash, 1)
	found := false
	for line in e.critique {
		if strings.contains(line, "bar 1 beat 3: f#5 over C major") {found = true}
	}
	testing.expect(t, found, "the clash is named")
}

@(test)
test_sethares_peaks_near_a_quarter_critical_band :: proc(t: ^testing.T) {
	f := 500.0
	band := 25 + 75 * math.pow(1 + 1.4 * (f / 1000) * (f / 1000), 0.69) // Zwicker, Hz
	best, at := 0.0, 0.0
	for d := 0.5; d < 300; d += 0.5 {
		if v := sethares(f, f + d, 1, 1); v > best {best, at = v, d}
	}
	testing.expectf(t, at > 0.2 * band && at < 0.3 * band, "peak at %v Hz, band %v Hz", at, band)
	testing.expect_value(t, sethares(f, f, 1, 1), 0.0)
}
