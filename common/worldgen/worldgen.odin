package worldgen

import "core:fmt"

import "common:game"

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
	Earth, // continents, biomes, rivers, mountains, caves, trees (M10)
	Classic, // M3's heightmap hills (worlds made before M10)
	Flat, // the same everywhere, for every seed (the tests' world)
}

KIND_NAMES := [Kind]string {
	.Earth   = "earth",
	.Classic = "classic",
	.Flat    = "flat",
}

Generator :: struct {
	kind:    Kind,
	seed:    i64,
	params:  Params, // (Earth)
	reg:     ^game.Registry, // what the blocks are, and the structures templates
	shipped: [Structure_Kind]i32, // the registry's structure of each kind (-1: none)
}

// generator_make: a generator with the default parameters.
generator_make :: proc(
	kind: Kind,
	seed: i64,
	reg: ^game.Registry,
	params := PARAMS_DEFAULTS,
) -> Generator {
	g := Generator{kind, seed, params, reg, {}}
	for k in Structure_Kind {
		index, found :=
			reg.ids[.Structure][fmt.tprintf("%s:%s", game.BASE_NAMESPACE, STRUCTURE_NAMES[k])]
		g.shipped[k] = i32(index) if found else -1
	}
	return g
}

kind_by_name :: proc(name: string) -> (Kind, bool) {
	for n, k in KIND_NAMES {if n == name {return k, true}}
	return {}, false
}

// generate fills dst with the chunk at c and reports whether every block is
// the same (then the caller can store just that block). Safe to call from
// any thread; cache (optional) is the calling thread's own.
generate :: proc(
	g: ^Generator,
	c: game.Chunk_Pos,
	dst: ^game.Block_Array,
	cache: ^Column_Cache = nil,
) -> (
	uniform: game.Block,
	is_uniform: bool,
) {
	switch g.kind {
	case .Earth:
		return earth_generate(g, c, dst, cache)
	case .Classic:
		return classic_generate(g.seed, c, dst)
	case .Flat:
		return flat_generate(c, dst)
	}
	return
}

COLUMN_AREA :: game.CHUNK_SIZE * game.CHUNK_SIZE

// Tops: the natural top of each block column of a chunk column, [x + z*16].
Tops :: [COLUMN_AREA]i32

// column_tops: the tops of the chunk column at column (chunk x, z).
column_tops :: proc(g: ^Generator, column: [2]i32, out: ^Tops, cache: ^Column_Cache = nil) {
	if g.kind == .Earth {
		earth_tops(g, column, out, cache)
		return
	}
	origin := column * game.CHUNK_SIZE
	for z in i32(0) ..< game.CHUNK_SIZE {
		for x in i32(0) ..< game.CHUNK_SIZE {
			out[x + z * game.CHUNK_SIZE] = column_top(g, origin.x + x, origin.y + z)
		}
	}
}

// column_top: the natural top of the block column at (x, z) (column_tops
// is cheaper per column, for a whole chunk column).
column_top :: proc(g: ^Generator, x, z: i32) -> i32 {
	switch g.kind {
	case .Earth:
		tops: Tops
		earth_tops(g, {x >> game.CHUNK_SHIFT, z >> game.CHUNK_SHIFT}, &tops)
		return tops[(x & game.CHUNK_MASK) + (z & game.CHUNK_MASK) * game.CHUNK_SIZE]
	case .Classic:
		return classic_height(g.seed, x, z)
	case .Flat:
		return FLAT_TOP
	}
	return game.WORLD_MIN_Y
}

// locate: the nearest place to (x, z) of biome b (searching rings every
// 32 blocks out to `within`), or false (or not an Earth world).
locate :: proc(
	g: ^Generator,
	b: Biome,
	x, z: i32,
	within: i32 = 4096,
) -> (
	at: [2]i32,
	found: bool,
) {
	if g.kind != .Earth {return}
	STEP :: 32
	for r in i32(0) ..= within / STEP {
		for i in i32(0) ..< max(1, 8 * r) {
			// Round the square ring of radius r, side by side.
			side, t := i / max(1, 2 * r), i % max(1, 2 * r) - r
			d: [2]i32
			switch side {
			case 0:
				d = {t, -r}
			case 1:
				d = {r, t}
			case 2:
				d = {-t, r}
			case:
				d = {-r, -t}
			}
			p := [2]i32{x, z} + d * STEP
			if earth_biome(g, p.x, p.y) == b {return p, true}
		}
	}
	return
}

biome_by_name :: proc(name: string) -> (Biome, bool) {
	for n, b in BIOME_NAMES {if n == name {return b, true}}
	return {}, false
}

// spawn_point: where new players appear (feet, just above the ground: the
// server lands them on what is really there), on open ground.
spawn_point :: proc(g: ^Generator) -> [3]f64 {
	switch g.kind {
	case .Earth:
		return earth_spawn(g)
	case .Classic:
	case .Flat:
		return {0.5, 0, 0.5}
	}
	return {0.5, f64(column_top(g, 0, 0)) + 1, 0.5}
}
