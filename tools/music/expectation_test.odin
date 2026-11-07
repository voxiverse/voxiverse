package music_tool

import "core:slice"
import "core:testing"

@(private = "file")
corpus_pieces :: proc(t: ^testing.T) -> (pieces: [dynamic]Piece, names: [dynamic]string) {
	for f in CORPUS {
		p, err, ok := midi_read(transmute([]u8)f.data)
		testing.expectf(t, ok, "%s: %s", f.name, err)
		if ok {
			append(&pieces, p)
			append(&names, f.name[:len(f.name) - len(".mid")])
		}
	}
	return
}

@(private = "file")
melody_of :: proc(p: ^Piece) -> []Mel {
	return melody_line(p, melody_part(p))
}

@(test)
test_expectation_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pieces, names := corpus_pieces(t)
	m := expectation_train(pieces[:])
	m.names = names
	bytes := expectation_write(&m)
	back, ok := expectation_read(bytes)
	testing.expect(t, ok, "the file reads back")
	testing.expect(
		t,
		slice.equal(expectation_write(&back), bytes),
		"the bytes survive a round trip",
	)
	testing.expect_value(t, len(back.ctx), len(m.ctx))
	testing.expect(t, expectation_has(&back, "bach-bwv269"))
	for i in 0 ..< len(pieces) {
		a := expectation_bits(&m, melody_of(&pieces[i]), true)
		b := expectation_bits(&back, melody_of(&pieces[i]), true)
		testing.expect_value(t, a, b)
	}
	_, bad := expectation_read(bytes[:len(bytes) - 1])
	testing.expect(t, !bad, "a short file is refused")
	bytes[4] = 9
	_, bad = expectation_read(bytes)
	testing.expect(t, !bad, "another version is refused")
}

@(test)
test_expectation_is_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pieces, _ := corpus_pieces(t)
	a := expectation_train(pieces[:])
	b := expectation_train(pieces[:])
	testing.expect(t, slice.equal(expectation_write(&a), expectation_write(&b)))
}

@(test)
test_expectation_master_beats_scramble :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pieces, names := corpus_pieces(t)
	m := expectation_train(pieces[:])
	for &p, i in pieces {
		master := expectation_bits(&m, melody_of(&p), true)
		q := scramble_in_key(p, 1)
		scrambled := expectation_bits(&m, melody_of(&q), false)
		testing.expectf(
			t,
			master < scrambled,
			"%s: master %v bits, scrambled %v",
			names[i],
			master,
			scrambled,
		)
	}
}
