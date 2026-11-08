package music_tool

import "core:slice"
import "core:strings"
import "core:testing"

// The notes of every committed score, hashed: the motif and form words must not
// change what a score without them reads as.
SCORE_DEATH :: #load("../../assets/music/death.score", string)
SCORE_DEEP :: #load("../../assets/music/deep.score", string)
SCORE_DISCOVERY :: #load("../../assets/music/discovery.score", string)
SCORE_FAR :: #load("../../assets/music/far.score", string)
SCORE_IGNITE :: #load("../../assets/music/ignite.score", string)
SCORE_MEADOW :: #load("../../assets/music/meadow.score", string)
SCORE_NIGHT :: #load("../../assets/music/night.score", string)
SCORE_TITLE :: #load("../../assets/music/title.score", string)

piece_hash :: proc(p: ^Piece) -> u64 {
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: ^u64, v: u64) {
		h^ = (h^ ~ v) * 0x100000001b3
	}
	for n in p.notes {
		mix(&h, u64(n.start))
		mix(&h, u64(n.length))
		mix(&h, u64(n.key) | u64(n.velocity) << 8 | u64(n.part) << 16)
	}
	for x in p.pedals {mix(&h, u64(x.at) | u64(x.part) << 32 | u64(x.down) << 40)}
	for x in p.tempos {mix(&h, u64(x.at) | u64(x.bpm * 100) << 32)}
	for x in p.meters {mix(&h, u64(x.at) | u64(x.num) << 32 | u64(x.den) << 40)}
	mix(&h, u64(p.end))
	return h
}

@(test)
test_existing_scores_read_as_before :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		name: string,
		src:  string,
		want: u64,
	} {
		{"death", SCORE_DEATH, 0xe5463079d7efbeb2},
		{"deep", SCORE_DEEP, 0x30030fa73e0aa661},
		{"discovery", SCORE_DISCOVERY, 0x83bcd9cb5a8070f6},
		{"far", SCORE_FAR, 0xb2205f77065f7ee7},
		{"meadow", SCORE_MEADOW, 0xa21c3cc4ea795c61},
		{"night", SCORE_NIGHT, 0x9871acc29132bd7d},
		{"title", SCORE_TITLE, 0x9686b999ccc98dcc},
	}
	for c in cases {
		p, err, ok := score_parse(c.src, c.name)
		if !testing.expectf(t, ok, "%s", err) {continue}
		got := piece_hash(&p)
		testing.expectf(t, got == c.want, "%s: want 0x%x, got 0x%x", c.name, c.want, got)
	}
}

// ---- motifs and form -------------------------------------------------------

MOTIF_HEAD :: `title "T"
tempo 120
meter 4/4
key d dorian
instrument piano preset 0:0
`

motif_piece :: proc(t: ^testing.T, body: string) -> (p: Piece, ok: bool) {
	src := strings.concatenate({MOTIF_HEAD, body})
	err: string
	p, err, ok = score_parse(src, "t.score")
	testing.expectf(t, ok, "%s", err)
	return
}

keys_of :: proc(p: ^Piece, from, count: int) -> []int {
	out := make([]int, count)
	for i in 0 ..< count {out[i] = int(p.notes[from + i].key)}
	return out
}

expect_keys :: proc(t: ^testing.T, what: string, got, want: []int) {
	testing.expectf(t, slice.equal(got, want), "%s: want %v, got %v", what, want, got)
}

@(test)
test_motif_degrees_in_d_dorian :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(
		t,
		"motif m | d4:q e4 f4 g4 |\npart a piano\n  play m degrees 2\n  play m degrees -1\n",
	)
	if !ok {return}
	// d e f g, two degrees up: f g a b; one down: c d e f
	expect_keys(t, "degrees 2", keys_of(&p, 0, 4), {65, 67, 69, 71})
	expect_keys(t, "degrees -1", keys_of(&p, 4, 4), {60, 62, 64, 65})
}

@(test)
test_motif_transpose_and_invert :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(
		t,
		"motif m | g4:q a4 b4 d5 |\npart a piano\n  play m transpose -5\n  play m invert\n",
	)
	if !ok {return}
	expect_keys(t, "transpose", keys_of(&p, 0, 4), {62, 64, 66, 69})
	// around the first note, g4 = 67: a4 69 -> 65, b4 71 -> 63, d5 74 -> 60
	expect_keys(t, "invert", keys_of(&p, 4, 4), {67, 65, 63, 60})
}

@(test)
test_motif_retrograde_keeps_durations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(t, "motif m | c4:q d4:e e4 f4:h |\npart a piano\n  play m retrograde\n")
	if !ok {return}
	want := [?][3]int{{65, 0, 960}, {64, 960, 240}, {62, 1200, 240}, {60, 1440, 480}}
	testing.expect_value(t, len(p.notes), 4)
	for w, i in want {
		n := p.notes[i]
		testing.expectf(
			t,
			int(n.key) == w[0] && int(n.start) == w[1] && int(n.length) == w[2],
			"note %d: want %v, got key %d at %d for %d",
			i,
			w,
			n.key,
			n.start,
			n.length,
		)
	}
}

@(test)
test_motif_augment_and_diminish :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(t, "motif m | c4:q d4:q |\npart a piano\n  play m augment 2\n")
	if !ok {return}
	testing.expect_value(t, len(p.notes), 2)
	testing.expect_value(t, p.notes[0].length, u32(960))
	testing.expect_value(t, p.notes[1].start, u32(960))
	m := Motif {
		name = "m",
	}
	append(&m.items, Item{key = 60, dur = 480}, Item{key = 62, dur = 240})
	out, err := motif_apply(m, {{.Diminish, 2}}, Scale{})
	testing.expect_value(t, err, "")
	testing.expect_value(t, out.items[0].dur, u32(240))
	testing.expect_value(t, out.items[1].dur, u32(120))
	_, err = motif_apply(m, {{.Diminish, 7}}, Scale{})
	testing.expect(t, err != "", "diminish by 7 cuts a tick")
}

@(test)
test_motif_vary_keeps_the_ends :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	m := Motif {
		name = "m",
	}
	base := [?]u8{62, 64, 65, 67, 69, 67, 65, 64, 62, 60, 62, 64}
	for k in base {append(&m.items, Item{key = k, dur = 240})}
	changed_any := false
	for scale in ([?]Scale{{}, scale_of("d", "dorian")}) {
		for seed in 0 ..< 40 {
			a, _ := motif_apply(m, {{.Vary, seed}}, scale)
			b, _ := motif_apply(m, {{.Vary, seed}}, scale)
			diff := 0
			for it, i in a.items {
				testing.expect_value(t, it.key, b.items[i].key) // seeded: the same twice
				if it.key != m.items[i].key {diff += 1}
			}
			testing.expectf(
				t,
				diff <= len(base) / 4,
				"seed %d changed %d of %d",
				seed,
				diff,
				len(base),
			)
			testing.expect_value(t, a.items[0].key, base[0])
			testing.expect_value(t, a.items[len(base) - 1].key, base[len(base) - 1])
			changed_any ||= diff > 0
		}
	}
	testing.expect(t, changed_any, "vary never changed a note")
}

@(test)
test_form_with_a_primed_section :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(
		t,
		`motif m | d4:q e4 f4 g4 |
part a piano
  section A
    play m
  end
  section B
    play m degrees 2
  end
  form A A B A'
`,
	)
	if !ok {return}
	testing.expect_value(t, len(p.notes), 16)
	testing.expect_value(t, len(p.motifs), 4)
	for st, i in p.motifs {
		testing.expect_value(t, st.start, u32(i * 1920))
		testing.expect_value(t, st.varied, i == 3)
	}
	expect_keys(t, "A", keys_of(&p, 0, 4), {62, 64, 65, 67})
	expect_keys(t, "A again", keys_of(&p, 4, 4), {62, 64, 65, 67})
	expect_keys(t, "B", keys_of(&p, 8, 4), {65, 67, 69, 71})
	primed := keys_of(&p, 12, 4)
	plain := [4]int{62, 64, 65, 67}
	diff := 0
	for k, i in primed {
		if k != plain[i] {diff += 1}
	}
	testing.expectf(t, diff <= 1 && primed[0] == 62 && primed[3] == 67, "A': %v", primed)
	// the plain form is written out the same as the motif played by hand
	q, _ := motif_piece(t, "motif m | d4:q e4 f4 g4 |\npart a piano\n  play m\n  play m\n")
	testing.expect_value(t, piece_hash(&p) != piece_hash(&q), true)
}

@(test)
test_section_repeat :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(
		t,
		"motif m | d4:q e4 f4 g4 |\npart a piano\n  section A repeat 3\n    play m\n  end\n  form A\n",
	)
	if !ok {return}
	testing.expect_value(t, len(p.notes), 12)
	testing.expect_value(t, p.end, u32(3 * 1920))
}

@(test)
test_cresc_and_dim_ramp_velocity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(
		t,
		"part a piano\n  | mp cresc c4:q c4 c4 c4 | f dim c4:q c4 c4 c4 | mp c4:w |\n",
	)
	if !ok {return}
	want := [?]u8{64, 72, 80, 88, 96, 88, 80, 72, 64}
	testing.expect_value(t, len(p.notes), len(want))
	for w, i in want {testing.expect_value(t, p.notes[i].velocity, w)}
	_, err, bad := score_parse(
		strings.concatenate({MOTIF_HEAD, "part a piano\n  | f cresc c4:w | p |\n"}),
		"t.score",
	)
	testing.expect(t, !bad && strings.contains(err, "does not rise"), err)
	_, err, bad = score_parse(
		strings.concatenate({MOTIF_HEAD, "part a piano\n  | mp cresc c4:w |\n"}),
		"t.score",
	)
	testing.expect(t, !bad && strings.contains(err, "not followed by a dynamic"), err)
}

@(test)
test_articulations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(t, "part a piano\n  | mf c4:q^stacc d4^ten e4^legato f4 |\n")
	if !ok {return}
	testing.expect_value(t, p.notes[0].length, u32(240))
	testing.expect_value(t, p.notes[1].length, u32(480))
	testing.expect_value(t, p.notes[1].velocity, u8(80 + TEN_ACCENT))
	// 30 ms at 120 bpm is 28.8 ticks of 480 to the quarter
	testing.expect_value(t, p.notes[2].length, u32(480 + 29))
	testing.expect_value(t, p.notes[3].length, u32(480))
}

@(test)
test_motif_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		body, want: string,
	} {
		{"part a piano\n  play nothing\n", "is not declared"},
		{"motif m | c4:q |\nmotif m | d4:q |\n", "already declared"},
		{"motif m | [c4 e4]:q |\n", "no chords"},
		{"motif m | r:q |\n", "has no note"},
		{"motif m | c4:w |\npart a piano\n  play m wiggle\n", "unknown word 'wiggle'"},
		{"motif m | c4:w |\npart a piano\n  play m degrees\n", "needs a number"},
		{"motif m | c4:w |\npart a piano\n  section A\n  | c4:w |\n", "never closed"},
		{"motif m | c4:w |\npart a piano\n  section A\n  | c4:w |\n  end\n", "no 'form'"},
		{"part a piano\n  form A\n", "is not declared"},
		{"part a piano\n  | c4:w^loud |\n", "unknown articulation"},
	}
	for c in cases {
		_, err, ok := score_parse(strings.concatenate({MOTIF_HEAD, c.body}), "t.score")
		testing.expectf(
			t,
			!ok && strings.contains(err, c.want),
			"%q: want '%s', got '%s'",
			c.body,
			c.want,
			err,
		)
	}
	// degrees needs a key
	src := "title \"T\"\ntempo 120\ninstrument piano preset 0:0\nmotif m | c4:w |\npart a piano\n  play m degrees 1\n"
	_, err, ok := score_parse(src, "t.score")
	testing.expect(t, !ok && strings.contains(err, "needs the piece's 'key'"), err)
}

@(test)
test_ear_reports_motifs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	p, ok := motif_piece(
		t,
		`motif m | d4:q e4 f4 g4 |
part a piano
  section A
    play m
  end
  form A A A'
`,
	)
	if !ok {return}
	e := listen(&p, "t", "t.score")
	testing.expect_value(t, len(e.motifs), 1)
	testing.expect_value(t, e.motifs[0].name, "m")
	testing.expect_value(t, len(e.motifs[0].bars), 3)
	testing.expect_value(t, e.motifs[0].varied[2], true)
	b: strings.Builder
	ear_report(e, &b)
	text := strings.to_string(b)
	testing.expectf(
		t,
		strings.contains(text, "m: stated 3 times, 1 varied; bars 1 2 3'"),
		"%s",
		text,
	)
}
