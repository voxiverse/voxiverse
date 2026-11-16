package hamlet

import "common:game"
import "common:protocol"

// What Hamlet tells its players besides the engine's kinds (docs/games.md): the town
// (a singleton: its counts, its stock, its speed), each row of the map (its tiles and,
// on a house's tiles, how happy its people are), and each structure (what and where,
// its workers); and what the players ask of it, as requests the server checks.

// Town: the village as everyone sees it.
Town :: struct {
	population: u16,
	housing:    u16, // homes in houses with water
	jobs:       u16,
	workers:    u16, // citizens with a job
	stock:      [Good]u32,
	happiness:  u8, // 0 ..= 100, the mean of the citizens'
	speed:      u8, // the simulation's steps a tick (0: paused)
	day:        u32,
	milestone:  u8, // MILESTONES reached
	seed:       u32, // the map's
}

// Row: one row of the map (key: its z), its tiles from x 0 and how happy the people of
// a house's tiles are (0 ..= 100; 0 elsewhere).
Row :: struct {
	tiles: [MAP]Tile,
	happy: [MAP]u8,
}

// Structure_Record: a structure (key: its index): what, where (its lowest corner's
// tile and its floor's y), how it is turned, its workers.
Structure_Record :: struct {
	kind:     Kind,
	at:       [2]i16,
	floor:    i16,
	rotation: u8,
	workers:  u8,
	people:   u8, // a house's
}

// Milestone: the town grew past a milestone.
Milestone :: struct {
	population: u16,
}

// The requests (the client part's game_request; the server judges each).

// Lay_Road: a road along the tiles from `from` to `to` (an L: x first, road_path).
Lay_Road :: struct {
	from, to: [2]i16,
}

// Zone: the tiles of the rectangle zoned for homes (clear: unzoned).
Zone :: struct {
	from, to: [2]i16,
	clear:    bool,
}

// Build: a structure of kind with its lowest corner at tile `at`, turned rotation.
Build :: struct {
	kind:     Kind,
	at:       [2]i16,
	rotation: u8,
}

// Demolish: what stands on tile `at` (a road, a house, a building) goes, half its cost
// back.
Demolish :: struct {
	at: [2]i16,
}

// Set_Speed: the simulation's speed (0: paused, 1, 2 or 4).
Set_Speed :: struct {
	speed: u8,
}

@(private = "file")
check_build :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	b := (^Build)(v)
	return KINDS_INFO[b.kind].placed && b.rotation < 4
}

@(private = "file")
check_speed :: proc(reg: ^game.Registry, v: rawptr) -> bool {
	s := (^Set_Speed)(v).speed
	return s == 0 || s == 1 || s == 2 || s == 4
}

KINDS :: protocol.Game_Kinds {
	states   = {
		{name = "hamlet.town", value = Town},
		// (keyed by numbers of the game's own, a row, a structure: an Entity key is any u32)
		{name = "hamlet.row", value = Row, key = .Entity, max_records = MAP},
		{
			name = "hamlet.structure",
			value = Structure_Record,
			key = .Entity,
			max_records = MAX_STRUCTURES,
		},
	},
	events   = {{name = "hamlet.milestone", value = Milestone}},
	requests = {
		{name = "hamlet.lay_road", value = Lay_Road},
		{name = "hamlet.zone", value = Zone},
		{name = "hamlet.build", value = Build, check = check_build},
		{name = "hamlet.demolish", value = Demolish},
		{name = "hamlet.set_speed", value = Set_Speed, check = check_speed},
	},
}
