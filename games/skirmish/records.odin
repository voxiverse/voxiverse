package skirmish

import "common:game"
import "common:protocol"

// What Skirmish tells its players besides the engine's kinds (docs/games.md), and what they
// ask of it. The units, buildings and nodes themselves are entities: under the fog of war
// (core.world_fog) a player is told only of those its side sees, each with its team; the
// records below about an entity follow the same rule (they go to a player who knows it).

// Match: the match as everyone sees it.
Match :: struct {
	phase:   Phase,
	match:   u16,
	seconds: u32, // into the match (Playing), or left (Results)
	winner:  u8, // the team that won (Results; 0: none, a draw)
	sides:   u8, // sides playing
}

// Economy: one player's side, as only that player is told it.
Economy :: struct {
	team:       u8, // 0: watching
	stock:      [Resource]u32,
	supply:     u16, // used
	supply_cap: u16,
	lost:       bool,
}

// Side_Record (key: its team, as an entity key is any number): every side, for the scoreboard.
Side_Record :: struct {
	name:   string `net:"max=16"`,
	team:   u8,
	units:  u16,
	built:  u16, // buildings standing
	killed: u16, // foes its side killed
	wins:   u16, // matches won, kept with the universe
}

// Building_Record (key: the building's entity): what a building is and does, to the players
// who know it: its kind, how far built, what it trains and where they gather.
Building_Record :: struct {
	building: Building,
	built:    u8, // percent (100: standing)
	queue:    [MAX_QUEUE]Unit,
	queued:   u8,
	training: u8, // the first's percent
	rally:    [2]i16, // where its units go (x, z)
}

// Unit_Record (key: the unit's entity): what a unit is and carries, to the players who know
// it.
Unit_Record :: struct {
	unit:     Unit,
	carrying: u8, // a worker's load
	resource: Resource,
}

// Node_Record (key: the node's entity): what is left in a crystal outcrop or a grove.
Node_Record :: struct {
	resource: Resource,
	left:     u16,
}

// Shot: an archer's arrow or a tower's bolt (the client draws its streak).
Shot :: struct {
	from, to: [3]f32,
}

// ---- the requests (the client part's game_request; the server judges each) ----

// Order: units of the player's side told what to do (the ids beyond `count` are unused):
// to a point (`at`, a block column and its y), at a target entity, to build.
Order :: struct {
	kind:     Order_Kind,
	ids:      [MAX_ORDER_IDS]u32,
	count:    u8,
	target:   u32,
	at:       [3]i16,
	building: Building,
}

// Train: a unit of `unit` queued at building `at` (an entity id).
Train :: struct {
	at:   u32,
	unit: Unit,
}

// Rally: where the units a building trains gather.
Rally :: struct {
	at: u32,
	to: [2]i16,
}

@(private = "file")
check_order :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	return int((^Order)(v).count) <= MAX_ORDER_IDS
}

KINDS :: protocol.Game_Kinds {
	states   = {
		{name = "skirmish.match", value = Match},
		{name = "skirmish.economy", value = Economy},
		{name = "skirmish.side", value = Side_Record, key = .Entity, max_records = MAX_SIDES},
		{name = "skirmish.building", value = Building_Record, key = .Entity, max_records = 256},
		{name = "skirmish.unit", value = Unit_Record, key = .Entity, max_records = 512},
		{name = "skirmish.node", value = Node_Record, key = .Entity, max_records = 64},
	},
	events   = {{name = "skirmish.shot", value = Shot}},
	requests = {
		{name = "skirmish.order", value = Order, check = check_order},
		{name = "skirmish.train", value = Train},
		{name = "skirmish.rally", value = Rally},
	},
}
