package game

import "core:mem"
import "core:testing"

@(private = "file")
Allocator_Error :: mem.Allocator_Error

@(test)
test_world_bounds :: proc(t: ^testing.T) {
	testing.expect(t, in_world({0, CHUNK_MIN_Y, 0}) && in_world({0, CHUNK_MAX_Y - 1, 0}))
	testing.expect(t, !in_world({0, CHUNK_MIN_Y - 1, 0}) && !in_world({0, CHUNK_MAX_Y, 0}))
	testing.expect(t, !in_world({CHUNK_LIMIT, 0, 0}))
	// Near the top, part of the area is outside the world.
	full := interest_count(4, 2)
	testing.expect_value(t, interest_count_at({0, 0, 0}, 4, 2), full)
	testing.expect_value(t, interest_count_at({0, CHUNK_MAX_Y - 1, 0}, 4, 2), full * 3 / 5)
}

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
	testing.expect(t, !block_collides(.Air) && block_collides(.Stone) && !block_opaque(.Air))
}

@(test)
test_chunk_set_and_compact :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	testing.expect(t, block_arrays_init(&arrays, 16) == nil)
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

// test_terrain fills dst with something like terrain (stone, dirt, grass,
// air, pockets) for tests that need realistic chunks.
@(private)
test_terrain :: proc(seed: i64, dst: ^Block_Array) {
	for &b, i in dst {
		l := local_from_index(i)
		h := 8 + (l.x * 7 + l.z * 3 + i32(seed)) % 5
		switch {
		case l.y > h:
			b = .Air
		case l.y == h:
			b = .Grass
		case l.y > h - 3:
			b = .Dirt
		case (l.x * 13 + l.y * 7 + l.z * 5 + i32(seed)) % 41 == 0:
			b = .Air // a pocket
		case:
			b = .Stone
		}
	}
}

@(test)
test_block_arrays_capacity :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	testing.expect(t, block_arrays_init(&arrays, 100) == nil)
	defer block_arrays_destroy(&arrays)
	taken: [100]^Block_Array
	for &p in taken {
		err: Allocator_Error
		p, err = block_arrays_take(&arrays)
		testing.expect(t, err == nil)
		p[CHUNK_VOLUME - 1] = .Stone // committed: writable to the end
	}
	_, err := block_arrays_take(&arrays)
	testing.expect_value(t, err, Allocator_Error.Out_Of_Memory)
	block_arrays_give(&arrays, taken[42])
	p, err2 := block_arrays_take(&arrays)
	testing.expect(t, err2 == nil && p == taken[42])
	testing.expect_value(t, block_arrays_in_use(&arrays), 100)
}
