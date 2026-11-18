package play

import "core:math"
import "core:slice"

import "common:game"
import "server:core"
import "server:path"

// Squads: many steered walkers ordered together (a real-time strategy's army, a town's
// work gang, a horde's wave), built on the steering of docs/games.md ("Walkers"):
//
//  - Routes: one route (core.route_make: a field searched once for all who follow it) per
//    goal, kept in a cache that shares a goal's route between orders and lets the least
//    recently used go when the world holds core.MAX_ROUTES, so a game never runs out of
//    them. A block changed in the area searches the route again (the engine's).
//  - formation: the places around a goal a group stands at, one each, nearest first, on
//    ground a walker stands on: a hundred ordered to one point arrive around it, not on
//    top of each other.
//  - march: a walker's step towards its place: along the shared route while far, by its
//    own short path for the last blocks (so only the last few blocks cost a search each).
//  - foe_nearest and fight: a fighter finds the nearest living entity of another team
//    within its range and keeps within reach of it, striking (core.entity_strike), so an
//    army fights itself: acquiring, attack-moving and holding are the game's choice of
//    when to call them.

SQUAD_ROUTES :: 12 // routes a cache keeps at most (the world holds core.MAX_ROUTES)
MARCH_NEAR :: 6 // blocks from its place a marching walker leaves the route for its own path
MARCH_ARRIVED :: 0.6 // blocks from its place a walker has arrived

Squad_Route :: struct {
	route: core.Route_Handle,
	goal:  game.Block_Pos,
	kind:  game.Kind_Id,
	used:  u64, // the tick it was last asked for
}

// Routes: a world's cache of routes to goals over one area (the game's map).
Routes :: struct {
	area:  core.Box,
	cache: [SQUAD_ROUTES]Squad_Route,
	count: int,
}

// routes_get: the route to goal for walkers of kind, shared with whoever asked for the
// same goal before; made when there is none, the least recently used one let go when the
// cache or the world is full. False: there is no route to be had (a kind that is not a
// walker, an area too big).
routes_get :: proc(
	s: ^core.Server,
	w: ^core.World,
	rs: ^Routes,
	goal: game.Block_Pos,
	kind: game.Kind_Id,
) -> (
	core.Route_Handle,
	bool,
) {
	for &r in rs.cache[:rs.count] {
		if r.goal == goal && r.kind == kind {
			r.used = s.tick
			return r.route, true
		}
	}
	for _ in 0 ..< 2 {
		if rs.count < SQUAD_ROUTES {
			if h, ok := core.route_make(w, rs.area, goal, goal, kind); ok {
				rs.cache[rs.count] = {h, goal, kind, s.tick}
				rs.count += 1
				return h, true
			}
		}
		if rs.count == 0 {return 0, false}
		oldest := 0
		for r, i in rs.cache[:rs.count] {if r.used < rs.cache[oldest].used {oldest = i}}
		core.route_free(w, rs.cache[oldest].route)
		rs.cache[oldest] = rs.cache[rs.count - 1]
		rs.count -= 1
	}
	return 0, false
}

// routes_free lets every route of the cache go (a match's end).
routes_free :: proc(w: ^core.World, rs: ^Routes) {
	for r in rs.cache[:rs.count] {core.route_free(w, r.route)}
	rs.count = 0
}

// standable: a walker one block wide and two high stands in block p (path.standable:
// solid under it, nothing in it or over it, a block not loaded being solid).
standable :: proc(s: ^core.Server, w: ^core.World, p: game.Block_Pos) -> bool {
	read :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
		return core.block_at((^core.World)(data), p)
	}
	return path.standable({w, read, &s.registry.blocks, {}}, p, {1, 2, 0})
}

// ground_at: the block a walker stands in at column (x, z), searching from y down to
// y - depth and up to y + depth for the nearest that is standable.
ground_at :: proc(
	s: ^core.Server,
	w: ^core.World,
	x, y, z: i32,
	depth: i32 = 4,
) -> (
	game.Block_Pos,
	bool,
) {
	for d in i32(0) ..= depth {
		if standable(s, w, {x, y - d, z}) {return {x, y - d, z}, true}
		if d > 0 && standable(s, w, {x, y + d, z}) {return {x, y + d, z}, true}
	}
	return {}, false
}

// formation: n places around goal (the block a walker stands in), `spacing` blocks apart
// on a square spiral out from it, each on ground a walker stands on, nearest first (in
// the temp allocator; fewer when the ground runs out within a reach of n * spacing).
formation :: proc(
	s: ^core.Server,
	w: ^core.World,
	goal: game.Block_Pos,
	n: int,
	spacing: i32 = 1,
) -> []game.Block_Pos {
	out := make([dynamic]game.Block_Pos, 0, n, context.temp_allocator)
	if n <= 0 {return out[:]}
	step := max(spacing, 1)
	reach := i32(math.sqrt(f64(n))) + 4
	for ring in i32(0) ..= reach {
		for dz in -ring ..= ring {
			for dx in -ring ..= ring {
				if max(abs(dx), abs(dz)) != ring {continue}
				at, ok := ground_at(s, w, goal.x + dx * step, goal.y, goal.z + dz * step)
				if !ok {continue}
				append(&out, at)
				if len(out) == n {return out[:]}
			}
		}
	}
	return out[:]
}

// formation_assign: which place each walker takes (places[i] is units[i]'s, in place):
// the walkers sorted by their distance to the goal, the nearest given the nearest place,
// so the front of a column fills the middle and nobody crosses the whole crowd.
formation_assign :: proc(w: ^core.World, units: []game.Entity_Handle, places: []game.Block_Pos) {
	if len(places) == 0 {return}
	goal := places[0]
	g := [3]f64{f64(goal.x) + 0.5, f64(goal.y), f64(goal.z) + 0.5}
	Near :: struct {
		h: game.Entity_Handle,
		d: f64,
	}
	near := make([]Near, len(units), context.temp_allocator)
	for h, i in units {
		d := core.entity_pos(w, h) - g
		near[i] = {h, d.x * d.x + d.z * d.z}
	}
	slice.stable_sort_by(near, proc(a, b: Near) -> bool {return a.d < b.d})
	for n, i in near {units[i] = n.h}
}

// place_point: where a walker stands in block p (the bottom centre).
place_point :: proc(p: game.Block_Pos) -> [3]f64 {
	return {f64(p.x) + 0.5, f64(p.y), f64(p.z) + 0.5}
}

// march: one tick of a walker making for its place: along the route while further than
// MARCH_NEAR (and the route reaches it), by its own path for the rest; true once there
// (it stands).
march :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	place: game.Block_Pos,
	route: core.Route_Handle,
) -> bool {
	p := core.entity_pos(w, h)
	to := place_point(place)
	d := to - p
	far := math.sqrt(d.x * d.x + d.z * d.z)
	if far <= MARCH_ARRIVED {
		core.entity_stand(w, h)
		return true
	}
	at := game.Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y + 0.01)), i32(math.floor(p.z))}
	if far > MARCH_NEAR && route != 0 && core.route_reaches(w, route, at) {
		core.entity_follow(w, h, route)
	} else {
		core.entity_go(w, h, to)
	}
	return false
}

// foe_nearest: the nearest living entity within radius of h that is on a team other than
// its own (and on one: no team is nobody's foe), 0 for none.
foe_nearest :: proc(w: ^core.World, h: game.Entity_Handle, radius: f64) -> game.Entity_Handle {
	team := core.entity_team(w, h)
	if team == 0 {return 0}
	for e in core.entities_of(w, 0, core.entity_pos(w, h), radius) {
		other := core.entity_team(w, e)
		if other != 0 && other != team && core.entity_health_of(w, e) > 0 {return e}
	}
	return 0
}

// fight: one tick of a fighter at a foe: it keeps within its reach of it (closing in by
// its own path) and strikes when its attack is ready (core.entity_strike, its kind's
// damage and cooldown; whether it struck, and whether the foe died of it). reach: blocks
// between their boxes, its kind's attack's.
fight :: proc(w: ^core.World, h, foe: game.Entity_Handle, reach: f32) -> (struck, killed: bool) {
	core.entity_keep(w, h, core.entity_pos(w, foe), 0, reach + 0.4)
	#partial switch core.entity_strike(w, h, foe) {
	case .Hit:
		return true, false
	case .Killed:
		return true, true
	}
	return
}
