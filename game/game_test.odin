package game

import "core:testing"

@(test)
test_chunk_of_floors_negative :: proc(t: ^testing.T) {
	testing.expect_value(t, chunk_of({0, 15, 16}), Chunk_Pos{0, 0, 1})
	testing.expect_value(t, chunk_of({-1, -16, -17}), Chunk_Pos{-1, -1, -2})
	testing.expect_value(t, local_of({-1, -16, -17}), [3]i32{15, 0, 15})
	for p in ([]Block_Pos{{0, 0, 0}, {-1, 5, -33}, {1000, -1000, 7}}) {
		testing.expect_value(t, chunk_origin(chunk_of(p)) + local_of(p), p)
	}
}

@(test)
test_local_index_round_trips :: proc(t: ^testing.T) {
	seen: [CHUNK_VOLUME]bool
	for y in 0 ..< i32(16) {
		for z in 0 ..< i32(16) {
			for x in 0 ..< i32(16) {
				i := local_index({x, y, z})
				testing.expect(t, !seen[i])
				seen[i] = true
				testing.expect_value(t, local_from_index(i), [3]i32{x, y, z})
			}
		}
	}
}

@(test)
test_block_valid :: proc(t: ^testing.T) {
	testing.expect(t, block_valid(u16(Block.Gravel)))
	testing.expect(t, !block_valid(len(Block)))
	testing.expect(t, !block_valid(max(u16)))
	testing.expect(t, !block_solid(.Air) && block_solid(.Stone))
}

@(test)
test_chunk_set_and_compact :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	block_arrays_init(&arrays)
	defer block_arrays_destroy(&arrays)

	c := Chunk_Blocks {
		uniform = .Air,
	}
	testing.expect(t, chunk_set(&c, &arrays, {1, 2, 3}, .Air) == nil)
	testing.expect(t, c.array == nil) // same block: still uniform
	testing.expect(t, chunk_set(&c, &arrays, {1, 2, 3}, .Stone) == nil)
	testing.expect(t, c.array != nil)
	testing.expect_value(t, chunk_get(&c, {1, 2, 3}), Block.Stone)
	testing.expect_value(t, chunk_get(&c, {0, 0, 0}), Block.Air)
	chunk_compact(&c, &arrays) // mixed: stays an array
	testing.expect(t, c.array != nil)
	testing.expect(t, chunk_set(&c, &arrays, {1, 2, 3}, .Air) == nil)
	chunk_compact(&c, &arrays)
	testing.expect(t, c.array == nil && c.uniform == .Air)
	testing.expect_value(t, block_arrays_in_use(&arrays), 0)

	// Arrays are reused, not reallocated.
	for _ in 0 ..< 10 {
		testing.expect(t, chunk_set(&c, &arrays, {0, 0, 0}, .Dirt) == nil)
		chunk_release(&c, &arrays)
	}
	testing.expect_value(t, arrays.allocated, 1)
}

@(test)
test_generate_is_deterministic :: proc(t: ^testing.T) {
	a, b := new(Block_Array), new(Block_Array)
	defer free(a)
	defer free(b)
	for c in ([]Chunk_Pos{{0, 0, 0}, {-3, -1, 7}, {100, -2, -50}}) {
		generate(1234, c, a)
		generate(1234, c, b)
		testing.expect(t, a^ == b^)
	}
	// Another seed gives another world.
	differs := false
	for x in i32(0) ..< 8 {
		if column_height(1, x * 37, 0) != column_height(2, x * 37, 0) {differs = true}
	}
	testing.expect(t, differs)
}

@(test)
test_generate_terrain_shape :: proc(t: ^testing.T) {
	SEED :: 42
	arr := new(Block_Array)
	defer free(arr)

	// Above every column: one uniform air chunk.
	uniform, ok := generate(SEED, {0, 50, 0}, arr)
	testing.expect(t, ok && uniform == .Air)

	// Each column's top block (where it falls in this chunk) is ground and
	// the block above it is air.
	for cx in i32(-2) ..< 2 {
		for cz in i32(-2) ..< 2 {
			h := column_height(SEED, cx * 16, cz * 16)
			c := chunk_of({cx * 16, h, cz * 16})
			generate(SEED, c, arr)
			top := arr[local_index(local_of({cx * 16, h, cz * 16}))]
			testing.expect(
				t,
				top == .Grass || top == .Sand || top == .Gravel,
				"column top is ground",
			)
			above := Block_Pos{cx * 16, h + 1, cz * 16}
			if chunk_of(above) == c {
				testing.expect_value(t, arr[local_index(local_of(above))], Block.Air)
			}
		}
	}

	// Deep underground there are caves: some air, mostly stone.
	air := 0
	for cx in i32(0) ..< 4 {
		_, _ = generate(SEED, {cx, -6, 0}, arr)
		for b in arr {if b == .Air {air += 1}}
	}
	testing.expect(t, air > 0 && air < 4 * CHUNK_VOLUME / 4, "caves carve some but not most stone")
}
