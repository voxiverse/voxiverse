package game

import "common:starmap"

// The logbook (the Journal screen of the player menu; not the edit journal): what a
// character has found, kept with it (the server's player file) and
// sent to its player (the `logbook` record): the places (a gate it opened, a game's places
// such as the sandbox's ruin), each in its world, and the creature kinds that came into its
// view. The server notes them (core.logbook_place, core.logbook_meet); the client shows
// them (the logbook's screen, the compass, the map).

LOGBOOK_PLACES :: 64
LOGBOOK_MET :: 64 // creature kinds a logbook remembers
PLACE_NAME_MAX :: 32
PLACE_SAME :: 24 // blocks: a place of a kind this near one already noted (in its world) is that one

// Logbook_Place_Kind: what kind of place a logbook's place is (its name when it has none of its own).
Logbook_Place_Kind :: enum u8 {
	Gate,
	Ruin,
	Town,
	Outpost,
	Beacon,
}

// Logbook_Place: a place in a logbook (name_len 0: the kind's own name).
Logbook_Place :: struct {
	kind:     Logbook_Place_Kind,
	world:    starmap.Address,
	at:       [3]i32,
	name:     [PLACE_NAME_MAX]u8,
	name_len: u8,
}

// Logbook: a character's places and the creature kinds it met, in the order found.
Logbook :: struct {
	places:      [LOGBOOK_PLACES]Logbook_Place,
	place_count: u8,
	met:         [LOGBOOK_MET]Kind_Id,
	met_count:   u8,
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

// logbook_valid: a logbook as the wire may carry it: its counts and names within their
// bounds, every place in the world and every kind met one the registry has.
logbook_valid :: proc(reg: ^Registry, j: ^Logbook) -> bool {
	if j.place_count > LOGBOOK_PLACES || j.met_count > LOGBOOK_MET {return false}
	for &p in j.places[:j.place_count] {
		if p.name_len > PLACE_NAME_MAX || int(p.kind) >= len(Logbook_Place_Kind) {return false}
		if !in_world(chunk_of(Block_Pos(p.at))) {return false}
	}
	for k in j.met[:j.met_count] {if kind_info(reg, k) == nil {return false}}
	return true
}
