package music_tool

import "core:fmt"

// Motifs: a figure declared once and played back transformed. The score
// parser (score.odin) reads the words; this file is the figure and what can be
// done to it. The operations are pure functions of the figure, so each is
// tested on its own.

// Articulation of a note, written `^stacc`, `^ten` or `^legato` after it.
Art :: enum u8 {
	None,
	Stacc, // half the written length
	Ten, // the full length, a little accented
	Legato, // held 30 ms over into the next note
}

LEGATO_MS :: 30.0
TEN_ACCENT :: 6 // velocity added by `^ten`

// One note or rest of a motif. A velocity of 0 is the part's dynamic when the
// motif is played.
Item :: struct {
	key:  u8,
	rest: bool,
	dur:  u32,
	vel:  u8,
	tie:  bool,
	art:  Art,
}

Motif :: struct {
	name:  string,
	items: [dynamic]Item,
	line:  int,
}

Op_Kind :: enum u8 {
	Transpose,
	Degrees,
	Invert,
	Retrograde,
	Augment,
	Diminish,
	Vary,
}

Op :: struct {
	kind: Op_Kind,
	n:    int,
}

// A motif stated in a piece (the ear reads these).
Stated :: struct {
	name:   string,
	part:   u8,
	start:  u32,
	varied: bool, // `vary` applied, by hand or by a primed section
}

MODE_STEPS := [?]struct {
	name:  string,
	steps: [7]int,
} {
	{"major", {0, 2, 4, 5, 7, 9, 11}},
	{"minor", {0, 2, 3, 5, 7, 8, 10}},
	{"aeolian", {0, 2, 3, 5, 7, 8, 10}},
	{"dorian", {0, 2, 3, 5, 7, 9, 10}},
	{"phrygian", {0, 1, 3, 5, 7, 8, 10}},
	{"lydian", {0, 2, 4, 6, 7, 9, 11}},
	{"mixolydian", {0, 2, 4, 5, 7, 9, 10}},
	{"locrian", {0, 1, 3, 5, 6, 8, 10}},
}

// A piece's key as a tonic pitch class and the steps of its scale.
Scale :: struct {
	tonic: int,
	steps: [7]int,
	known: bool,
}

scale_of :: proc(key, mode: string) -> (s: Scale) {
	if len(key) < 1 || key[0] < 'a' || key[0] > 'g' {return}
	pc := PITCH_CLASS[key[0] - 'a']
	if len(key) == 2 &&
	   key[1] ==
		   '#' {pc += 1} else if len(key) == 2 && key[1] == 'b' {pc -= 1} else if len(key) != 1 {return}
	for m in MODE_STEPS {
		if m.name == mode {
			return Scale{(pc + 12) % 12, m.steps, true}
		}
	}
	return
}

@(private = "file")
fdiv :: proc(a, b: int) -> int {
	q := a / b
	if a % b != 0 && (a < 0) != (b < 0) {q -= 1}
	return q
}

// degree_shift moves a key along the scale by n degrees. A note off the scale
// keeps its distance above the scale note under it.
degree_shift :: proc(key, n: int, s: Scale) -> int {
	rel := key - s.tonic
	oct := fdiv(rel, 12)
	r := rel - 12 * oct
	d := 0
	for step, i in s.steps {
		if step <= r {d = i}
	}
	off := r - s.steps[d]
	to := oct * 7 + d + n
	q := fdiv(to, 7)
	return s.tonic + 12 * q + s.steps[to - 7 * q] + off
}

// splitmix64: the seeded stream `vary` draws from.
@(private = "file")
next_rand :: proc(state: ^u64) -> u64 {
	state^ += 0x9e3779b97f4a7c15
	z := state^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// motif_apply returns the motif with each operation applied in order.
motif_apply :: proc(m: Motif, ops: []Op, s: Scale) -> (out: Motif, err: string) {
	out = Motif {
		name = m.name,
		line = m.line,
	}
	for it in m.items {append(&out.items, it)}
	for op in ops {
		switch op.kind {
		case .Transpose:
			for &it in out.items {
				if it.rest {continue}
				k := int(it.key) + op.n
				if k < 0 ||
				   k > 127 {return {}, fmt.aprintf("transpose %d leaves the keyboard", op.n)}
				it.key = u8(k)
			}
		case .Degrees:
			if !s.known {return {}, "'degrees' needs the piece's 'key'"}
			for &it in out.items {
				if it.rest {continue}
				k := degree_shift(int(it.key), op.n, s)
				if k < 0 ||
				   k > 127 {return {}, fmt.aprintf("degrees %d leaves the keyboard", op.n)}
				it.key = u8(k)
			}
		case .Invert:
			first := -1
			for it in out.items {
				if !it.rest {first = int(it.key); break}
			}
			for &it in out.items {
				if it.rest {continue}
				k := 2 * first - int(it.key)
				if k < 0 || k > 127 {return {}, "invert leaves the keyboard"}
				it.key = u8(k)
			}
		case .Retrograde:
			n := len(out.items)
			ties := make([]bool, n)
			for it, i in out.items {ties[i] = it.tie}
			for i in 0 ..< n / 2 {
				out.items[i], out.items[n - 1 - i] = out.items[n - 1 - i], out.items[i]
			}
			// A tie runs into the next note; reversed, it runs into the former
			// previous one.
			for &it, k in out.items {
				it.tie = ties[n - 2 - k] if k + 1 < n else false
			}
		case .Augment:
			if op.n < 1 || op.n > 16 {return {}, "augment is from 1 to 16"}
			for &it in out.items {it.dur *= u32(op.n)}
		case .Diminish:
			if op.n < 1 || op.n > 16 {return {}, "diminish is from 1 to 16"}
			for &it in out.items {
				if it.dur % u32(op.n) !=
				   0 {return {}, fmt.aprintf("diminish %d cuts a note short of a tick", op.n)}
				it.dur /= u32(op.n)
			}
		case .Vary:
			motif_vary(&out, u64(op.n), s)
		}
	}
	return out, ""
}

// motif_vary changes at most one note in four by a step (a scale degree in a
// known key, else two semitones), never the first or the last note, nor a note
// tied to its neighbour. The seed makes it the same every time.
motif_vary :: proc(m: ^Motif, seed: u64, s: Scale) {
	notes: [dynamic]int
	for it, i in m.items {
		if !it.rest {append(&notes, i)}
	}
	if len(notes) < 3 {return}
	eligible: [dynamic]int
	for ni in 1 ..< len(notes) - 1 {
		at := notes[ni]
		if m.items[at].tie || m.items[notes[ni - 1]].tie {continue}
		append(&eligible, at)
	}
	state := seed
	for _ in 0 ..< len(notes) / 4 {
		if len(eligible) == 0 {break}
		pick := int(next_rand(&state) % u64(len(eligible)))
		at := eligible[pick]
		ordered_remove(&eligible, pick)
		dir := 1 if next_rand(&state) & 1 == 0 else -1
		for _ in 0 ..< 2 {
			k := int(m.items[at].key)
			k = degree_shift(k, dir, s) if s.known else k + 2 * dir
			if k >= 0 && k <= 127 {
				m.items[at].key = u8(k)
				break
			}
			dir = -dir
		}
	}
}

// tempo_bpm_at is the tempo in force at a tick.
tempo_bpm_at :: proc(tempos: []Tempo, tick: u32) -> f64 {
	bpm := 120.0
	for t in tempos {
		if t.at > tick {break}
		bpm = t.bpm
	}
	return bpm
}
