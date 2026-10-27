package game

import "core:testing"

@(test)
test_region_round_trip :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	testing.expect(t, block_arrays_init(&arrays, 8) == nil)
	defer block_arrays_destroy(&arrays)

	// Region (-1, 2): chunk columns x -16..-1, z 32..47.
	region := Region_Pos{-1, 2}
	terrain := Chunk_Blocks{}
	terrain.array, _ = block_arrays_take(&arrays)
	test_terrain(4, terrain.array)
	terrain.array[17] = .Lamp
	air := Chunk_Blocks {
		uniform = .Air,
	}
	chunks := []Saved_Chunk{{{-3, 0, 40}, &terrain}, {{-16, CHUNK_MIN_Y, 47}, &air}}
	tops := []Saved_Top{{-40, 600, 12}, {-1, 512, WORLD_MIN_Y}}
	testing.expect_value(t, region_of({-16, 0, 47}), region)

	w: Writer
	writer_init(&w, context.temp_allocator)
	region_encode(&w, region, chunks, tops)
	data := w.buf[:]

	r, err := region_open(data, region)
	testing.expect_value(t, err, Region_Error.None)
	scratch := new(Block_Array)
	defer free(scratch)
	pos, uniform, is_uniform, ok := region_next_chunk(&r, scratch)
	testing.expect(t, ok && pos == chunks[1].pos && is_uniform && uniform == .Air) // (sorted)
	pos, uniform, is_uniform, ok = region_next_chunk(&r, scratch)
	testing.expect(t, ok && pos == chunks[0].pos && !is_uniform && scratch^ == terrain.array^)
	_, _, _, ok = region_next_chunk(&r, scratch)
	testing.expect(t, !ok && r.reader.ok) // the end, not damage
	got := make([dynamic]Saved_Top, context.temp_allocator)
	testing.expect(t, region_tops(&r, &got))
	testing.expect(t, len(got) == 2 && got[0] == tops[0] && got[1] == tops[1])
	chunk_release(&terrain, &arrays)

	// Damage in the header is caught by its checksum (the whole file is lost).
	header_end := len(data) - len(r.payloads)
	for i in ([]int{0, 5, 20, header_end / 2, header_end - 1}) {
		broken := make([]u8, len(data), context.temp_allocator)
		copy(broken, data)
		broken[i] ~= 0x40
		_, e := region_open(broken, region)
		testing.expectf(t, e != .None, "header byte %d flipped: accepted", i)
	}
	// Damage in a payload loses that chunk only; so does a file cut short.
	broken := make([]u8, len(data), context.temp_allocator)
	copy(broken, data)
	broken[header_end + 2] ~= 0x40 // (the first in the index's order)
	r2, e2 := region_open(broken, region)
	testing.expect_value(t, e2, Region_Error.None)
	first, second := r2.index[0].pos, r2.index[1].pos
	pos, _, _, ok = region_next_chunk(&r2, scratch)
	testing.expect(t, ok && pos == second)
	testing.expect(t, len(r2.dropped) == 1 && r2.dropped[0] == first)
	r3, _ := region_open(data[:len(data) - 1], region)
	_, _, _, ok = region_next_chunk(&r3, scratch)
	testing.expect(t, ok) // (the first chunk is whole)
	_, _, _, ok = region_next_chunk(&r3, scratch)
	testing.expect(t, !ok && len(r3.dropped) == 1) // (the cut one is dropped)
	_, e := region_open(data, {0, 0})
	testing.expect_value(t, e, Region_Error.Wrong_Region)
	_, e = region_open(transmute([]u8)string("hello"), region)
	testing.expect_value(t, e, Region_Error.Not_A_Region)
}

// Format 1 is read by region_open_v1 (the migration's reader); the current
// reader says it is older.
@(test)
test_region_v1_still_reads :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	testing.expect(t, block_arrays_init(&arrays, 8) == nil)
	defer block_arrays_destroy(&arrays)
	region := Region_Pos{0, 0}
	terrain := Chunk_Blocks{}
	terrain.array, _ = block_arrays_take(&arrays)
	test_terrain(9, terrain.array)
	chunks := []Saved_Chunk{{{1, 0, 2}, &terrain}}
	tops := []Saved_Top{{20, 40, 7}}
	w: Writer
	writer_init(&w, context.temp_allocator)
	region_encode_v1(&w, region, chunks, tops)
	_, err := region_open(w.buf[:], region)
	testing.expect_value(t, err, Region_Error.Older_Format)
	r, err1 := region_open_v1(w.buf[:], region)
	testing.expect_value(t, err1, Region_Error.None)
	scratch := new(Block_Array)
	defer free(scratch)
	pos, _, is_uniform, ok := region_next_chunk_v1(&r, scratch)
	testing.expect(t, ok && pos == chunks[0].pos && !is_uniform && scratch^ == terrain.array^)
	got := make([dynamic]Saved_Top, context.temp_allocator)
	testing.expect(t, region_tops_v1(&r, &got) && len(got) == 1 && got[0] == tops[0])
	chunk_release(&terrain, &arrays)
}
