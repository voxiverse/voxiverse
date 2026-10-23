package game

import "core:math"
import "core:math/noise"

// Worldgen is a pure function of (seed, chunk position): the same seed gives
// the same world on any machine and in any generation order, so chunks can be
// generated on worker threads and regenerated instead of saved.
//
// Terrain: a heightmap from two noise layers (broad continents, local hills),
// grass over dirt over stone, sand and gravel in the lowlands, and tunnels
// where two 3D noise fields are both near zero ("spaghetti" caves). The cave
// noise is sampled every 4 blocks on a world-aligned grid and interpolated,
// which is 30x cheaper than per block and matches across chunk borders.

SEA_LEVEL :: 0

@(private = "file")
CAVE_STEP :: 4
@(private = "file")
CAVE_SAMPLES :: CHUNK_SIZE / CAVE_STEP + 1

// Per-layer seeds, so layers are uncorrelated.
@(private = "file")
Layer :: enum i64 {
	Continent = 0x1f3a,
	Hills     = 0x7c41,
	Cave_A    = 0x2d95,
	Cave_B    = 0x5be7,
	Lowland   = 0x6a03,
}

// column_height is the y of the topmost terrain block at (x, z).
column_height :: proc(seed: i64, x, z: i32) -> i32 {
	p := [2]f64{f64(x), f64(z)}
	continent := fbm2(seed ~ i64(Layer.Continent), p / 600, 4)
	hills := fbm2(seed ~ i64(Layer.Hills), p / 90, 4)
	mountainous := math.smoothstep(-0.1, 0.6, continent)
	h := 4 + continent * 28 + hills * (4 + 26 * mountainous)
	return i32(math.floor(h))
}

// generate fills dst with the chunk at c and reports whether every block is
// the same (then the caller can store just that block).
generate :: proc(
	seed: i64,
	c: Chunk_Pos,
	dst: ^Block_Array,
) -> (
	uniform: Block,
	is_uniform: bool,
) {
	origin := chunk_origin(c)
	heights: [CHUNK_SIZE][CHUNK_SIZE]i32 // [z][x]
	highest := min(i32)
	for z in 0 ..< i32(CHUNK_SIZE) {
		for x in 0 ..< i32(CHUNK_SIZE) {
			h := column_height(seed, origin.x + x, origin.z + z)
			heights[z][x] = h
			highest = max(highest, h)
		}
	}
	// Entirely above the terrain: skip the cave noise.
	if origin.y > highest {
		for &b in dst {b = .Air}
		return .Air, true
	}

	// Caves are carved only 4+ blocks below the surface (1 KB of samples).
	caves: Cave_Grid
	has_caves := origin.y < highest - 3
	if has_caves {cave_samples(seed, origin, &caves)}
	for i in 0 ..< CHUNK_VOLUME {
		l := local_from_index(i)
		y := origin.y + l.y
		h := heights[l.z][l.x]
		b := surface_block(seed, origin.x + l.x, origin.z + l.z, y, h)
		if b != .Air && y < h - 3 && has_caves && in_cave(&caves, l) {b = .Air}
		dst[i] = b
	}
	first := dst[0]
	for b in dst {if b != first {return {}, false}}
	return first, true
}

// surface_block is the block at height y in a column whose top is h, before
// caves are carved.
@(private = "file")
surface_block :: proc(seed: i64, x, z, y, h: i32) -> Block {
	if y > h {return .Air}
	depth := h - y // 0 at the surface
	if h <= SEA_LEVEL + 2 {
		// Lowlands: sand, with gravel patches.
		if depth < 4 {
			patch := noise.noise_2d(seed ~ i64(Layer.Lowland), {f64(x) / 24, f64(z) / 24})
			return .Gravel if patch > 0.35 else .Sand
		}
		return .Stone
	}
	switch {
	case depth == 0:
		return .Grass
	case depth < 4:
		return .Dirt
	}
	return .Stone
}

@(private = "file")
Cave_Grid :: [CAVE_SAMPLES][CAVE_SAMPLES][CAVE_SAMPLES][2]f32 // [y][z][x]

// cave_samples evaluates both cave fields on the chunk's grid.
@(private = "file")
cave_samples :: proc(seed: i64, origin: Block_Pos, grid: ^Cave_Grid) {
	for y in 0 ..< CAVE_SAMPLES {
		for z in 0 ..< CAVE_SAMPLES {
			for x in 0 ..< CAVE_SAMPLES {
				p := [3]f64 {
					f64(origin.x + i32(x * CAVE_STEP)),
					f64(origin.y + i32(y * CAVE_STEP)),
					f64(origin.z + i32(z * CAVE_STEP)),
				}
				// Squashed vertically: tunnels run more sideways than up.
				q := p / [3]f64{48, 28, 48}
				grid[y][z][x] = {
					noise.noise_3d_improve_xz(seed ~ i64(Layer.Cave_A), q),
					noise.noise_3d_improve_xz(seed ~ i64(Layer.Cave_B), q),
				}
			}
		}
	}
}

@(private = "file")
in_cave :: proc(g: ^Cave_Grid, l: [3]i32) -> bool {
	cell := l / CAVE_STEP
	f := [3]f32{f32(l.x % CAVE_STEP), f32(l.y % CAVE_STEP), f32(l.z % CAVE_STEP)} / CAVE_STEP
	v: [2]f32
	for corner in 0 ..< 8 {
		o := [3]i32{i32(corner & 1), i32(corner >> 1 & 1), i32(corner >> 2 & 1)}
		w := (o.x == 1 ? f.x : 1 - f.x) * (o.y == 1 ? f.y : 1 - f.y) * (o.z == 1 ? f.z : 1 - f.z)
		s := cell + o
		v += w * g[s.y][s.z][s.x]
	}
	TUNNEL_WIDTH :: 0.09
	return abs(v[0]) < TUNNEL_WIDTH && abs(v[1]) < TUNNEL_WIDTH
}

// fbm2 sums octaves of 2D simplex noise; the result is roughly in -1..1.
@(private = "file")
fbm2 :: proc(seed: i64, p: [2]f64, octaves: int) -> f64 {
	sum, amplitude, total := 0.0, 1.0, 0.0
	q := p
	for o in 0 ..< octaves {
		sum += amplitude * f64(noise.noise_2d(seed + i64(o), q))
		total += amplitude
		amplitude *= 0.5
		q *= 2
	}
	return sum / total
}
