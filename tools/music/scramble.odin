package music_tool

import "common:base"
import "core:slice"

// Scramblers: a piece with its notes put wrong and its rhythm kept. The ear's
// calibration scores masters against these. Both are pure: the same piece and
// seed give the same result, from base.rng_make and nothing else.

@(private = "file")
clone_piece :: proc(p: Piece) -> (q: Piece) {
	q = p
	q.parts = slice.clone_to_dynamic(p.parts[:])
	q.notes = slice.clone_to_dynamic(p.notes[:])
	q.sources = slice.clone_to_dynamic(p.sources[:])
	q.pedals = slice.clone_to_dynamic(p.pedals[:])
	q.tempos = slice.clone_to_dynamic(p.tempos[:])
	q.meters = slice.clone_to_dynamic(p.meters[:])
	q.moods = slice.clone_to_dynamic(p.moods[:])
	q.place = slice.clone_to_dynamic(p.place[:])
	q.time = slice.clone_to_dynamic(p.time[:])
	q.depth = slice.clone_to_dynamic(p.depth[:])
	q.worlds = slice.clone_to_dynamic(p.worlds[:])
	q.motifs = slice.clone_to_dynamic(p.motifs[:])
	return
}

// scramble_shuffle shuffles the pitches within each part; rhythm and length are kept.
scramble_shuffle :: proc(p: Piece, seed: u64) -> Piece {
	q := clone_piece(p)
	rng := base.rng_make(seed)
	for part in 0 ..< len(q.parts) {
		idx: [dynamic]int
		defer delete(idx)
		for n, i in q.notes {
			if int(n.part) == part {append(&idx, i)}
		}
		for i := len(idx) - 1; i > 0; i -= 1 {
			j := base.rng_int_max(&rng, i + 1)
			a, b := &q.notes[idx[i]], &q.notes[idx[j]]
			a.key, b.key = b.key, a.key
		}
	}
	return q
}

// common_pitch_classes is the piece's 7 commonest pitch classes, by note count.
common_pitch_classes :: proc(p: Piece) -> (in_set: [12]bool) {
	count: [12]int
	for n in p.notes {count[n.key % 12] += 1}
	// Select the top 7 by count, the lower pitch class winning a tie.
	for _ in 0 ..< 7 {
		best := -1
		for pc in 0 ..< 12 {
			if in_set[pc] {continue}
			if best < 0 || count[pc] > count[best] {best = pc}
		}
		in_set[best] = true
	}
	return
}

// scramble_in_key replaces each note by a random note of the piece's 7
// commonest pitch classes within a fifth (7 semitones) of the original.
scramble_in_key :: proc(p: Piece, seed: u64) -> Piece {
	q := clone_piece(p)
	rng := base.rng_make(seed)
	in_set := common_pitch_classes(p)
	for &n in q.notes {
		cands: [15]u8
		c := 0
		for d in -7 ..= 7 {
			k := int(n.key) + d
			if k < 0 || k > 127 || !in_set[k % 12] {continue}
			cands[c] = u8(k)
			c += 1
		}
		if c > 0 {n.key = cands[base.rng_int_max(&rng, c)]}
	}
	return q
}
