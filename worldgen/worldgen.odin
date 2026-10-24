package worldgen

import "../game"

// World generation: a pure function of (generator, chunk position). The
// same generator gives the same world on any machine and in any order, so
// chunks are generated on worker threads, and regenerated instead of saved
// unless edited. A world keeps its generator (world.cfg: generator = ...):
// worlds made before a generator existed keep the one they were made with.
//
// Besides chunks, a generator knows its natural column tops (the highest
// opaque block of each block column, where sky light stops) without
// generating the whole column, and where players first appear.

Kind :: enum u8 {
	Classic, // M3's heightmap hills (worlds made before M10)
}

KIND_NAMES := [Kind]string {
	.Classic = "classic",
}

Generator :: struct {
	kind: Kind,
	seed: i64,
}

kind_by_name :: proc(name: string) -> (Kind, bool) {
	for n, k in KIND_NAMES {if n == name {return k, true}}
	return {}, false
}

// generate fills dst with the chunk at c and reports whether every block is
// the same (then the caller can store just that block). Safe to call from
// any thread.
generate :: proc(
	g: ^Generator,
	c: game.Chunk_Pos,
	dst: ^game.Block_Array,
) -> (
	uniform: game.Block,
	is_uniform: bool,
) {
	switch g.kind {
	case .Classic:
		return classic_generate(g.seed, c, dst)
	}
	return
}

COLUMN_AREA :: game.CHUNK_SIZE * game.CHUNK_SIZE

// Tops: the natural top of each block column of a chunk column, [x + z*16].
Tops :: [COLUMN_AREA]i32

// column_tops: the tops of the chunk column at column (chunk x, z).
column_tops :: proc(g: ^Generator, column: [2]i32, out: ^Tops) {
	origin := column * game.CHUNK_SIZE
	for z in i32(0) ..< game.CHUNK_SIZE {
		for x in i32(0) ..< game.CHUNK_SIZE {
			out[x + z * game.CHUNK_SIZE] = column_top(g, origin.x + x, origin.y + z)
		}
	}
}

// column_top: the natural top of the block column at (x, z).
column_top :: proc(g: ^Generator, x, z: i32) -> i32 {
	switch g.kind {
	case .Classic:
		return classic_height(g.seed, x, z)
	}
	return game.WORLD_MIN_Y
}

// spawn_point: where new players appear (feet), above the ground.
spawn_point :: proc(g: ^Generator) -> [3]f64 {
	return {0.5, f64(column_top(g, 0, 0)) + 3, 0.5}
}
