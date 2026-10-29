package worldgen

import "../game"

// The flat generator (T2): the same at every (x, z) and for every seed, so a
// test's world does not move when terrain code changes. From the top: air,
// grass at y -1, three layers of dirt, stone, and a bedrock floor at
// WORLD_MIN_Y. Most of its chunks are uniform.

FLAT_TOP :: -1

// flat_block is the block at height y.
flat_block :: proc(y: i32) -> game.Block {
	switch {
	case y > FLAT_TOP:
		return .Air
	case y == FLAT_TOP:
		return .Grass
	case y >= FLAT_TOP - 3:
		return .Dirt
	case y > game.WORLD_MIN_Y:
		return .Stone
	}
	return .Bedrock
}

flat_generate :: proc(
	c: game.Chunk_Pos,
	dst: ^game.Block_Array,
) -> (
	uniform: game.Block,
	is_uniform: bool,
) {
	origin := game.chunk_origin(c)
	first := flat_block(origin.y)
	same := true
	for y in origin.y ..< origin.y + game.CHUNK_SIZE {
		if flat_block(y) != first {same = false; break}
	}
	if same {
		for &b in dst {b = first}
		return first, true
	}
	for i in 0 ..< game.CHUNK_VOLUME {
		l := game.local_from_index(i)
		dst[i] = flat_block(origin.y + l.y)
	}
	return {}, false
}
