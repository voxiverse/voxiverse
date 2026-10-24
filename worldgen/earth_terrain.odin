package worldgen

import "core:math"
import "core:math/noise"

import "../base"
import "../game"

// Overhang noise lives on a world-aligned grid (every 4 blocks across,
// every 8 up) and is interpolated between: cheap, and the same at a block
// whichever chunk or column scan asks for it.
@(private = "file")
GRID_XZ :: 4
@(private = "file")
GRID_Y :: 8
@(private = "file")
GRID_N :: game.CHUNK_SIZE / GRID_XZ + 1
@(private = "file")
MAX_LEVELS :: (game.WORLD_MAX_Y - game.WORLD_MIN_Y) / GRID_Y + 2

// Overhang_Grid: overhang noise over a chunk column, levels from y0 up.
@(private = "file")
Overhang_Grid :: struct {
	y0:     i32,
	levels: int,
	values: [MAX_LEVELS][GRID_N][GRID_N]f32, // [level][z][x]
}

// MARGIN: blocks above a chunk looked at to know how deep under open air
// its blocks are (the deepest surface rule is this deep).
@(private = "file")
MARGIN :: 8

@(private = "file")
Columns :: [game.CHUNK_SIZE][game.CHUNK_SIZE]Column // [z][x]

@(private = "file")
columns_fill :: proc(p: ^Params, seed: i64, column: [2]i32, cols: ^Columns) {
	origin := column * game.CHUNK_SIZE
	for z in i32(0) ..< game.CHUNK_SIZE {
		for x in i32(0) ..< game.CHUNK_SIZE {
			cols[z][x] = column_at(p, seed, origin.x + x, origin.y + z)
		}
	}
}

// grid_fill samples the overhang noise of a chunk column for y lo..hi.
@(private = "file")
grid_fill :: proc(seed: i64, column: [2]i32, lo, hi: i32, g: ^Overhang_Grid) {
	g.y0 = floor_div(max(lo, game.WORLD_MIN_Y), GRID_Y) * GRID_Y
	top := min(hi, game.WORLD_MAX_Y)
	g.levels = min(int((top - g.y0) / GRID_Y) + 2, MAX_LEVELS)
	origin := column * game.CHUNK_SIZE
	for l in 0 ..< g.levels {
		for z in 0 ..< GRID_N {
			for x in 0 ..< GRID_N {
				q := [3]f64 {
					f64(origin.x + i32(x * GRID_XZ)),
					f64(g.y0 + i32(l * GRID_Y)),
					f64(origin.y + i32(z * GRID_XZ)),
				}
				a := noise.noise_3d_improve_xz(
					seed ~ i64(Earth_Layer.Overhang),
					q / [3]f64{26, 18, 26},
				)
				b := noise.noise_3d_improve_xz(
					seed ~ i64(Earth_Layer.Overhang) + 1,
					q / [3]f64{13, 9, 13},
				)
				g.values[l][z][x] = (a * 2 + b) / 3
			}
		}
	}
}

// grid_at: the overhang noise at chunk-column-local (x, z) and world y.
@(private = "file")
grid_at :: proc(g: ^Overhang_Grid, x, y, z: i32) -> f32 {
	ly := y - g.y0
	l := int(ly / GRID_Y)
	cx, cz := int(x / GRID_XZ), int(z / GRID_XZ)
	fx := f32(x % GRID_XZ) / GRID_XZ
	fy := f32(ly % GRID_Y) / GRID_Y
	fz := f32(z % GRID_XZ) / GRID_XZ
	v := &g.values
	a := mix(
		mix(v[l][cz][cx], v[l][cz][cx + 1], fx),
		mix(v[l][cz + 1][cx], v[l][cz + 1][cx + 1], fx),
		fz,
	)
	b := mix(
		mix(v[l + 1][cz][cx], v[l + 1][cz][cx + 1], fx),
		mix(v[l + 1][cz + 1][cx], v[l + 1][cz + 1][cx + 1], fx),
		fz,
	)
	return mix(a, b, fy)
}

// solid: the land fills (x, y, z) (chunk-column-local x, z).
@(private = "file")
solid :: #force_inline proc(c: ^Column, g: ^Overhang_Grid, x, y, z: i32) -> bool {
	d := c.height - f32(y)
	if c.rough > 0 {d += c.rough * grid_at(g, x, y, z)}
	return d >= 0
}

// terrain_top: the highest solid block of a column (before caves, which
// never reach the top, and features).
@(private = "file")
terrain_top :: proc(c: ^Column, g: ^Overhang_Grid, x, z: i32) -> i32 {
	plain := i32(math.floor(c.height))
	if c.rough == 0 {return plain}
	for y := i32(math.floor(c.height + c.rough)); y > plain - i32(c.rough) - 1; y -= 1 {
		if solid(c, g, x, y, z) {return y}
	}
	return i32(math.floor(c.height - c.rough))
}

// earth_tops: the natural tops of a chunk column: the land, the ice on a
// frozen sea, the trunks and cacti standing on it.
earth_tops :: proc(gen: ^Generator, column: [2]i32, out: ^Tops) {
	p := &gen.params
	cols := new(Columns, context.temp_allocator)
	columns_fill(p, gen.seed, column, cols)
	grid := new(Overhang_Grid, context.temp_allocator)
	lo, hi := max(i32), min(i32)
	for &row in cols {
		for &c in row {
			if c.rough == 0 {continue}
			lo = min(lo, i32(math.floor(c.height - c.rough)) - 1)
			hi = max(hi, i32(math.floor(c.height + c.rough)) + 1)
		}
	}
	if lo <= hi {grid_fill(gen.seed, column, lo, hi, grid)}
	for z in i32(0) ..< game.CHUNK_SIZE {
		for x in i32(0) ..< game.CHUNK_SIZE {
			c := &cols[z][x]
			top := terrain_top(c, grid, x, z)
			if top < p.sea_level && frozen(c.biome) {top = p.sea_level}
			out[x + z * game.CHUNK_SIZE] = top
		}
	}
	trees := make([dynamic]Tree, context.temp_allocator)
	place_trees(gen, column, &trees)
	origin := column * game.CHUNK_SIZE
	for t in trees {
		i := (t.ground.x - origin.x) + (t.ground.z - origin.y) * game.CHUNK_SIZE
		out[i] = max(out[i], t.ground.y + t.height) // its trunk (leaves let light through)
	}
}

// earth_generate fills dst with the chunk at c.
earth_generate :: proc(
	gen: ^Generator,
	c: game.Chunk_Pos,
	dst: ^game.Block_Array,
) -> (
	uniform: game.Block,
	is_uniform: bool,
) {
	p := &gen.params
	seed := gen.seed
	origin := game.chunk_origin(c)
	column := [2]i32{c.x, c.z}
	cols := new(Columns, context.temp_allocator)
	{
		base.profile_scope("worldgen climate")
		columns_fill(p, seed, column, cols)
	}

	// Trees from this chunk column and its neighbours may reach in.
	trees := make([dynamic]Tree, context.temp_allocator)
	{
		base.profile_scope("worldgen place trees")
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {place_trees(gen, column + {dx, dz}, &trees)}
		}
	}
	highest := p.sea_level
	rough := false
	for &row in cols {
		for &col in row {
			highest = max(highest, i32(math.floor(col.height + col.rough)) + 1)
			rough ||= col.rough > 0
		}
	}
	for t in trees {highest = max(highest, t.ground.y + t.height + 2)}
	if origin.y > highest {
		for &b in dst {b = .Air}
		return .Air, true
	}

	base.profile_scope("worldgen terrain")
	grid := new(Overhang_Grid, context.temp_allocator)
	if rough {grid_fill(seed, column, origin.y, origin.y + game.CHUNK_SIZE + MARGIN, grid)}
	caves := new(Cave_Grid, context.temp_allocator)
	has_caves := origin.y < highest - 4 && p.cave_size > 0
	if has_caves {cave_samples(seed, origin, caves)}

	for z in i32(0) ..< game.CHUNK_SIZE {
		for x in i32(0) ..< game.CHUNK_SIZE {
			col := &cols[z][x]
			wx, wz := origin.x + x, origin.z + z
			plain := i32(math.floor(col.height))
			// How deep under open air: exact without overhangs, else by
			// looking down from MARGIN above the chunk (treated as buried).
			depth := i32(999)
			for y := origin.y + game.CHUNK_SIZE - 1 + (MARGIN if col.rough > 0 else 0);
			    y >= origin.y;
			    y -= 1 {
				is_solid: bool
				if col.rough > 0 {
					is_solid = solid(col, grid, x, y, z)
					depth = (depth + 1 if depth != 999 else 999) if is_solid else -1
				} else {
					is_solid = y <= plain
					depth = plain - y
				}
				if y >= origin.y + game.CHUNK_SIZE {continue}
				b := game.Block.Air
				if is_solid {
					d := min(depth, 999)
					b = surface_block(p, col.biome, d, y)
					if has_caves && d >= 5 && y > game.WORLD_MIN_Y + 4 {
						l := [3]i32{x, y - origin.y, z}
						if in_cave(caves, l, p.cave_size) {b = .Air}
					}
					if b == .Stone {b = ore_at(seed, wx, y, wz)}
				} else if y <= p.sea_level {
					b = .Ice if y == p.sea_level && frozen(col.biome) else .Water
				}
				if y < game.WORLD_MIN_Y + 3 && is_bedrock(seed, wx, wz, y) {b = .Bedrock}
				dst[game.local_index({x, y - origin.y, z})] = b
			}
			if col.rough == 0 &&
			   plain >= p.sea_level {plant(p, seed, col, origin, dst, x, plain, z)}
		}
	}
	for t in trees {tree_write(seed, t, origin, dst)}

	first := dst[0]
	for b in dst {if b != first {return {}, false}}
	return first, true
}

// earth_spawn: near the origin, on dry, flat-ish land.
earth_spawn :: proc(gen: ^Generator) -> [3]f64 {
	p := &gen.params
	// Rings of growing radius, 16 blocks apart.
	for r in i32(0) ..< 200 {
		for i in i32(0) ..< max(1, 8 * r) {
			side := i / max(1, 2 * r)
			t := i % max(1, 2 * r) - r
			x, z: i32
			switch side {
			case 0:
				x, z = t, -r
			case 1:
				x, z = r, t
			case 2:
				x, z = -t, r
			case:
				x, z = -r, -t
			}
			x, z = x * 16 + 8, z * 16 + 8
			c := column_at(p, gen.seed, x, z)
			if c.rough > 0 || c.height < f32(p.sea_level) + 2 {continue}
			if c.biome == .Mountains || c.biome == .Beach || c.biome == .River {continue}
			return {f64(x) + 0.5, math.floor(f64(c.height)) + 2, f64(z) + 0.5}
		}
	}
	c := column_at(p, gen.seed, 0, 0)
	return {0.5, max(f64(c.height), f64(p.sea_level)) + 2, 0.5}
}

// earth_biome: the biome at (x, z).
earth_biome :: proc(gen: ^Generator, x, z: i32) -> Biome {
	return column_at(&gen.params, gen.seed, x, z).biome
}

// is_bedrock: the bottom layer, and a ragged two layers above it.
@(private = "file")
is_bedrock :: proc(seed: i64, x, z, y: i32) -> bool {
	layer := y - game.WORLD_MIN_Y
	if layer == 0 {return true}
	return f32(layer) < 3 * chance(hash(seed ~ i64(Earth_Layer.Bedrock), x, z))
}

// ore_at: stone, or ore in small clusters (2x2x2 cells, not every block),
// by depth: coal high, copper in the middle, iron deep.
@(private = "file")
ore_at :: proc(seed: i64, x, y, z: i32) -> game.Block {
	cell := chance(hash(seed ~ i64(Earth_Layer.Ore), x >> 1, y >> 1, z >> 1))
	if cell >= 0.024 {return .Stone}
	if chance(hash(seed ~ i64(Earth_Layer.Ore) + 1, x, y, z)) < 0.35 {return .Stone}
	switch {
	case cell < 0.012 && y < 90:
		return .Coal_Ore
	case cell < 0.018 && y > -50 && y < 50:
		return .Copper_Ore
	case cell < 0.024 && y < 16:
		return .Iron_Ore
	}
	return .Stone
}

// Caves: tunnels where two 3D noise fields are both near zero
// ("spaghetti"), sampled every 4 blocks and interpolated.
@(private = "file")
CAVE_STEP :: 4
@(private = "file")
CAVE_SAMPLES :: game.CHUNK_SIZE / CAVE_STEP + 1

@(private = "file")
Cave_Grid :: [CAVE_SAMPLES][CAVE_SAMPLES][CAVE_SAMPLES][2]f32 // [y][z][x]

@(private = "file")
cave_samples :: proc(seed: i64, origin: game.Block_Pos, grid: ^Cave_Grid) {
	for y in 0 ..< CAVE_SAMPLES {
		for z in 0 ..< CAVE_SAMPLES {
			for x in 0 ..< CAVE_SAMPLES {
				p := [3]f64 {
					f64(origin.x + i32(x * CAVE_STEP)),
					f64(origin.y + i32(y * CAVE_STEP)),
					f64(origin.z + i32(z * CAVE_STEP)),
				}
				q := p / [3]f64{52, 30, 52}
				grid[y][z][x] = {
					noise.noise_3d_improve_xz(seed ~ i64(Earth_Layer.Cave_A), q),
					noise.noise_3d_improve_xz(seed ~ i64(Earth_Layer.Cave_B), q),
				}
			}
		}
	}
}

@(private = "file")
in_cave :: proc(g: ^Cave_Grid, l: [3]i32, size: f32) -> bool {
	cell := l / CAVE_STEP
	f := [3]f32{f32(l.x % CAVE_STEP), f32(l.y % CAVE_STEP), f32(l.z % CAVE_STEP)} / CAVE_STEP
	v: [2]f32
	for corner in 0 ..< 8 {
		o := [3]i32{i32(corner & 1), i32(corner >> 1 & 1), i32(corner >> 2 & 1)}
		w := (o.x == 1 ? f.x : 1 - f.x) * (o.y == 1 ? f.y : 1 - f.y) * (o.z == 1 ? f.z : 1 - f.z)
		s := cell + o
		v += w * g[s.y][s.z][s.x]
	}
	return abs(v[0]) < size && abs(v[1]) < size
}

@(private)
floor_div :: proc(a, b: i32) -> i32 {
	q := a / b
	return q - 1 if (a % b != 0) && ((a < 0) != (b < 0)) else q
}
