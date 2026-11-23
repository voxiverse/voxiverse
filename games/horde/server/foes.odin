package horde_server

import "common:game"
import "games:horde"
import "server:core"
import "server:play"

// The horde: the run's crowd (play.Crowd: the base pack's hostile kinds, each with a slot
// and whom it hunts) in the home world. A creature goes for the nearest survivor
// standing, looking again every play.RETARGET ticks or when its prey goes down or leaves,
// and hunts it as every game's creatures do (play.hunt: the band of distances its kind
// keeps, its blow or its spit).

// foe_spawn: a creature of a kind at p, as tough as the wave; 0 when the slots or the
// world are full.
foe_spawn :: proc(s: ^core.Server, f: horde.Foe, p: [3]f64) -> game.Entity_Handle {
	return play.crowd_spawn(s, &state(s).crowd, s.home, f, p)
}

// foe_of: the slot of a creature by its entity id (nil: none of the game's).
foe_of :: proc(s: ^core.Server, id: u32) -> ^play.Foe_Slot {
	return play.crowd_find(&state(s).crowd, id)
}

// foe_forget: a creature's slot goes (it died, or is gone).
foe_forget :: proc(s: ^core.Server, id: u32) {play.crowd_forget(&state(s).crowd, id)}

// foes_clear: every creature goes, and none is to come (a run's end, everyone gone).
foes_clear :: proc(s: ^core.Server) {play.crowd_clear(&state(s).crowd, s.home)}

// foes_tick: every creature finds its prey, closes in and attacks.
foes_tick :: proc(s: ^core.Server) {play.crowd_tick(s, &state(s).crowd, s.home, standing)}

// standing: c plays the run and is not down.
standing :: proc(s: ^core.Server, c: ^core.Client) -> bool {
	return play.here(s, c) && !c.dead && !survivor(s, c).down && survivor(s, c).run == state(s).run
}
