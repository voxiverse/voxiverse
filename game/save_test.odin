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
	generate(4, {-3, 0, 40}, terrain.array)
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
	testing.expect(t, ok && pos == chunks[0].pos && !is_uniform && scratch^ == terrain.array^)
	pos, uniform, is_uniform, ok = region_next_chunk(&r, scratch)
	testing.expect(t, ok && pos == chunks[1].pos && is_uniform && uniform == .Air)
	_, _, _, ok = region_next_chunk(&r, scratch)
	testing.expect(t, !ok && r.reader.ok) // the end, not damage
	got := make([dynamic]Saved_Top, context.temp_allocator)
	testing.expect(t, region_tops(&r, &got))
	testing.expect(t, len(got) == 2 && got[0] == tops[0] && got[1] == tops[1])
	chunk_release(&terrain, &arrays)

	// Damage anywhere is caught by the checksum; a cut file too.
	for i in ([]int{0, 5, 20, len(data) / 2, len(data) - 1}) {
		broken := make([]u8, len(data), context.temp_allocator)
		copy(broken, data)
		broken[i] ~= 0x40
		_, e := region_open(broken, region)
		testing.expectf(t, e != .None, "byte %d flipped: accepted", i)
	}
	_, e := region_open(data[:len(data) - 3], region)
	testing.expect(t, e != .None)
	_, e = region_open(data, {0, 0})
	testing.expect_value(t, e, Region_Error.Wrong_Region)
	_, e = region_open(transmute([]u8)string("hello"), region)
	testing.expect_value(t, e, Region_Error.Not_A_Region)
}
