package core

import "base:runtime"

import "common:game"
import "common:protocol"

// Sides: who is on whose side, and what a side sees. A player and an entity may be on a
// team (1 to MAX_TEAMS; 0: none, the default), set by the game (client_set_team,
// entity_set_team). The engine keeps teams apart where it decides alone:
//
//  - harm: nobody hurts their own side (a blow, a shot, a blast between two of a team is
//    no harm, before the game's harming hook is asked);
//  - looks: an entity whose kind has a look named `team<n>` shows the one of its team, so
//    an army's colour is its kind's data (packs.md);
//  - sight: in a world with fog (world_fog), a player on a team is told only of the
//    entities its team sees: its own, and the others within the vision (entity_set_vision)
//    of one of its own, wherever on the map they stand (entities_put). Another player's
//    place (its motion, its swings, its shots) is told by the same rule (player_seen). A
//    player on no team in a world with fog is on no side and sees for none: it is told of
//    what is on no team near it (neutral creatures, dropped stacks, other players on no
//    team) and of nothing a side has. Nothing it does not see reaches its client: the fog
//    is the server's, not a picture over what was sent.
//
// A team is not saved with the entity: a game whose sides outlive a restart keeps them in
// its own record and sets them again.

MAX_TEAMS :: protocol.MAX_TEAMS

// C_SIDE: an entity's Side (added the first time it is given a team or vision).
C_SIDE :: game.FIRST_SERVER_COMPONENT + 4

// Side: an entity's team and how far it sees.
Side :: struct {
	team:   u8, // 0: none
	vision: u8, // blocks (horizontally) it sees its team's foes within (0: none)
}

// Sight: the eyes of every team in a world with fog this tick, gathered once (sight_of).
Sight :: struct {
	tick: u64, // when it was gathered (0: never)
	eyes: [MAX_TEAMS + 1][dynamic]Eye, // by team (heap)
}

Eye :: struct {
	at:     [2]f64, // x, z
	vision: f64,
}

// client_set_team: the player's team (0: none). Told to nobody by the engine: a game says
// it in its own records.
client_set_team :: proc(c: ^Client, team: u8) {
	assert(int(team) <= MAX_TEAMS, "no such team")
	c.team = team
}

// client_team: the player's team (0: none).
client_team :: proc(c: ^Client) -> u8 {return c.team}

// entity_side: an entity's side, made when asked to (nil: it is gone).
@(private = "file")
entity_side :: proc(w: ^World, h: game.Entity_Handle, make_it: bool) -> ^Side {
	store := &w.entity_world.store
	if p := game.store_get(store, h, C_SIDE, Side); p != nil || !make_it {return p}
	if !entity_listed(w, h) {return nil}
	zero: Side
	if game.store_add(store, h, C_SIDE, &zero) != nil {return nil}
	game.store_apply(store)
	return game.store_get(store, h, C_SIDE, Side)
}

// entity_set_team: the entity's team (0: none), its `team<n>` look shown if its kind has
// one (and those of the other teams hidden).
entity_set_team :: proc(w: ^World, h: game.Entity_Handle, team: u8) {
	assert(int(team) <= MAX_TEAMS, "no such team")
	side := entity_side(w, h, true)
	if side == nil {return}
	side.team = team
	@(static, rodata)
	TEAM_LOOKS := [MAX_TEAMS + 1]string {
		"",
		"team1",
		"team2",
		"team3",
		"team4",
		"team5",
		"team6",
		"team7",
		"team8",
	}
	for look, t in TEAM_LOOKS[1:] {entity_show(w, h, look, t + 1 == int(team))}
}

// entity_team: the entity's team (0: none, or gone).
entity_team :: proc(w: ^World, h: game.Entity_Handle) -> u8 {
	side := entity_side(w, h, false)
	return side.team if side != nil else 0
}

// entity_set_vision: how far (blocks, horizontally, at most 255) the entity sees for its
// team in a world with fog.
entity_set_vision :: proc(w: ^World, h: game.Entity_Handle, vision: int) {
	if side := entity_side(w, h, true); side != nil {side.vision = u8(clamp(vision, 0, 255))}
}

// entity_vision: how far the entity sees (0: not at all).
entity_vision :: proc(w: ^World, h: game.Entity_Handle) -> int {
	side := entity_side(w, h, false)
	return int(side.vision) if side != nil else 0
}

// world_fog: whether the world's players on a team are told only of what their team sees.
world_fog :: proc(w: ^World, on: bool) {w.fog = on}

// same_side: both are on the same team (not none): no harm passes between them.
same_side :: proc(a, b: u8) -> bool {return a != 0 && a == b}

// harm_sides: the teams of who does a harm and who takes it (0: none).
harm_sides :: proc(h: Harming) -> (from, to: u8) {
	if h.by != nil {
		from = h.by.team
	} else if h.creature != 0 && h.world != nil {
		if e, ok := entity_find(h.world, h.creature); ok {from = entity_team(h.world, e)}
	}
	if h.to != nil {
		to = h.to.team
	} else if h.entity != 0 && h.world != nil {
		to = entity_team(h.world, h.entity)
	}
	return
}

// sight_destroy frees what a world gathered of its teams' eyes.
sight_destroy :: proc(sg: ^Sight) {
	for &eyes in sg.eyes {delete(eyes)}
	sg^ = {}
}

// sight_of: every team's eyes in the world this tick (gathered by the first who asks).
sight_of :: proc(w: ^World) -> ^Sight {
	sg := &w.sight
	if sg.tick == w.server.tick + 1 {return sg}
	if sg.tick == 0 {
		for &eyes in sg.eyes {eyes = make([dynamic]Eye, runtime.heap_allocator())}
	}
	sg.tick = w.server.tick + 1
	for &eyes in sg.eyes {clear(&eyes)}
	it := entities_each(w)
	for h in entities_next(&it) {
		side := entity_side(w, h, false)
		if side == nil || side.team == 0 || side.vision == 0 {continue}
		p := entity_pos(w, h)
		append(&sg.eyes[side.team], Eye{{p.x, p.z}, f64(side.vision)})
	}
	return sg
}

// team_sees: a team sees a point: one of its entities sees it (in a world with fog).
team_sees :: proc(w: ^World, team: u8, p: [3]f64) -> bool {
	if team == 0 {return false}
	for e in sight_of(w).eyes[team] {
		d := e.at - {p.x, p.z}
		if d.x * d.x + d.y * d.y <= e.vision * e.vision {return true}
	}
	return false
}

// entity_seen: whether a player on a team is told of an entity in a world with fog: its
// own side's, or one its team sees.
entity_seen :: proc(w: ^World, team: u8, h: game.Entity_Handle) -> bool {
	return entity_team(w, h) == team || team_sees(w, team, entity_pos(w, h))
}

// player_seen: whether viewer is told where other is (its motion, its swings and shots):
// always without fog; in a world with fog, when both are of one side (on no team: both on
// none) or viewer's team sees it. A bodiless player has no place to tell (players_put).
player_seen :: proc(viewer, other: ^Client) -> bool {
	w := viewer.world
	if !w.fog || viewer.team == other.team {return true}
	return team_sees(w, viewer.team, other.player.position)
}
