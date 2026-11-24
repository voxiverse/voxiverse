package worldgen

import "core:math"

import "common:base"
import "common:game"
import "common:starmap"

// World classes: the authored rules a gate world is generated with. The
// address alone chooses the class (world_class), so a world is the same kind
// of place in every universe and the gate's address screen can say what is
// there before anyone goes; the universe's seed makes its terrain. Each
// class is data (CLASSES): the ranges its generator parameters are drawn
// from, the blocks that stand in for Earth's, its sea (water, magma or
// none), its plants and trees, its ores and the one rare resource found on
// no other class, its sky, gravity and day. What is not data is the few
// shapes a class's land takes (class_shape: terraces and canyons, islands,
// cones, craters) and its trees (earth_features.odin).
//
// Class None is the Earth generator as it was: the home world, Earth, and
// every world saved before classes (world.cfg without worldgen.class).

World_Class :: enum u8 {
	None, // the Earth generator unchanged (Params.class 0)
	Temperate, // forests, meadows and seas: the home world's kin
	Canyon, // red mesas in terraces cut by dry canyons
	Frozen, // snow and ice, frozen seas, slate cliffs
	Ocean, // a warm sea of scattered islands, palms on the shores
	Volcanic, // basalt and ash, cones and seas of magma
	Fungal, // violet ground under giant fungi
	Moon, // grey dust and craters, no air, no sea, low gravity
	Jungle, // hot and wet under a dense, tall canopy
}

CLASS_NAMES := [World_Class]string {
	.None      = "none",
	.Temperate = "temperate",
	.Canyon    = "canyon",
	.Frozen    = "frozen",
	.Ocean     = "ocean",
	.Volcanic  = "volcanic",
	.Fungal    = "fungal",
	.Moon      = "moon",
	.Jungle    = "jungle",
}

class_by_name :: proc(name: string) -> (World_Class, bool) {
	for n, c in CLASS_NAMES {if n == name {return c, true}}
	return {}, false
}

// world_class_of: the class a generator's parameters name.
world_class_of :: proc(p: ^Params) -> World_Class {
	c := int(p.class)
	if c <= 0 || c >= len(World_Class) {return .None}
	return World_Class(c)
}

// CLASS_SHARE: out of 100 addresses of each kind of life (world_life), how
// many are of each class: a world's class agrees with what lives there (a
// lifeless world is a moon or a volcano, one with animals is never airless).
// Every class has 9 to 15 in 100 addresses all told.
@(rodata)
CLASS_SHARE := [Life][World_Class]u8 {
	.None = #partial [World_Class]u8{.Moon = 67, .Volcanic = 33},
	.Microbial = #partial [World_Class]u8{.Moon = 16, .Volcanic = 28, .Frozen = 28, .Canyon = 28},
	.Plants = #partial [World_Class]u8{.Canyon = 25, .Frozen = 25, .Fungal = 30, .Ocean = 20},
	.Animals = #partial [World_Class]u8 {
		.Temperate = 30,
		.Jungle = 22,
		.Ocean = 20,
		.Fungal = 15,
		.Frozen = 5,
		.Canyon = 8,
	},
}

// world_class: the class of the world at address a, from the address alone.
// Earth's address is no class: it is Earth.
world_class :: proc(a: starmap.Address) -> World_Class {
	if a == starmap.earth_address() {return .None}
	life := world_life(a).life
	state := starmap.address_hash(a) ~ 0x2f6b_1c3d_9e85_a7c1
	roll := int(base.splitmix(&state) % 100)
	for share, class in CLASS_SHARE[life] {
		if roll < int(share) {return class}
		roll -= int(share)
	}
	return .Temperate
}

// Span: a parameter's range, low to high.
Span :: [2]f32

// MAX_CLASS_ORES: the most ores a class lists.
MAX_CLASS_ORES :: 8

// Class_Ore: an ore of a class: its block's id, the share of the ore cells
// it takes (Earth's three take 0.024 between them) and the heights it lies
// between. A block no pack defines is left out, so an ore of a pack not
// loaded costs nothing: the hook for ores added later.
Class_Ore :: struct {
	block:  string,
	share:  f32,
	lo, hi: i32,
}

// Swap: a block of Earth's surface rules (earth_surface) and the block that
// stands in for it on a class's world.
Swap :: struct {
	from: game.Block,
	to:   string,
}

Class_Def :: struct {
	// The shape: each drawn within its span from the address (class_params).
	sea_level, continent_scale, mountain_height, hill_height, ocean_depth: Span,
	overhang, river_width, cave_size, tree_density, plant_density:         Span,
	warmth, wetness:                                                       Span,
	continent_bias:                                                        f32, // added to continentalness: below 0 more sea, above more land
	// The rules.
	gravity, day_length:                                                   Span,
	// The blocks: what stands in for Earth's, the sea, ores, plants.
	swaps:                                                                 []Swap,
	liquid:                                                                string, // the sea ("": none, the basins dry)
	ores:                                                                  []Class_Ore, // at most MAX_CLASS_ORES
	unique:                                                                string, // the rare resource only this class has
	plant_on:                                                              string, // the ground its small plants grow on ("": none)
	plants:                                                                [2]string, // its grass and its flower ("": Earth's)
	parts:                                                                 [4]string, // its own: a canyon's rock bands, a fungus's stem, cap and glowing cap
	// The sky by day (linear rgb; at night the time of day's own): its zenith,
	// its horizon and its clouds (zero: the time of day's), how bright its
	// stars stay by day (0: none), and whether clouds are drawn.
	zenith, horizon, cloud:                                                [3]f32,
	stars:                                                                 f32,
	no_clouds:                                                             bool,
	no_ice:                                                                bool, // its water never freezes over
	no_buildings:                                                          bool, // no towers, ruins, wells or dungeons stand (only its gates)
	climate:                                                               Maybe(game.Climate), // its weather's climate everywhere (nil: each place's, by its biome)
}

// The engine's ores, as Earth places them (ore_at).
@(private = "file")
COAL :: Class_Ore{"voxiverse:coal_ore", 0.012, game.WORLD_MIN_Y, 89}
@(private = "file")
COPPER :: Class_Ore{"voxiverse:copper_ore", 0.006, -49, 49}
@(private = "file")
IRON :: Class_Ore{"voxiverse:iron_ore", 0.006, game.WORLD_MIN_Y, 15}

CLASSES := [World_Class]Class_Def {
	.None = {},
	.Temperate = {
		sea_level = {-4, 6},
		continent_scale = {1600, 3200},
		mountain_height = {60, 140},
		hill_height = {8, 20},
		ocean_depth = {24, 50},
		overhang = {4, 14},
		river_width = {0.04, 0.08},
		cave_size = {0.07, 0.12},
		tree_density = {0.8, 1.4},
		plant_density = {0.8, 1.4},
		warmth = {-0.15, 0.3},
		wetness = {0, 0.35},
		gravity = {28, 36},
		day_length = {1200, 1800},
		liquid = "voxiverse:water",
		ores = {COAL, COPPER, IRON, {"voxiverse:amber_ore", 0.002, -40, 70}},
		unique = "voxiverse:amber_ore",
		plant_on = "voxiverse:grass",
	},
	.Canyon = {
		sea_level = {-40, -30},
		continent_scale = {2400, 4000},
		mountain_height = {40, 90},
		hill_height = {10, 24},
		ocean_depth = {10, 20},
		overhang = {0, 0},
		river_width = {0, 0},
		cave_size = {0.05, 0.1},
		tree_density = {0.3, 0.7},
		plant_density = {0, 0},
		warmth = {1.1, 1.4},
		wetness = {-1.4, -1.1},
		continent_bias = 0.35,
		gravity = {26, 34},
		day_length = {1500, 2400},
		swaps = {
			{.Grass, "voxiverse:red_sand"},
			{.Dirt, "voxiverse:red_rock"},
			{.Sand, "voxiverse:red_sand"},
			{.Stone, "voxiverse:red_rock"},
			{.Gravel, "voxiverse:red_sand"},
			{.Snow, "voxiverse:red_sand"},
		},
		liquid = "voxiverse:water",
		ores = {COPPER, IRON, {"voxiverse:opal_ore", 0.003, -60, 120}},
		unique = "voxiverse:opal_ore",
		parts = {"voxiverse:red_rock", "voxiverse:sandstone", "voxiverse:red_sand", ""},
		zenith = {0.16, 0.25, 0.50},
		horizon = {0.75, 0.45, 0.25},
		cloud = {0.95, 0.80, 0.66},
		no_ice = true,
		climate = game.Climate.Dry,
	},
	.Frozen = {
		sea_level = {-6, 4},
		continent_scale = {1400, 2800},
		mountain_height = {90, 180},
		hill_height = {10, 24},
		ocean_depth = {20, 40},
		overhang = {10, 20},
		river_width = {0.02, 0.05},
		cave_size = {0.06, 0.1},
		tree_density = {0.1, 0.3},
		plant_density = {0, 0},
		warmth = {-1.5, -1.3},
		wetness = {-0.2, 0.3},
		gravity = {30, 38},
		day_length = {1800, 2400},
		swaps = {
			{.Dirt, "voxiverse:packed_ice"},
			{.Sand, "voxiverse:gravel"},
			{.Stone, "voxiverse:slate"},
			{.Clay, "voxiverse:gravel"},
			{.Grass, "voxiverse:snow"},
		},
		liquid = "voxiverse:water",
		ores = {COAL, IRON, {"voxiverse:cryolite_ore", 0.003, -60, 100}},
		unique = "voxiverse:cryolite_ore",
		zenith = {0.14, 0.32, 0.75},
		horizon = {0.62, 0.75, 0.90},
		climate = game.Climate.Cold,
	},
	.Ocean = {
		sea_level = {2, 10},
		continent_scale = {700, 1300},
		mountain_height = {20, 50},
		hill_height = {6, 14},
		ocean_depth = {40, 70},
		overhang = {0, 4},
		river_width = {0, 0},
		cave_size = {0.05, 0.09},
		tree_density = {0.8, 1.3},
		plant_density = {0.6, 1.2},
		warmth = {0.25, 0.4},
		wetness = {0.2, 0.6},
		continent_bias = -0.12,
		gravity = {28, 34},
		day_length = {900, 1500},
		swaps = {{.Stone, "voxiverse:limestone"}},
		liquid = "voxiverse:water",
		ores = {COAL, COPPER},
		unique = "voxiverse:nacre",
		plant_on = "voxiverse:grass",
		zenith = {0.06, 0.24, 0.80},
		horizon = {0.38, 0.62, 0.92},
		no_ice = true,
	},
	.Volcanic = {
		sea_level       = {-8, 2},
		continent_scale = {1200, 2400},
		mountain_height = {50, 110},
		hill_height     = {8, 20},
		ocean_depth     = {14, 30},
		overhang        = {6, 16},
		river_width     = {0, 0},
		cave_size       = {0.08, 0.14},
		tree_density    = {0.15, 0.35},
		plant_density   = {0, 0},
		warmth          = {0.1, 0.3},
		wetness         = {0.2, 0.4},
		gravity         = {36, 44},
		day_length      = {600, 1200},
		swaps           = {
			{.Grass, "voxiverse:ash"},
			{.Dirt, "voxiverse:ash"},
			{.Sand, "voxiverse:obsidian"},
			{.Gravel, "voxiverse:ash"},
			{.Sandstone, "voxiverse:basalt"},
			{.Stone, "voxiverse:basalt"},
			{.Snow, "voxiverse:ash"},
			{.Ice, "voxiverse:obsidian"},
			{.Clay, "voxiverse:ash"},
		},
		liquid          = "voxiverse:magma",
		ores            = {IRON, COPPER, {"voxiverse:sulfur_ore", 0.004, -30, 120}},
		unique          = "voxiverse:sulfur_ore",
		parts           = {"voxiverse:magma", "", "", ""},
		zenith          = {0.10, 0.035, 0.02},
		horizon         = {0.40, 0.14, 0.05},
		cloud           = {0.10, 0.07, 0.06},
		no_buildings    = true,
		climate         = game.Climate.Dry, // (ash would fall here: dry until the sky can draw it)
	},
	.Fungal = {
		sea_level = {-4, 4},
		continent_scale = {1400, 2800},
		mountain_height = {40, 100},
		hill_height = {10, 22},
		ocean_depth = {20, 40},
		overhang = {6, 16},
		river_width = {0.04, 0.08},
		cave_size = {0.08, 0.14},
		tree_density = {1.2, 1.8},
		plant_density = {1, 1.6},
		warmth = {0.35, 0.6},
		wetness = {0.5, 0.9},
		gravity = {24, 32},
		day_length = {1200, 2100},
		swaps = {{.Grass, "voxiverse:mycelium"}, {.Snow, "voxiverse:mycelium"}},
		liquid = "voxiverse:water",
		ores = {COAL, COPPER, IRON},
		unique = "voxiverse:glow_cap",
		plant_on = "voxiverse:mycelium",
		plants = {"voxiverse:spore_sprout", "voxiverse:spore_sprout"},
		parts = {"voxiverse:fungus_stem", "voxiverse:fungus_cap", "voxiverse:glow_cap", ""},
		zenith = {0.18, 0.08, 0.40},
		horizon = {0.50, 0.32, 0.55},
		cloud = {0.72, 0.60, 0.80},
		no_ice = true,
	},
	.Moon = {
		sea_level = {-64, -64},
		continent_scale = {1600, 3000},
		mountain_height = {30, 70},
		hill_height = {2, 5},
		ocean_depth = {10, 20},
		overhang = {0, 0},
		river_width = {0, 0},
		cave_size = {0.04, 0.08},
		tree_density = {0, 0},
		plant_density = {0, 0},
		warmth = {0, 0},
		wetness = {-1.5, -1.5},
		continent_bias = 0.4,
		gravity = {8, 13},
		day_length = {2400, 3600},
		swaps = {
			{.Grass, "voxiverse:regolith"},
			{.Dirt, "voxiverse:regolith"},
			{.Sand, "voxiverse:regolith"},
			{.Gravel, "voxiverse:regolith"},
			{.Sandstone, "voxiverse:stone"},
			{.Snow, "voxiverse:regolith"},
			{.Ice, "voxiverse:regolith"},
			{.Clay, "voxiverse:regolith"},
		},
		ores = {IRON, {"voxiverse:ilmenite_ore", 0.004, game.WORLD_MIN_Y, 80}},
		unique = "voxiverse:ilmenite_ore",
		parts = {"voxiverse:basalt", "voxiverse:basalt", "", ""},
		zenith = {0.002, 0.002, 0.003},
		horizon = {0.03, 0.03, 0.034},
		stars = 0.9,
		no_clouds = true,
		no_buildings = true,
		climate = game.Climate.Airless,
	},
	.Jungle = {
		sea_level = {-2, 6},
		continent_scale = {1400, 2800},
		mountain_height = {50, 120},
		hill_height = {10, 22},
		ocean_depth = {20, 40},
		overhang = {6, 14},
		river_width = {0.07, 0.12},
		cave_size = {0.07, 0.12},
		tree_density = {1.6, 2.2},
		plant_density = {2, 3},
		warmth = {0.45, 0.65},
		wetness = {0.9, 1.3},
		continent_bias = 0.08,
		gravity = {30, 36},
		day_length = {900, 1500},
		swaps = {{.Dirt, "voxiverse:mud"}, {.Clay, "voxiverse:mud"}},
		liquid = "voxiverse:water",
		ores = {COAL, COPPER, IRON, {"voxiverse:jade_ore", 0.002, game.WORLD_MIN_Y, 10}},
		unique = "voxiverse:jade_ore",
		plant_on = "voxiverse:grass",
		zenith = {0.10, 0.30, 0.55},
		horizon = {0.48, 0.65, 0.50},
		cloud = {0.85, 0.92, 0.85},
		no_ice = true,
	},
}

// class_params: the generator parameters and the rules of the world at
// address a, of class c (not None): each drawn within its class's span from
// the address (base.lcg64, not an Rng: docs/determinism.md, rule 3: a gate
// world works out its kind from its address each time it is made).
class_params :: proc(c: World_Class, a: starmap.Address) -> (p: Params, gravity, day_length: f32) {
	d := &CLASSES[c]
	n := starmap.address_hash(a) ~ 0x6a09_e667_f3bc_c909
	pick :: proc(n: ^u64, s: Span) -> f32 {
		return s[0] + base.unit_f32(base.lcg64(n)) * (s[1] - s[0])
	}
	p = PARAMS_DEFAULTS
	p.class = f32(c)
	p.sea_level = i32(math.round(pick(&n, d.sea_level)))
	p.continent_scale = pick(&n, d.continent_scale)
	p.climate_scale = pick(&n, {1600, 3200})
	p.mountain_height = pick(&n, d.mountain_height)
	p.hill_height = pick(&n, d.hill_height)
	p.ocean_depth = pick(&n, d.ocean_depth)
	p.overhang = pick(&n, d.overhang)
	p.river_width = pick(&n, d.river_width)
	p.cave_size = pick(&n, d.cave_size)
	p.tree_density = pick(&n, d.tree_density)
	p.plant_density = pick(&n, d.plant_density)
	p.warmth = pick(&n, d.warmth)
	p.wetness = pick(&n, d.wetness)
	gravity = pick(&n, d.gravity)
	day_length = f32(int(pick(&n, d.day_length)) / 60 * 60)
	return
}

// Class_Blocks: a class's blocks as the registry numbers them, found once
// when the generator is made (generator_make).
Class_Blocks :: struct {
	class:        World_Class,
	remap:        [game.Block]game.Block, // Earth's surface block to the class's
	stone:        game.Block, // its rock (where ores are)
	liquid:       game.Block, // its sea (Air: none)
	plant_on:     game.Block, // what its small plants grow on (Air: none)
	plants:       [2]game.Block,
	parts:        [4]game.Block,
	unique:       game.Block,
	ores:         [MAX_CLASS_ORES]Class_Ore_Block,
	ore_count:    int,
	ore_total:    f32, // the shares summed
	no_ice:       bool, // (Class_Def's)
	no_buildings: bool,
}

Class_Ore_Block :: struct {
	block:  game.Block,
	share:  f32,
	lo, hi: i32,
}

// class_blocks: class c's blocks in reg. A block reg lacks stands as Earth's
// (and an ore it lacks is left out).
class_blocks :: proc(reg: ^game.Registry, c: World_Class) -> (b: Class_Blocks) {
	b.class = c
	for &to, from in b.remap {to = from}
	b.stone, b.liquid = .Stone, .Water
	if c == .None {return}
	d := &CLASSES[c]
	find :: proc(reg: ^game.Registry, id: string, fallback: game.Block) -> game.Block {
		if id == "" {return fallback}
		if blk, ok := game.registry_block(reg, id); ok {return blk}
		return fallback
	}
	for s in d.swaps {
		if s.to != "" {b.remap[s.from] = find(reg, s.to, s.from)}
	}
	b.stone = b.remap[.Stone]
	b.liquid = find(reg, d.liquid, .Air)
	b.plant_on = find(reg, d.plant_on, .Air)
	b.plants = {find(reg, d.plants[0], .Tall_Grass), find(reg, d.plants[1], .Air)}
	for part, i in d.parts {b.parts[i] = find(reg, part, .Air)}
	b.unique = find(reg, d.unique, .Air)
	b.no_ice, b.no_buildings = d.no_ice, d.no_buildings
	for o in d.ores[:min(len(d.ores), MAX_CLASS_ORES)] {
		blk, ok := game.registry_block(reg, o.block)
		if !ok {continue}
		b.ores[b.ore_count] = {blk, o.share, o.lo, o.hi}
		b.ore_count += 1
		b.ore_total += o.share
	}
	return
}

// class_surface: what a solid block depth blocks under open air is on a
// class's world (Earth's surface rules, its blocks swapped; a canyon's rock
// in bands; a volcano's crater floored with magma; a moon's craters floored
// with darker rock).
@(private)
class_surface :: proc(gen: ^Generator, c: ^Column, depth, y: i32) -> game.Block {
	cb := &gen.blocks
	b := cb.remap[earth_surface(&gen.params, c.biome, depth, y)]
	#partial switch cb.class {
	case .Canyon:
		// Beds of rock a few blocks thick, the same at every height across
		// the world: the mesas' walls show them.
		if depth > 0 && b == cb.stone && y > gen.params.sea_level - 12 {
			return cb.parts[1] if canyon_band(y) else cb.parts[0]
		}
	case .Volcanic:
		if c.mark != 0 && depth < 2 {return cb.parts[0]} 	// a crater's floor
	case .Moon:
		// A crater's floor is dark basalt, the dust on its rims pale.
		if c.mark != 0 && depth == 0 {return cb.parts[c.mark - 1]}
	}
	return b
}

// canyon_band: the bed at height y is the pale one (else the red).
@(private)
canyon_band :: #force_inline proc(y: i32) -> bool {
	BEDS :: 0b100_0100 // of each seven beds, the third and the seventh
	return BEDS >> uint((y + 1024) / 3 % 7) & 1 == 1
}

// class_ore: a class's rock or ore at (x, y, z), in Earth's clusters
// (2 x 2 x 2 cells, not every block) at each ore's share.
@(private)
class_ore :: proc(gen: ^Generator, x, y, z: i32) -> game.Block {
	cb := &gen.blocks
	seed := gen.seed
	cell := base.unit_f32(hash(seed ~ i64(Earth_Layer.Ore), x >> 1, y >> 1, z >> 1))
	if cell >= cb.ore_total {return cb.stone}
	if base.unit_f32(hash(seed ~ i64(Earth_Layer.Ore) + 1, x, y, z)) < 0.35 {return cb.stone}
	acc: f32
	for o in cb.ores[:cb.ore_count] {
		acc += o.share
		if cell < acc {return o.block if y >= o.lo && y <= o.hi else cb.stone}
	}
	return cb.stone
}

// class_floor: an ocean world's sea floor holds beds of nacre here and there.
@(private)
class_floor :: #force_inline proc(
	gen: ^Generator,
	b: game.Block,
	c: ^Column,
	x, y, z: i32,
) -> game.Block {
	if gen.blocks.class != .Ocean || c.biome != .Ocean || y > gen.params.sea_level - 4 {return b}
	cell := base.unit_f32(hash(gen.seed ~ i64(Earth_Layer.Plant) + 7, x >> 2, z >> 2))
	if cell < 0.03 && base.unit_f32(hash(gen.seed ~ i64(Earth_Layer.Plant) + 8, x, z)) < 0.6 {
		return gen.blocks.unique
	}
	return b
}

// Class_Layer: the seeds of the classes' own shapes.
@(private = "file")
Class_Layer :: enum i64 {
	Canyon  = 0x71a3,
	Cone    = 0x4c8d,
	Crater  = 0x3b25,
	Crater2 = 0x5e17,
}

// class_shape: a class's own land, over the shape column_at made: terraced
// mesas and canyons, volcanic cones, craters. river is column_at's river
// noise (0 at a river's middle).
@(private)
class_shape :: proc(p: ^Params, c: ^Column, seed: i64, x, z: i32, river: f32) {
	sea := f32(p.sea_level)
	#partial switch world_class_of(p) {
	case .Canyon:
		// The land rises in treads a few blocks high with steep risers
		// between, then dry canyons wind down to a floor above the sea.
		STEP :: 7
		h := c.height - sea
		if h > 0 {
			t := h / STEP
			f := t - math.floor(t)
			c.height = sea + (math.floor(t) + smooth(0.6, 0.85, f)) * STEP
		}
		floor := sea + 6
		cut := smooth(0.07, 0.035, river)
		if cut > 0 && c.height > floor {c.height = mix(c.height, floor, cut)}
	case .Volcanic:
		// A cone in some cells of 640 blocks, a crater at its top whose
		// floor is magma (Column.mark).
		CELL :: 640
		cell := [2]i32{base.floor_div(x, CELL), base.floor_div(z, CELL)}
		h := hash(seed ~ i64(Class_Layer.Cone), cell.x, cell.y)
		if base.unit_f32(h) >= 0.6 {break}
		r := 110 + f32(h >> 8 & 63)
		height := 60 + f32(h >> 14 & 63)
		margin := i32(r) + 4
		room := u32(CELL - 2 * margin)
		h2 := hash(seed ~ i64(Class_Layer.Cone) + 1, cell.x, cell.y)
		centre := cell * CELL + margin + {i32(h2 % room), i32((h2 >> 16) % room)}
		dx, dz := f32(x - centre.x), f32(z - centre.y)
		d := math.sqrt(dx * dx + dz * dz) / r
		if d >= 1 {break}
		t := 1 - d
		c.height = max(c.height, sea + 2) + height * t * t * (3 - 2 * t) * 0.9
		crater := f32(0.16)
		if d < crater {
			k := d / crater
			c.height -= height * 0.35 * (1 - k * k)
			if k < 0.8 {c.mark = 1}
		}
		c.rough *= d // (the cone's flanks smooth)
	case .Moon:
		// Craters of two sizes, each wholly in its own cell: a bowl floored
		// with dark rock (Column.mark: 1 a great crater's, 2 a small one's),
		// then a raised rim. Most cells hold one, so one is in view anywhere.
		crater :: proc(
			c: ^Column,
			seed: i64,
			x, z: i32,
			cell_size: i32,
			r_lo, r_span: f32,
			chance: f32,
			mark: u8,
		) {
			cell := [2]i32{base.floor_div(x, cell_size), base.floor_div(z, cell_size)}
			h := hash(seed, cell.x, cell.y)
			if base.unit_f32(h) >= chance {return}
			r := r_lo + r_span * f32(h >> 8 & 255) / 255
			margin := i32(r * 1.5) + 1
			room := u32(max(1, cell_size - 2 * margin))
			h2 := hash(seed + 1, cell.x, cell.y)
			centre := cell * cell_size + margin + {i32(h2 % room), i32((h2 >> 16) % room)}
			dx, dz := f32(x - centre.x), f32(z - centre.y)
			d := math.sqrt(dx * dx + dz * dz) / r
			if d >= 1.5 {return}
			depth := r * 0.4
			if d < 1 {
				c.height -= depth * (1 - d * d)
				if d < 0.75 && (c.mark == 0 || mark < c.mark) {c.mark = mark}
			}
			rim := 1 - abs(d - 1.05) / 0.4
			if rim > 0 {c.height += depth * 0.6 * smooth(0, 1, rim)}
		}
		crater(c, seed ~ i64(Class_Layer.Crater), x, z, 240, 34, 56, 0.85, 1)
		crater(c, seed ~ i64(Class_Layer.Crater2), x, z, 60, 5, 12, 0.7, 2)
	}
}
