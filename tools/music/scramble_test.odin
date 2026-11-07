package music_tool

import "core:fmt"
import "core:testing"

CORPUS :: [?]struct {
	name: string,
	data: string,
} {
	{"bach-bwv269.mid", #load("testdata/corpus/bach-bwv269.mid", string)},
	{"bach-bwv691.mid", #load("testdata/corpus/bach-bwv691.mid", string)},
	{"satie-gymnopedie1.mid", #load("testdata/corpus/satie-gymnopedie1.mid", string)},
	{"folk-greensleeves.mid", #load("testdata/corpus/folk-greensleeves.mid", string)},
	{"chopin-op28-4.mid", #load("testdata/corpus/chopin-op28-4.mid", string)},
	{"chopin-op28-7.mid", #load("testdata/corpus/chopin-op28-7.mid", string)},
}

@(private = "file")
load_corpus :: proc(t: ^testing.T) -> (pieces: [dynamic]Piece) {
	for f in CORPUS {
		p, err, ok := midi_read(transmute([]u8)f.data)
		testing.expectf(t, ok, "%s: %s", f.name, err)
		testing.expectf(t, len(p.notes) > 20, "%s: only %d notes", f.name, len(p.notes))
		if ok {append(&pieces, p)}
	}
	return
}

// same_rhythm: note count, and per note its part, onset and duration.
@(private = "file")
same_rhythm :: proc(a, b: Piece) -> bool {
	if len(a.notes) != len(b.notes) {return false}
	for n, i in a.notes {
		m := b.notes[i]
		if n.part != m.part || n.start != m.start || n.length != m.length {return false}
	}
	return true
}

@(private = "file")
same_keys :: proc(a, b: Piece) -> bool {
	for n, i in a.notes {
		if n.key != b.notes[i].key {return false}
	}
	return true
}

@(test)
test_corpus_parses :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	load_corpus(t)
}

@(test)
test_scramble_shuffle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for p, i in load_corpus(t) {
		a := scramble_shuffle(p, 1)
		a2 := scramble_shuffle(p, 1)
		b := scramble_shuffle(p, 2)
		testing.expect(t, same_rhythm(p, a), fmt.tprintf("piece %d: rhythm changed", i))
		testing.expect(t, same_keys(a, a2), fmt.tprintf("piece %d: not deterministic", i))
		testing.expect(t, !same_keys(a, b), fmt.tprintf("piece %d: seeds agree", i))
		testing.expect(t, !same_keys(p, a), fmt.tprintf("piece %d: unchanged", i))
		// Pitches are only moved within a part.
		for part in 0 ..< len(p.parts) {
			var_before, var_after: [128]int
			for n in p.notes {if int(n.part) == part {var_before[n.key] += 1}}
			for n in a.notes {if int(n.part) == part {var_after[n.key] += 1}}
			testing.expect(
				t,
				var_before == var_after,
				fmt.tprintf("piece %d part %d: pitches changed", i, part),
			)
		}
	}
}

@(test)
test_scramble_in_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for p, i in load_corpus(t) {
		a := scramble_in_key(p, 1)
		a2 := scramble_in_key(p, 1)
		b := scramble_in_key(p, 2)
		testing.expect(t, same_rhythm(p, a), fmt.tprintf("piece %d: rhythm changed", i))
		testing.expect(t, same_keys(a, a2), fmt.tprintf("piece %d: not deterministic", i))
		testing.expect(t, !same_keys(a, b), fmt.tprintf("piece %d: seeds agree", i))
		testing.expect(t, !same_keys(p, a), fmt.tprintf("piece %d: unchanged", i))
		// The 7 commonest pitch classes, counted on the original.
		count: [12]int
		for n in p.notes {count[n.key % 12] += 1}
		for n, j in a.notes {
			o := p.notes[j].key
			d := int(n.key) - int(o)
			testing.expect(t, abs(d) <= 7, fmt.tprintf("piece %d note %d: moved %d", i, j, d))
			// pitch class rank: fewer than 7 classes have a higher count (ties go to the lower class)
			better := 0
			pc := int(n.key % 12)
			for c in 0 ..< 12 {
				if count[c] > count[pc] || (count[c] == count[pc] && c < pc) {better += 1}
			}
			testing.expect(
				t,
				better < 7,
				fmt.tprintf("piece %d note %d: pitch class %d out of key", i, j, pc),
			)
		}
	}
}
