package hamlet

import "common:base"
import "common:game"

// Hamlet: a small village builder for one player or several, seen from a free camera
// with no body in the world. The players lay roads, zone land for homes and place
// workplaces from a toolbar; citizens move in when there are homes and water, take the
// jobs, walk the roads between home, work and the storehouse carrying what they made,
// and leave when they go hungry or unhappy. What both sides share is here: the map's
// tiles, the buildings' table and shapes, the ground from the seed, the rules' numbers.

INFO :: game.Game_Info {
	id          = "hamlet",
	name        = "Hamlet",
	description = "Co-op village builder: roads, homes, work, food.",
}

MAP :: 96 // tiles on a side: tile (x, z) is the block column (x, z), both from 0
GROUND :: -1 // the flat world's top: the lowest ground; hills rise above it
MAX_HILL :: 3 // blocks of hill at most over GROUND
PLANNER_MODE :: "hamlet:planner"
CITIZEN_KIND :: "hamlet:citizen"

// Tile: what stands on a tile of the map.
Tile :: enum u8 {
	Grass,
	Road,
	Zone, // zoned for homes, nothing built yet
	House,
	Building, // a workplace, the storehouse, a well, a market
	Water,
	Tree,
	Rock,
}

// Good: what the stock holds.
Good :: enum u8 {
	None,
	Wood,
	Stone,
	Food,
}

// Kind: a structure the game knows. Houses grow by themselves on zoned land; the rest
// are placed from the toolbar.
Kind :: enum u8 {
	House,
	Woodcutter,
	Quarry,
	Farm,
	Storehouse,
	Well,
	Market,
}

Kind_Info :: struct {
	name:   string,
	cost:   [Good]int, // taken from the stock when it is built
	jobs:   int, // workers it takes
	homes:  int, // citizens it houses
	makes:  Good, // what a shift there brings to the storehouse
	needs:  Tile, // Tree or Rock within RESOURCE_REACH of it (Grass: nothing)
	layers: []string, // its shape (template_shape), bottom up
	placed: bool, // from the toolbar (a house grows on its own)
}

@(rodata)
KINDS_INFO := [Kind]Kind_Info {
	.House = {
		name = "House",
		cost = #partial [Good]int{.Wood = 4, .Stone = 2},
		homes = 5,
		layers = {"LPL/P_P/L_L", "LGL/G_G/L_L", "LPL/P_P/LPL", "sss/sss/sss"},
	},
	.Woodcutter = {
		name = "Woodcutter",
		cost = #partial [Good]int{.Wood = 6},
		jobs = 3,
		makes = .Wood,
		needs = .Tree,
		layers = {"LPL/P__/L_L", "L_L/___/L_L", "sss/sss/sss"},
		placed = true,
	},
	.Quarry = {
		name = "Quarry",
		cost = #partial [Good]int{.Wood = 8},
		jobs = 3,
		makes = .Stone,
		needs = .Rock,
		layers = {"CCC/C__/C_C", "C_C/___/C_C", "ccc/ccc/ccc"},
		placed = true,
	},
	.Farm = {
		name = "Farm",
		cost = #partial [Good]int{.Wood = 6},
		jobs = 4,
		makes = .Food,
		layers = {"fffff/fFFFf/fFFFf/fFFFf/ff_ff", "_____/_WWW_/_WWW_/_WWW_/_____"},
		placed = true,
	},
	.Storehouse = {
		name = "Storehouse",
		cost = #partial [Good]int{.Wood = 10, .Stone = 6},
		jobs = 2,
		layers = {
			"SPPS/P__P/P__P/S__S",
			"SPPS/G__G/P__P/S__S",
			"SPPS/P__P/P__P/SPPS",
			"ssss/ssss/ssss/ssss",
		},
		placed = true,
	},
	.Well = {
		name = "Well",
		cost = #partial [Good]int{.Wood = 2, .Stone = 6},
		layers = {"CCC/CwC/CCC", "f_f/___/f_f", "sss/sss/sss"},
		placed = true,
	},
	.Market = {
		name = "Market",
		cost = #partial [Good]int{.Wood = 12, .Stone = 8},
		jobs = 2,
		layers = {
			"L___L/_____/__C__/_____/L___L",
			"L___L/_____/_____/_____/L___L",
			"RRRRR/RRRRR/RRRRR/RRRRR/RRRRR",
		},
		placed = true,
	},
}

// The shapes' characters and the blocks they stand for (by name: the registry's).
SHAPE_KEY :: "LPGsSCcfFWwR_."
SHAPE_BLOCKS :: [?]string {
	"log",
	"planks",
	"glass",
	"planks_slab",
	"stone_bricks",
	"cobblestone",
	"cobblestone_slab",
	"planks_fence",
	"farmland",
	"wheat_7",
	"water",
	"wool",
	"air",
}
#assert(len(SHAPE_BLOCKS) == len(SHAPE_KEY) - 1) // ('.' is void)

ROAD_BLOCK :: "gravel"

START_STOCK :: #partial [Good]int {
	.Wood  = 60,
	.Stone = 30,
	.Food  = 40,
}

RESOURCE_REACH :: 10 // tiles: a woodcutter's trees, a quarry's rocks are this near
WELL_REACH :: 14 // tiles: a house this near a well has water
MARKET_REACH :: 16 // tiles: a house this near a market is happier
ACCESS_REACH :: 2 // tiles: the road access overlay's reach
MAX_STRUCTURES :: 256
MAX_CITIZENS :: 1000
@(rodata)
MILESTONES := [?]int{25, 50, 100, 200}

// Simulation steps (the world's: sim_speed multiplies them).
DAY_STEPS :: 30 * 20 // a day: each citizen eats once
WORK_STEPS :: 30 * 5 // a shift
REST_STEPS :: 30 * 3 // at home between shifts
ARRIVE_STEPS :: 30 * 2 // between arrivals
GROW_STEPS :: 30 // between looks at the zones for a house to grow
CARRY :: 2 // goods a worker brings from a shift
WALK_SPEED :: 3.0 // blocks a second on the roads

// Ground: the map's land from its seed: the height of each tile's ground (GROUND to
// GROUND + MAX_HILL, gently: neighbours differ by at most one), and what stands on it
// (Grass, Water, Tree or Rock).
Ground :: struct {
	height: [MAP][MAP]i8, // [z][x]: the top block's y
	tiles:  [MAP][MAP]Tile, // [z][x]
}

// ground_make: the land of a seed. The same on every machine (the game's own random
// numbers, no clock): a smooth sum of a few bumps for the hills, a pond in the low
// ground, woods and rocks in clusters, the middle left open for the first roads.
ground_make :: proc(g: ^Ground, seed: u32) {
	g^ = {}
	rng := base.rng_make(u64(seed) ~ 0x4a3e1e7)
	Bump :: struct {
		x, z, r, h: f32,
	}
	bumps: [8]Bump
	for &b in bumps {
		b = {
			f32(base.rng_int_max(&rng, MAP)),
			f32(base.rng_int_max(&rng, MAP)),
			f32(12 + base.rng_int_max(&rng, 18)),
			f32(1 + base.rng_int_max(&rng, MAX_HILL)),
		}
	}
	for z in 0 ..< MAP {
		for x in 0 ..< MAP {
			h: f32
			for b in bumps {
				dx, dz := f32(x) - b.x, f32(z) - b.z
				d := (dx * dx + dz * dz) / (b.r * b.r)
				if d < 1 {h = max(h, b.h * (1 - d) * (1 - d) * 1.6)}
			}
			g.height[z][x] = i8(GROUND + i32(clamp(h, 0, MAX_HILL)))
		}
	}
	// Smooth: no step of more than one between neighbours.
	for _ in 0 ..< MAX_HILL {
		for z in 0 ..< MAP {
			for x in 0 ..< MAP {
				for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					nx, nz := x + d.x, z + d.y
					if nx < 0 || nz < 0 || nx >= MAP || nz >= MAP {continue}
					g.height[z][x] = min(g.height[z][x], g.height[nz][nx] + 1)
				}
			}
		}
	}
	// A pond on the low ground, away from the middle.
	px := 12 + base.rng_int_max(&rng, 20)
	pz := 60 + base.rng_int_max(&rng, 24)
	for z in pz - 6 ..= pz + 6 {
		for x in px - 8 ..= px + 8 {
			dx, dz := f32(x - px) / 8, f32(z - pz) / 6
			if x < 0 || z < 0 || x >= MAP || z >= MAP || dx * dx + dz * dz > 1 {continue}
			g.tiles[z][x] = .Water
			g.height[z][x] = GROUND
		}
	}
	// Woods and rocks, in clusters, not in the middle.
	cluster :: proc(g: ^Ground, rng: ^base.Rng, tile: Tile, count, spread, chance: int) {
		for _ in 0 ..< count {
			cx, cz := base.rng_int_max(rng, MAP), base.rng_int_max(rng, MAP)
			for z in cz - spread ..= cz + spread {
				for x in cx - spread ..= cx + spread {
					if x < 1 || z < 1 || x >= MAP - 1 || z >= MAP - 1 {continue}
					if abs(x - MAP / 2) < 12 && abs(z - MAP / 2) < 12 {continue}
					if g.tiles[z][x] != .Grass || base.rng_int_max(rng, 100) >= chance {continue}
					g.tiles[z][x] = tile
				}
			}
		}
	}
	cluster(g, &rng, .Tree, 9, 5, 22)
	cluster(g, &rng, .Rock, 4, 3, 35)
}

// ground_top: the y of tile (x, z)'s ground block.
ground_top :: proc(g: ^Ground, x, z: i32) -> i32 {
	if x < 0 || z < 0 || x >= MAP || z >= MAP {return GROUND}
	return i32(g.height[z][x])
}

// on_map: tile (x, z) is on the map.
on_map :: proc(x, z: i32) -> bool {
	return x >= 0 && z >= 0 && x < MAP && z < MAP
}

// footprint: the tiles a kind covers placed at (x, z) (its lowest corner) turned
// rotation quarter turns: its size along x and z.
footprint :: proc(kind: Kind, rotation: u8) -> [2]i32 {
	rows := 1
	width := 0
	for c in KINDS_INFO[kind].layers[0] {
		if c == '/' {rows += 1} else if rows == 1 {width += 1}
	}
	if rotation & 1 == 1 {return {i32(rows), i32(width)}}
	return {i32(width), i32(rows)}
}

// template_shape: a kind's shape as a template, its block names resolved in reg; false
// when the registry lacks one.
template_shape :: proc(
	reg: ^game.Registry,
	kind: Kind,
	allocator := context.allocator,
) -> (
	t: game.Template,
	ok: bool,
) {
	cells: [len(SHAPE_KEY)]u16
	for name, i in SHAPE_BLOCKS {
		b := game.registry_block(reg, name) or_return
		cells[i] = u16(b)
	}
	cells[len(SHAPE_KEY) - 1] = game.VOID
	return game.template_build(KINDS_INFO[kind].layers, SHAPE_KEY, cells[:], allocator)
}

// road_path: the tiles of a road dragged from a to b: along x from a, then along z to
// b (an L), each once, in order.
road_path :: proc(a, b: [2]i32, allocator := context.temp_allocator) -> [][2]i32 {
	out := make([dynamic][2]i32, allocator)
	x, z := a.x, a.y
	append(&out, [2]i32{x, z})
	for x != b.x {
		x += 1 if b.x > x else -1
		append(&out, [2]i32{x, z})
	}
	for z != b.y {
		z += 1 if b.y > z else -1
		append(&out, [2]i32{x, z})
	}
	return out[:]
}

// can_afford: the stock holds a cost.
can_afford :: proc(stock: [Good]int, cost: [Good]int) -> bool {
	for n, g in cost {if stock[g] < n {return false}}
	return true
}

// Tiles: the map's tiles, [z][x].
Tiles :: [MAP][MAP]Tile

// tile_at: what stands on tile (x, z) (off the map: Water, where nothing goes).
tile_at :: proc(tiles: ^Tiles, x, z: i32) -> Tile {
	if !on_map(x, z) {return .Water}
	return tiles[z][x]
}

// access: the first road tile next to the footprint at..at+size-1 (its edge walked
// from the low corner along x, the far side first, then the two ends): where its
// people come and go; false when no road touches it.
access :: proc(tiles: ^Tiles, at, size: [2]i32) -> (p: [2]i32, ok: bool) {
	for x in at.x ..< at.x + size.x {
		for z in ([2]i32{at.y + size.y, at.y - 1}) {
			if tile_at(tiles, x, z) == .Road {return {x, z}, true}
		}
	}
	for z in at.y ..< at.y + size.y {
		for x in ([2]i32{at.x - 1, at.x + size.x}) {
			if tile_at(tiles, x, z) == .Road {return {x, z}, true}
		}
	}
	return
}

// resource_near: a tile of `need` within RESOURCE_REACH of the footprint's middle
// (Grass: nothing is needed).
resource_near :: proc(tiles: ^Tiles, at, size: [2]i32, need: Tile) -> bool {
	if need == .Grass {return true}
	c := at + size / 2
	for z in c.y - RESOURCE_REACH ..= c.y + RESOURCE_REACH {
		for x in c.x - RESOURCE_REACH ..= c.x + RESOURCE_REACH {
			if on_map(x, z) && tiles[z][x] == need {return true}
		}
	}
	return false
}

// placement: why kind may not go at `at` turned rotation by the map's rules ("": it
// may), and the floor it would stand on: every tile of its footprint on the map and
// one of `allow`, the ground under it even within a block, a road touching it, what it
// needs near. (Whether the blocks there leave room is the server's to see.)
placement :: proc(
	tiles: ^Tiles,
	ground: ^Ground,
	kind: Kind,
	at: [2]i32,
	rotation: u8,
	allow: bit_set[Tile],
) -> (
	floor: i32,
	refusal: string,
) {
	size := footprint(kind, rotation)
	lo, hi := i32(127), i32(-128)
	for z in at.y ..< at.y + size.y {
		for x in at.x ..< at.x + size.x {
			if !on_map(x, z) {return 0, "Not on the map"}
			if tiles[z][x] not_in allow {return 0, "Something is in the way"}
			h := ground_top(ground, x, z)
			lo, hi = min(lo, h), max(hi, h)
		}
	}
	if hi - lo > 1 {return 0, "The ground is too steep"}
	if _, ok := access(tiles, at, size); !ok {return 0, "It must touch a road"}
	info := &KINDS_INFO[kind]
	if !resource_near(tiles, at, size, info.needs) {
		return 0, "It needs trees nearby" if info.needs == .Tree else "It needs rocks nearby"
	}
	return hi + 1, ""
}

// road_refusal: why a road may not go along tiles ("": it may): every tile open
// (grass, zoned or road already).
road_refusal :: proc(tiles: ^Tiles, path: [][2]i32) -> string {
	if len(path) > 2 * MAP {return "That road is too long"}
	for p in path {
		switch tile_at(tiles, p.x, p.y) {
		case .Grass, .Zone, .Road:
		case .House, .Building:
			return "A road cannot go through a building"
		case .Water, .Tree, .Rock:
			return "A road cannot go there (water, trees, rocks)"
		}
	}
	return ""
}
