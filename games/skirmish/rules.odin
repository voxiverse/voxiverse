package skirmish

import "common:base"
import "common:game"

// Skirmish: a small real-time strategy for one to four sides on a seeded map, seen from a
// free camera with no body in the world. Each side starts with a headquarters and a few
// workers; workers gather two resources (ore from crystal outcrops, wood from groves) and
// put up buildings; buildings train units within the supply the side has room for; armies
// are picked with the pointer and ordered about, and fight by themselves what they meet.
// A side whose headquarters and every building that trains are gone has lost; the last
// side standing wins. Sides no player takes are played by a simple computer opponent that
// gives its orders as a player's requests do. What both parts share is here: the map's
// size, the units' and buildings' tables, their shapes, the orders.

INFO :: game.Game_Info {
	id          = "skirmish",
	name        = "Skirmish",
	description = "A small real-time strategy: gather, build, command.",
}

MAP :: 112 // blocks a side: the map is the block columns 0 ..< MAP in x and z
GROUND :: 0 // the y a walker stands in on the low ground (the flat world's top is -1)
HIGH :: 3 // blocks the high ground stands over the low
MAX_SIDES :: 4
COMMANDER_MODE :: "skirmish:commander"

Phase :: enum u8 {
	Waiting, // the map is being made, or nobody plays
	Playing,
	Results, // a side won; a new match follows
}

Resource :: enum u8 {
	Ore,
	Wood,
}

Unit :: enum u8 {
	Worker,
	Soldier, // close combat
	Archer, // at range
	Ram, // slow, against buildings
}

Building :: enum u8 {
	Headquarters,
	Barracks,
	Workshop,
	Tower,
	Depot,
}

Cost :: [Resource]int

Unit_Info :: struct {
	kind:    string, // its entity kind
	name:    Text,
	cost:    Cost,
	supply:  int,
	seconds: f32, // to train
	vision:  int, // blocks
	sight:   f64, // blocks within which it finds a foe by itself
	reach:   f32, // blocks between boxes it strikes within (its kind's attack's)
	at:      Building, // where it is trained
}

UNITS := [Unit]Unit_Info {
	.Worker  = {
		"skirmish:worker",
		.Unit_Worker,
		{.Ore = 50, .Wood = 0},
		1,
		8,
		9,
		0,
		1,
		.Headquarters,
	},
	.Soldier = {
		"skirmish:soldier",
		.Unit_Soldier,
		{.Ore = 60, .Wood = 0},
		1,
		10,
		10,
		9,
		1,
		.Barracks,
	},
	.Archer  = {
		"skirmish:archer",
		.Unit_Archer,
		{.Ore = 45, .Wood = 30},
		1,
		11,
		12,
		10,
		6,
		.Barracks,
	},
	.Ram     = {"skirmish:ram", .Unit_Ram, {.Ore = 90, .Wood = 80}, 3, 18, 8, 6, 1.5, .Workshop},
}

// RAM_AGAINST_BUILDINGS: a ram's blow at a building counts this many times.
RAM_AGAINST_BUILDINGS :: 6
// ARMOUR_AGAINST_UNITS: a building takes a soldier's or an archer's blow at this share.
BUILDING_ARMOUR :: 0.5

Building_Info :: struct {
	kind:    string, // its entity kind (the flag over its blocks, its health)
	name:    Text,
	cost:    Cost,
	seconds: f32, // to build, with one worker at it
	size:    i32, // its footprint's side, blocks
	height:  i32,
	vision:  int,
	supply:  int, // the room for units it gives (built)
	trains:  bit_set[Unit],
}

BUILDINGS := [Building]Building_Info {
	.Headquarters = {
		"skirmish:headquarters",
		.Building_Headquarters,
		{},
		0,
		5,
		4,
		14,
		10,
		{.Worker},
	},
	.Barracks     = {
		"skirmish:barracks",
		.Building_Barracks,
		{.Ore = 0, .Wood = 150},
		20,
		4,
		3,
		9,
		0,
		{.Soldier, .Archer},
	},
	.Workshop     = {
		"skirmish:workshop",
		.Building_Workshop,
		{.Ore = 120, .Wood = 120},
		24,
		4,
		3,
		9,
		0,
		{.Ram},
	},
	.Tower        = {
		"skirmish:tower",
		.Building_Tower,
		{.Ore = 60, .Wood = 60},
		16,
		2,
		5,
		14,
		0,
		{},
	},
	.Depot        = {
		"skirmish:depot",
		.Building_Depot,
		{.Ore = 0, .Wood = 80},
		12,
		3,
		2,
		7,
		8,
		{},
	},
}

// What a worker may put up (the headquarters each side starts with).
BUILDABLE :: bit_set[Building]{.Barracks, .Workshop, .Tower, .Depot}

// The tower's own shot.
TOWER_REACH :: 9 // blocks
TOWER_DAMAGE :: 3
TOWER_COOLDOWN :: 30 // ticks

START :: Cost {
	.Ore  = 150,
	.Wood = 100,
}
START_WORKERS :: 4
SUPPLY_LIMIT :: 60 // the most room for units a side has, however many depots
MAX_QUEUE :: 5 // units waiting to be trained at a building
CARRY :: 5 // what a worker brings back each trip
GATHER_TICKS :: 45 // a worker's work at a node for one load
NODE_ORE :: 600 // what a crystal outcrop holds
NODE_WOOD :: 500 // ... a grove
RESULTS_SECONDS :: 10

// Order_Kind: what a player (or the computer) tells the units it picked to do.
Order_Kind :: enum u8 {
	Move, // to the point; fight back only when struck
	Attack, // the target, wherever it goes
	Attack_Move, // to the point, fighting whatever they meet on the way
	Gather, // the node, back and forth to the nearest drop-off
	Build, // a building of `building` at the point (the workers among them)
	Stop, // stand (and fight what comes within sight)
}

// MAX_ORDER_IDS: the units one Order names (a selection of more is several orders).
MAX_ORDER_IDS :: 48

// ---- the buildings' shapes (both sides': the server places them, the client draws their
// ghost where one would go) ----

// building_template: a building's blocks, its footprint size x height x size: walls of its
// material, a door gap on each side at the ground, a roof; a tower is a column.
building_template :: proc(b: Building, allocator := context.allocator) -> game.Template {
	info := BUILDINGS[b]
	n, h := info.size, info.height
	t := game.template_make({n, h, n}, allocator)
	wall, roof := game.Block.Planks, game.Block.Log
	#partial switch b {
	case .Headquarters:
		wall, roof = .Stone_Bricks, .Planks
	case .Workshop:
		wall, roof = .Cobblestone, .Planks
	case .Tower:
		wall, roof = .Stone_Bricks, .Cobblestone
	}
	game.template_fill(&t, {0, 0, 0}, {n - 1, h - 2, n - 1}, wall)
	if n >= 3 {
		game.template_fill(&t, {1, 0, 1}, {n - 2, h - 2, n - 2}, .Air) // (hollow)
	}
	game.template_fill(&t, {0, h - 1, 0}, {n - 1, h - 1, n - 1}, roof)
	return t
}

// building_corner: the lowest corner of a building's footprint centred on a block column
// (the point a player picks).
building_corner :: proc(b: Building, at: [2]i32) -> [2]i32 {
	n := BUILDINGS[b].size
	return at - n / 2
}

// building_middle: where a building's entity stands (the middle of its footprint's floor).
building_middle :: proc(b: Building, corner: [2]i32, floor: i32) -> [3]f64 {
	n := f64(BUILDINGS[b].size)
	return {f64(corner.x) + n / 2, f64(floor), f64(corner.y) + n / 2}
}

// on_map: the block column lies on the map with room for a footprint of size.
on_map :: proc(corner: [2]i32, size: i32) -> bool {
	return(
		corner.x >= 1 &&
		corner.y >= 1 &&
		corner.x + size <= MAP - 1 &&
		corner.y + size <= MAP - 1 \
	)
}

// can_afford: the stock covers the cost.
can_afford :: proc(stock, cost: Cost) -> bool {
	for r in Resource {if stock[r] < cost[r] {return false}}
	return true
}

// team_color: a side's colour (by team, 1 to MAX_SIDES).
TEAM_COLORS := [MAX_SIDES + 1][4]u8 {
	{160, 160, 160, 255},
	{220, 60, 50, 255},
	{50, 110, 230, 255},
	{240, 200, 40, 255},
	{60, 180, 90, 255},
}

// Settings: what the admin sets (`/skirmish set <name> <value>`), from the next match,
// each described once with its bounds (SETTINGS_VARS), kept with the universe.
Settings :: struct {
	sides:   int, // in a match: the players present take them in turn, the computer the rest
	wave:    int, // the units the computer gathers before its first attack (more each time)
	ore:     int, // each side's at the start
	wood:    int,
	workers: int,
}

@(rodata)
DEFAULT_SETTINGS := Settings {
	sides   = 2,
	wave    = 6,
	ore     = START[.Ore],
	wood    = START[.Wood],
	workers = START_WORKERS,
}

@(rodata)
SETTINGS_VARS := [?]base.Var {
	{
		field = "sides",
		help = "sides in a match (players first, the computer the rest)",
		min = 2,
		max = MAX_SIDES,
	},
	{
		field = "wave",
		help = "units the computer gathers before its first attack",
		min = 1,
		max = 40,
	},
	{field = "ore", help = "each side's ore at the start", min = 0, max = 5000},
	{field = "wood", help = "each side's wood at the start", min = 0, max = 5000},
	{field = "workers", help = "each side's workers at the start", min = 1, max = 12},
}

settings_table :: proc() -> base.Var_Table {
	return {"", Settings, SETTINGS_VARS[:], &DEFAULT_SETTINGS}
}
