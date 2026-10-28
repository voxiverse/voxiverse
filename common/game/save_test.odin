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
	held := Block_Entity {
		local = 17,
		kind  = .Container,
	}
	held.slots[0] = {item_of_material(.Seeds), 3}
	held.slots[24] = {item_of_material(.Seeds), 1}
	chunks := []Saved_Chunk{{{-3, 0, 40}, &terrain, {held}}, {{-16, CHUNK_MIN_Y, 47}, &air, nil}}
	tops := []Saved_Top{{-40, 600, 12}, {-1, 512, WORLD_MIN_Y}}
	testing.expect_value(t, region_of({-16, 0, 47}), region)

	w: Writer
	writer_init(&w, context.temp_allocator)
	region_encode(test_reg(), &w, region, chunks, tops)
	data := w.buf[:]

	r, err := region_open(test_reg(), data, region)
	testing.expect_value(t, err, Region_Error.None)
	scratch := new(Block_Array)
	defer free(scratch)
	ents := make([dynamic]Block_Entity, context.temp_allocator)
	pos, uniform, is_uniform, ok := region_next_chunk(&r, scratch, &ents)
	testing.expect(t, ok && pos == chunks[1].pos && is_uniform && uniform == .Air) // (sorted)
	pos, uniform, is_uniform, ok = region_next_chunk(&r, scratch, &ents)
	testing.expect(t, ok && pos == chunks[0].pos && !is_uniform && scratch^ == terrain.array^)
	testing.expect(
		t,
		len(ents) == 1 && ents[0] == held,
		"the container did not come back as saved",
	)
	_, _, _, ok = region_next_chunk(&r, scratch, &ents)
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
		_, e := region_open(test_reg(), broken, region)
		testing.expectf(t, e != .None, "header byte %d flipped: accepted", i)
	}
	// Damage in a payload loses that chunk only; so does a file cut short.
	broken := make([]u8, len(data), context.temp_allocator)
	copy(broken, data)
	broken[header_end + 2] ~= 0x40 // (the first in the index's order)
	r2, e2 := region_open(test_reg(), broken, region)
	testing.expect_value(t, e2, Region_Error.None)
	first, second := r2.index[0].pos, r2.index[1].pos
	pos, _, _, ok = region_next_chunk(&r2, scratch, &ents)
	testing.expect(t, ok && pos == second)
	testing.expect(t, len(r2.dropped) == 1 && r2.dropped[0] == first)
	r3, _ := region_open(test_reg(), data[:len(data) - 1], region)
	_, _, _, ok = region_next_chunk(&r3, scratch, &ents)
	testing.expect(t, ok) // (the first chunk is whole)
	_, _, _, ok = region_next_chunk(&r3, scratch, &ents)
	testing.expect(t, !ok && len(r3.dropped) == 1) // (the cut one is dropped)
	_, e := region_open(test_reg(), data, {0, 0})
	testing.expect_value(t, e, Region_Error.Wrong_Region)
	_, e = region_open(test_reg(), transmute([]u8)string("hello"), region)
	testing.expect_value(t, e, Region_Error.Not_A_Region)
}

// The file names its blocks: a registry with other numbers (or without a
// pack's blocks) still reads it.
@(test)
test_region_names_round_trip :: proc(t: ^testing.T) {
	with_pack, errs := build_with(pack_of("testpack", TEST_PACK))
	testing.expect_value(t, len(errs), 0)
	if with_pack == nil {return}
	marble, _ := registry_block(with_pack, "testpack:marble")
	testing.expect_value(t, int(marble), BASE_STATES)

	arrays: Block_Arrays
	testing.expect(t, block_arrays_init(&arrays, 2) == nil)
	defer block_arrays_destroy(&arrays)
	chunk := Chunk_Blocks{}
	chunk.array, _ = block_arrays_take(&arrays)
	test_terrain(3, chunk.array)
	chunk.array[5] = marble
	solid := Chunk_Blocks {
		uniform = marble,
	}
	region := Region_Pos{0, 0}
	chunks := []Saved_Chunk{{{1, 0, 2}, &chunk, nil}, {{2, 0, 2}, &solid, nil}}
	w: Writer
	writer_init(&w, context.temp_allocator)
	region_encode(with_pack, &w, region, chunks, nil)

	scratch := new(Block_Array)
	defer free(scratch)
	ents := make([dynamic]Block_Entity, context.temp_allocator)
	// The same registry: every block comes back as it was, pack block included.
	r, err := region_open(with_pack, w.buf[:], region)
	testing.expect_value(t, err, Region_Error.None)
	pos, _, is_uniform, ok := region_next_chunk(&r, scratch, &ents)
	uniform: Block
	testing.expect(t, ok && pos == chunks[0].pos && !is_uniform && scratch^ == chunk.array^)
	testing.expect_value(t, scratch[5], marble)
	_, uniform, is_uniform, ok = region_next_chunk(&r, scratch, &ents)
	testing.expect(t, ok && is_uniform && uniform == marble)

	// A registry that lacks the pack: refused, naming the block...
	base := test_reg()
	_, err = region_open(base, w.buf[:], region)
	testing.expect_value(t, err, Region_Error.Unknown_Blocks)
	r, err = region_open(base, w.buf[:], region)
	testing.expect_value(t, len(r.unknown), 1)
	testing.expect_value(t, r.unknown[0], "testpack:marble")
	// ...or reading it as air.
	r, err = region_open(base, w.buf[:], region, unknown_air = true)
	testing.expect_value(t, err, Region_Error.None)
	_, _, is_uniform, ok = region_next_chunk(&r, scratch, &ents)
	testing.expect(t, ok && !is_uniform && scratch[5] == .Air)
	_, uniform, is_uniform, ok = region_next_chunk(&r, scratch, &ents)
	testing.expect(t, ok && is_uniform && uniform == .Air)

	// Numbers that moved: a pack ahead of the first makes marble another number.
	moved, errs2 := build_with(
		pack_of(
			"apack",
			{{"data/blocks/slate.json", `{"slate": {"textures": {"all": "voxiverse:stone"}}}`}},
		),
		pack_of("testpack", TEST_PACK),
	)
	testing.expect_value(t, len(errs2), 0)
	if moved == nil {return}
	marble2, _ := registry_block(moved, "testpack:marble")
	testing.expect(t, marble2 != marble)
	r, err = region_open(moved, w.buf[:], region)
	testing.expect_value(t, err, Region_Error.None)
	_, _, is_uniform, ok = region_next_chunk(&r, scratch, &ents)
	testing.expect(t, ok && !is_uniform && scratch[5] == marble2)
	chunk_release(&chunk, &arrays)
}
