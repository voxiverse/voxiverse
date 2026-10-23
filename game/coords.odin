package game

// World coordinates are integer block positions; chunks are 16³ cubes
// (cubic chunks: the world has no height limit). A block's chunk is its
// position floored by 16, also for negative positions (-1 is in chunk -1).

CHUNK_SIZE :: 16
CHUNK_SHIFT :: 4
CHUNK_MASK :: CHUNK_SIZE - 1
CHUNK_VOLUME :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

Block_Pos :: [3]i32
Chunk_Pos :: [3]i32

// The world is bounded vertically: blocks y in WORLD_MIN_Y ..< WORLD_MAX_Y
// (chunk layers CHUNK_MIN_Y ..< CHUNK_MAX_Y), with bedrock at the bottom.
// Below is solid, above is air; neither is stored or sent.
WORLD_MIN_Y :: -256
WORLD_MAX_Y :: 256
CHUNK_MIN_Y :: WORLD_MIN_Y / CHUNK_SIZE
CHUNK_MAX_Y :: WORLD_MAX_Y / CHUNK_SIZE

chunk_of :: #force_inline proc(p: Block_Pos) -> Chunk_Pos {
	// Arithmetic shift: floors negative positions.
	return {p.x >> CHUNK_SHIFT, p.y >> CHUNK_SHIFT, p.z >> CHUNK_SHIFT}
}

// local_of is p's position inside its chunk, each axis in 0..<16.
local_of :: #force_inline proc(p: Block_Pos) -> [3]i32 {
	return p & CHUNK_MASK
}

chunk_origin :: #force_inline proc(c: Chunk_Pos) -> Block_Pos {
	return c * CHUNK_SIZE
}

// local_index orders a chunk's blocks x fastest, then z, then y.
local_index :: #force_inline proc(l: [3]i32) -> int {
	assert(
		l.x >= 0 &&
		l.x < CHUNK_SIZE &&
		l.y >= 0 &&
		l.y < CHUNK_SIZE &&
		l.z >= 0 &&
		l.z < CHUNK_SIZE,
	)
	return int(l.x) | int(l.z) << CHUNK_SHIFT | int(l.y) << (2 * CHUNK_SHIFT)
}

local_from_index :: #force_inline proc(i: int) -> [3]i32 {
	return {i32(i & CHUNK_MASK), i32(i >> (2 * CHUNK_SHIFT)), i32(i >> CHUNK_SHIFT & CHUNK_MASK)}
}

// chunk_distance_sq is the squared distance between chunk positions, in chunks.
chunk_distance_sq :: #force_inline proc(a, b: Chunk_Pos) -> i64 {
	d := [3]i64{i64(a.x - b.x), i64(a.y - b.y), i64(a.z - b.z)}
	return d.x * d.x + d.y * d.y + d.z * d.z
}
