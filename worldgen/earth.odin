package worldgen

import "core:math/noise"

import "../game"

// The Earth generator: continents and oceans, rivers, mountains with
// overhangs, biomes from a climate, caves, ores, trees and plants.
//
// Every block column has a climate, from 2D noise: how far inland it is
// (continentalness), how rugged, how warm, how wet, and whether a river
// runs there. From those come a smooth height and a biome. Where the land
// is rugged, 3D noise (sampled on a coarse world-aligned grid and
// interpolated: the same values whichever chunk asks) adds cliffs and
// overhangs around that height. Surface rules dress the top by biome and
// depth; caves, ores and the sea come after; trees and plants last, each
// chunk also running its neighbours' placements so features cross chunk
// borders whole.
//
// Only arithmetic (no sin, exp or pow): the same world on every OS.

// Params: what shapes an Earth world (the worldgen.* variables).
Params :: struct {
	sea_level:       i32,
	continent_scale: f32, // blocks: the size of continents and oceans
	climate_scale:   f32, // blocks: the size of warm, cold, wet and dry regions
	mountain_height: f32, // blocks above the plains, at the highest ridges
	hill_height:     f32,
	ocean_depth:     f32,
	overhang:        f32, // blocks: how far cliffs lean out, in the mountains
	river_width:     f32, // 0..1: how much land rivers take
	cave_size:       f32, // 0..1
	tree_density:    f32, // 1: as designed; 0: none
	plant_density:   f32,
}

@(rodata)
PARAMS_DEFAULTS := Params {
	sea_level       = 0,
	continent_scale = 2000,
	climate_scale   = 2400,
	mountain_height = 120,
	hill_height     = 12,
	ocean_depth     = 34,
	overhang        = 10,
	river_width     = 0.05,
	cave_size       = 0.09,
	tree_density    = 1,
	plant_density   = 1,
}

Biome :: enum u8 {
	Ocean,
	Frozen_Ocean,
	Beach,
	River,
	Plains,
	Forest,
	Taiga,
	Tundra,
	Desert,
	Mountains,
}

BIOME_NAMES := [Biome]string {
	.Ocean        = "ocean",
	.Frozen_Ocean = "frozen_ocean",
	.Beach        = "beach",
	.River        = "river",
	.Plains       = "plains",
	.Forest       = "forest",
	.Taiga        = "taiga",
	.Tundra       = "tundra",
	.Desert       = "desert",
	.Mountains    = "mountains",
}

// Per-layer seeds, so layers are uncorrelated.
@(private)
Earth_Layer :: enum i64 {
	Continent = 0x41c3,
	Rugged    = 0x2a77,
	Ridge     = 0x6d01,
	Hills     = 0x1b5e,
	River     = 0x5c2f,
	Heat      = 0x3e91,
	Wet       = 0x7f13,
	Overhang  = 0x0d6b,
	Cave_A    = 0x2d95,
	Cave_B    = 0x5be7,
	Bedrock   = 0x3c11,
	Ore       = 0x4a3d,
	Tree      = 0x6e29,
	Plant     = 0x1f87,
}

// Column: one block column's climate and shape.
Column :: struct {
	height:      f32, // the land's smooth height (solid at and below, before overhangs)
	rough:       f32, // how far overhangs reach above and below it (0: none)
	temperature: f32, // about -1..1
	humidity:    f32,
	river:       f32, // 0..1: how much of a river's bed this is
	biome:       Biome,
}

// column_at: the climate and shape of the block column at (x, z).
column_at :: proc(p: ^Params, seed: i64, x, z: i32) -> (c: Column) {
	at := [2]f64{f64(x), f64(z)}
	continent := fbm2(seed ~ i64(Earth_Layer.Continent), at / f64(p.continent_scale), 5)
	rugged := fbm2(seed ~ i64(Earth_Layer.Rugged), at / f64(p.continent_scale * 0.45), 3)
	ridge := 1 - abs(fbm2(seed ~ i64(Earth_Layer.Ridge), at / 420, 4))
	hills := fbm2(seed ~ i64(Earth_Layer.Hills), at / 96, 4)
	river := abs(fbm2(seed ~ i64(Earth_Layer.River), at / 520, 3))

	// The land rises from the ocean floor through the shelf and the coast
	// to the plains (continentalness -1..1 to a height).
	base := spline(
		continent,
		{
			{-1.0, -p.ocean_depth * 1.4},
			{-0.4, -p.ocean_depth},
			{-0.22, -9},
			{-0.12, f32(0.5)},
			{-0.06, 3},
			{0.35, 10},
			{1.0, 22},
		},
	)
	inland := smooth(-0.12, 0.15, continent)
	mountainous := smooth(-0.02, 0.4, continent) * smooth(-0.05, 0.4, rugged)
	height := base + hills * p.hill_height * (0.25 + 0.75 * inland)
	height += mountainous * ridge * ridge * p.mountain_height
	// Rivers wind through the lowlands down to just below the sea.
	if inland > 0 && p.river_width > 0 {
		// A valley leads down to the banks, then a steep channel below the sea.
		bed :=
			smooth(p.river_width * 1.4, p.river_width * 0.85, river) *
			inland *
			(1 - smooth(0.2, 0.5, mountainous))
		valley :=
			smooth(p.river_width * 6, p.river_width * 1.4, river) * inland * (1 - mountainous)
		height = mix(
			height,
			max(f32(p.sea_level) + 3, min(height, f32(p.sea_level) + 9)),
			valley * 0.7,
		)
		height = mix(height, f32(p.sea_level) - 4, bed)
		c.river = bed
	}
	c.height = height
	c.rough = p.overhang * mountainous * smooth(0.35, 0.85, ridge)

	c.temperature =
		fbm2(seed ~ i64(Earth_Layer.Heat), at / f64(p.climate_scale), 3) * 1.6 -
		max(0, height - f32(p.sea_level) - 50) / 90
	c.humidity = fbm2(seed ~ i64(Earth_Layer.Wet), at / f64(p.climate_scale * 0.6), 3) * 1.6
	c.biome = biome_of(p, &c, continent, mountainous)
	return
}

@(private = "file")
biome_of :: proc(p: ^Params, c: ^Column, continent, mountainous: f32) -> Biome {
	sea := f32(p.sea_level)
	cold := c.temperature < -0.5
	switch {
	case c.height < sea - 3 && c.river < 0.5:
		return .Frozen_Ocean if cold else .Ocean
	case c.river > 0.3 && c.height < sea:
		return .Tundra if cold else .River
	case c.river > 0.2 && c.height < sea + 1:
		return .Tundra if cold else .Beach // the banks
	case c.height < sea + 1.8 && continent < 0.0:
		return .Tundra if cold else .Beach
	case mountainous > 0.3 && c.height > sea + 45:
		return .Mountains
	case cold:
		return .Tundra
	case c.temperature < -0.12:
		return .Taiga
	case c.temperature > 0.4 && c.humidity < 0.05:
		return .Desert
	case c.humidity > 0.12:
		return .Forest
	}
	return .Plains
}

// frozen: the sea freezes over here.
@(private)
frozen :: proc(b: Biome) -> bool {
	return b == .Frozen_Ocean || b == .Tundra
}

// surface_block: what a solid block depth blocks under open air is, in
// biome b, at height y (depth 0: the top).
@(private)
surface_block :: proc(p: ^Params, b: Biome, depth, y: i32) -> game.Block {
	sea := p.sea_level
	underwater := y < sea
	switch b {
	case .Ocean, .Frozen_Ocean, .River:
		if depth <
		   3 {return .Clay if b == .River && depth == 0 && (y & 3) == 0 else (.Gravel if y < sea - 18 else .Sand)}
	case .Beach:
		if depth < 4 {return .Sand}
		if depth < 7 {return .Sandstone}
	case .Desert:
		if depth < 4 {return .Sand}
		if depth < 8 {return .Sandstone}
	case .Mountains:
		if depth == 0 && y > sea + 95 {return .Snow}
		if depth == 0 && y < sea + 70 {return .Grass}
		if depth < 3 && y < sea + 70 {return .Dirt}
	case .Tundra:
		if depth == 0 {return .Sand if underwater else .Snow}
		if depth < 3 {return .Dirt}
	case .Plains, .Forest, .Taiga:
		if depth == 0 {return .Sand if underwater else .Grass}
		if depth < 3 {return .Dirt}
	}
	return .Stone
}

// fbm2 sums octaves of 2D simplex noise; the result is roughly in -1..1.
@(private)
fbm2 :: proc(seed: i64, p: [2]f64, octaves: int) -> f32 {
	sum, amplitude, total: f32 = 0, 1, 0
	q := p
	for o in 0 ..< octaves {
		sum += amplitude * noise.noise_2d(seed + i64(o), q)
		total += amplitude
		amplitude *= 0.5
		q *= 2
	}
	return sum / total
}

// smooth: 0 at edge0, 1 at edge1, smoothstep between (either order).
@(private)
smooth :: proc(edge0, edge1, x: f32) -> f32 {
	t := clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private)
mix :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

// spline: piecewise linear through points (x ascending), flat beyond.
@(private)
spline :: proc(x: f32, points: [][2]f32) -> f32 {
	if x <= points[0].x {return points[0].y}
	for i in 1 ..< len(points) {
		a, b := points[i - 1], points[i]
		if x <= b.x {return mix(a.y, b.y, (x - a.x) / (b.x - a.x))}
	}
	return points[len(points) - 1].y
}

// hash: a well-mixed 32 bits from a seed and up to three integers.
@(private)
hash :: proc(seed: i64, a, b: i32, c: i32 = 0) -> u32 {
	h := u32(seed) ~ u32(seed >> 32) * 0x9e37_79b1
	h ~= u32(a) * 0x85eb_ca6b
	h = (h ~ h >> 15) * 0xc2b2_ae35
	h ~= u32(b) * 0x27d4_eb2d
	h = (h ~ h >> 13) * 0x1656_67b1
	h ~= u32(c) * 0x9e37_79b9
	h = (h ~ h >> 16) * 0x85eb_ca6b
	return h ~ h >> 13
}

// chance: a hash as 0..1.
@(private)
chance :: proc(h: u32) -> f32 {
	return f32(h >> 8) / f32(1 << 24)
}
