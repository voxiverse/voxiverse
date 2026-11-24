package game

import "common:starmap"

// The logbook (the Journal screen of the player menu; not the edit journal): what a
// character has found, kept with it (the server's player file) and
// sent to its player (the `logbook` record): the places (a gate it opened or arrived at, a
// game's places such as the sandbox's ruin), each in its world, the creature kinds that came
// into its view, and the worlds it has stood on. The server notes them (core.logbook_place,
// core.logbook_meet, core's logbook_world); the client shows them (the logbook's screen, the
// compass, the map, the gate's address).

LOGBOOK_PLACES :: 64
LOGBOOK_MET :: 64 // creature kinds a logbook remembers
LOGBOOK_WORLDS :: 16 // worlds a logbook remembers (past it the oldest is forgotten, never the home world)
PLACE_NAME_MAX :: 32
PLACE_SAME :: 24 // blocks: a place of a kind this near one already noted (in its world) is that one

// Logbook_Place_Kind: what kind of place a logbook's place is (its name when it has none of its own).
Logbook_Place_Kind :: enum u8 {
	Gate,
	Ruin,
	Town,
	Outpost,
	Beacon,
	Remains, // what is left of an older place (the sandbox's round its home gate)
	Settlement, // where people live (the sandbox's survivors' camps)
	Landmark, // a world's own great place (the sandbox's on the gate worlds)
}

// Logbook_Place: a place in a logbook (name_len 0: the kind's own name).
Logbook_Place :: struct {
	kind:     Logbook_Place_Kind,
	world:    starmap.Address,
	at:       [3]i32,
	name:     [PLACE_NAME_MAX]u8,
	name_len: u8,
}

// Logbook_World: a world a character has stood on: its address, its class
// (worldgen.World_Class's number; 0: none, as Earth and the home world are) and whether it
// is the universe's home world.
Logbook_World :: struct {
	world: starmap.Address,
	class: u8,
	home:  bool,
}

// Logbook: a character's places, the creature kinds it met and the worlds it stood on, in
// the order found.
Logbook :: struct {
	places:      [LOGBOOK_PLACES]Logbook_Place,
	place_count: u8,
	met:         [LOGBOOK_MET]Kind_Id,
	met_count:   u8,
	worlds:      [LOGBOOK_WORLDS]Logbook_World,
	world_count: u8,
}

// place_name: the place's own name ("" when it has none).
place_name :: proc(p: ^Logbook_Place) -> string {return string(
		p.name[:min(int(p.name_len), PLACE_NAME_MAX)],
	)}

// logbook_place notes a place: one of the same kind in the same world within PLACE_SAME
// blocks of one noted is that one (named anew when a name is given); past LOGBOOK_PLACES the
// oldest is forgotten. name: "" for the kind's own name. False when nothing changed.
logbook_place :: proc(
	j: ^Logbook,
	kind: Logbook_Place_Kind,
	world: starmap.Address,
	at: [3]i32,
	name := "",
) -> bool {
	p: ^Logbook_Place
	for &q in j.places[:j.place_count] {
		d := q.at - at
		if q.kind == kind &&
		   q.world == world &&
		   d.x * d.x + d.z * d.z <= PLACE_SAME * PLACE_SAME {p = &q}
	}
	if p != nil {
		if name == "" || place_name(p) == name {return false}
		p.name_len = u8(copy(p.name[:], name))
		return true
	}
	if j.place_count == LOGBOOK_PLACES {
		copy(j.places[:], j.places[1:])
		j.place_count -= 1
	}
	j.places[j.place_count] = {
		kind  = kind,
		world = world,
		at    = at,
	}
	j.places[j.place_count].name_len = u8(copy(j.places[j.place_count].name[:], name))
	j.place_count += 1
	return true
}

// logbook_meet notes a creature kind as met (once; past LOGBOOK_MET no more are noted). False
// when nothing changed.
logbook_meet :: proc(j: ^Logbook, kind: Kind_Id) -> bool {
	for k in j.met[:j.met_count] {if k == kind {return false}}
	if j.met_count == LOGBOOK_MET {return false}
	j.met[j.met_count] = kind
	j.met_count += 1
	return true
}

// logbook_world notes a world stood on (once: its class and whether it is home as now
// told); past LOGBOOK_WORLDS the oldest but the home world is forgotten. False when nothing
// changed.
logbook_world :: proc(j: ^Logbook, world: Logbook_World) -> bool {
	for &w in j.worlds[:j.world_count] {
		if w.world != world.world {continue}
		if w == world {return false}
		w = world
		return true
	}
	if j.world_count == LOGBOOK_WORLDS {
		gone := 0
		for j.worlds[gone].home {gone += 1}
		copy(j.worlds[gone:], j.worlds[gone + 1:])
		j.world_count -= 1
	}
	j.worlds[j.world_count] = world
	j.world_count += 1
	return true
}

// logbook_found_in: how many of the logbook's places are in world (what it found there).
logbook_found_in :: proc(j: ^Logbook, world: starmap.Address) -> int {
	n := 0
	for p in j.places[:j.place_count] {if p.world == world {n += 1}}
	return n
}

// logbook_valid: a logbook as the wire may carry it: its counts and names within their
// bounds, every place in the world and every kind met one the registry has.
logbook_valid :: proc(reg: ^Registry, j: ^Logbook) -> bool {
	if j.place_count > LOGBOOK_PLACES ||
	   j.met_count > LOGBOOK_MET ||
	   j.world_count > LOGBOOK_WORLDS {
		return false
	}
	for &p in j.places[:j.place_count] {
		if p.name_len > PLACE_NAME_MAX || int(p.kind) >= len(Logbook_Place_Kind) {return false}
		if !in_world(chunk_of(Block_Pos(p.at))) {return false}
	}
	for k in j.met[:j.met_count] {if kind_info(reg, k) == nil {return false}}
	return true
}
