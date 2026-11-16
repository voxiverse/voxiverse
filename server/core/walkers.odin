package core

import "base:runtime"
import "core:math"
import "core:slice"

import "common:base"
import "common:game"
import "server:path"

// Walkers a game steers: entities whose kind has `"brain": "steered"` (a walker
// with no mind of its own) stand until their game sends them somewhere, and then
// walk there by the shared body physics, as a sheep walks its own way:
//
//  - entity_go: to a point, by A* (server/path) within the tick's node budget, the
//    way planned again when a changed block lies on it, when it runs out short of
//    the point, or when the walker is stuck;
//  - entity_follow: along a route, a field (path.Field) to one goal over an area the
//    game names, which every walker following it shares: one search for a whole wave.
//    A route whose area a block changes in is searched again before it is next used.
//
// route_would_shut answers whether a block placed somewhere would leave the route's
// start, or a walker following it, with no way: a tower defence refuses the wall
// that seals its maze, a city builder the house across its only road.
//
// The machinery is the engine's, not the game's: what a walker is (its box, its
// speed, whether it jumps) is its kind's data; what it does is the game's choice
// each tick. Sheep keep their own brain for now; this is the steering they would use.

MAX_ROUTES :: 16 // routes a world holds at once
MAX_CHANGED_BOXES :: 64 // changed boxes kept a tick for the walkers (more: their bounds)
STUCK_TICKS :: game.TICK_RATE // a walker going nowhere this long plans again
ARRIVED :: 0.35 // blocks from its point (horizontally) a walker has arrived

// C_STEER: a steered walker's Steer (large: set at spawn).
C_STEER :: game.FIRST_SERVER_COMPONENT + 2

Route_Handle :: distinct u32

Steer_Mode :: enum u8 {
	Stand, // still, where it is
	Go, // to a point (target), by its own path
	Follow, // along a route
}

Steer :: struct {
	mode:    Steer_Mode,
	target:  [3]f64, // Go: where to (the bottom centre of its box)
	route:   Route_Handle, // Follow
	path:    path.Path, // Go: the way planned
	step:    int, // the path's next block
	plan:    bool, // Go: a new way is wanted
	speed:   f32, // blocks a second (0: its kind's walk_speed)
	stuck:   int, // ticks without moving while it wants to
	arrived: bool, // at its point, or at the route's goal
}

// Route: a field to one goal over an area, for one body, searched again when a
// block in its area changed (dirty).
Route :: struct {
	area:  Box,
	start: game.Block_Pos, // where walkers set out (route_would_shut keeps its way)
	kind:  game.Kind_Id, // whose body it is made for
	field: path.Field,
	dirty: bool,
}

// Walkers: what a world keeps for its steered walkers (in Entities).
Walkers :: struct {
	routes:  base.Pool(Route, Route_Handle),
	changed: [dynamic]Box, // blocks changed since the walkers last looked (heap)
	builds:  int, // route searches made (a test counts them)
}

walkers_init :: proc(wk: ^Walkers) {
	base.pool_init(&wk.routes, MAX_ROUTES, runtime.heap_allocator())
	wk.changed = make([dynamic]Box, 0, MAX_CHANGED_BOXES, runtime.heap_allocator())
}

walkers_destroy :: proc(wk: ^Walkers) {
	it: base.Pool_Iterator
	for r in base.pool_next(&wk.routes, &it) {path.field_destroy(&r.field)}
	base.pool_destroy(&wk.routes)
	delete(wk.changed)
	wk^ = {}
}

// walkers_changed: the blocks lo..hi changed (set_block, bulk_edit): the routes over
// them are searched again before their next use, and the walkers whose way crosses
// them plan again (system_steer).
walkers_changed :: proc(w: ^World, lo, hi: game.Block_Pos) {
	wk := &w.entities.walkers
	it: base.Pool_Iterator
	for r in base.pool_next(&wk.routes, &it) {
		// (a block just outside matters too: a drop into the area, a step onto it)
		if box_overlaps(r.area, lo - {1, path.MAX_DROP + 1, 1}, hi + {1, 1, 1}) {r.dirty = true}
	}
	if len(wk.changed) < MAX_CHANGED_BOXES {
		append(&wk.changed, Box{lo, hi})
		return
	}
	last := &wk.changed[len(wk.changed) - 1]
	last.lo = {min(last.lo.x, lo.x), min(last.lo.y, lo.y), min(last.lo.z, lo.z)}
	last.hi = {max(last.hi.x, hi.x), max(last.hi.y, hi.y), max(last.hi.z, hi.z)}
}

// --- Routes -------------------------------------------------------------------

// route_make: a route over area (blocks; at most path.MAX_FIELD_BLOCKS of them) to
// goal (the block a walker stands in at the end), for walkers of kind, which set out
// from start. False when the world has MAX_ROUTES, the area is too big, or the kind
// is not a walker.
route_make :: proc(
	w: ^World,
	area: Box,
	start, goal: game.Block_Pos,
	kind: game.Kind_Id,
) -> (
	Route_Handle,
	bool,
) {
	info := game.kind_info(w.server.registry, kind)
	if info == nil || info.physics != .Walker {return 0, false}
	a := box_normal(area)
	r: Route
	if !path.field_make(&r.field, a.lo, a.hi, runtime.heap_allocator()) {return 0, false}
	r.area, r.start, r.kind, r.dirty = a, start, kind, true
	r.field.goal = goal
	h, _, ok := base.pool_add(&w.entities.walkers.routes, r)
	if !ok {
		path.field_destroy(&r.field)
		return 0, false
	}
	return h, true
}

// route_free: the route goes; its followers stand.
route_free :: proc(w: ^World, h: Route_Handle) {
	wk := &w.entities.walkers
	r := base.pool_get(&wk.routes, h)
	if r == nil {return}
	path.field_destroy(&r.field)
	base.pool_remove(&wk.routes, h)
}

// route_field: the route's field, searched again first if a block in its area
// changed; nil for a route that is gone.
@(private = "file")
route_field :: proc(w: ^World, h: Route_Handle) -> ^path.Field {
	wk := &w.entities.walkers
	r := base.pool_get(&wk.routes, h)
	if r == nil {return nil}
	if r.dirty {
		r.dirty = false
		path.field_build(&r.field, walk_query(w), r.field.goal, route_body(w, r))
		wk.builds += 1
	}
	return &r.field
}

@(private = "file")
route_body :: proc(w: ^World, r: ^Route) -> path.Body {
	info := game.kind_info(w.server.registry, r.kind)
	return path.body_of(info.box, info.walker.jump)
}

// route_cost: what the way to the route's goal costs from p (blocks walked, a
// climb or a drop a little more); false when there is no way from there.
route_cost :: proc(w: ^World, h: Route_Handle, p: game.Block_Pos) -> (f32, bool) {
	f := route_field(w, h)
	if f == nil {return 0, false}
	return path.field_cost(f, p)
}

// route_reaches: there is a way from p to the route's goal.
route_reaches :: proc(w: ^World, h: Route_Handle, p: game.Block_Pos) -> bool {
	_, ok := route_cost(w, h, p)
	return ok
}

// route_would_shut: block placed at p would leave the route's start, or a walker
// following it, with no way to its goal (asked before the block is placed; the
// route's own field is left as it was).
route_would_shut :: proc(
	w: ^World,
	h: Route_Handle,
	p: game.Block_Pos,
	block: game.Block,
) -> bool {
	f := route_field(w, h)
	if f == nil {return false}
	r := base.pool_get(&w.entities.walkers.routes, h)
	ask := path.With_Block{walk_query(w), p, block}
	trial: path.Field
	if !path.field_make(&trial, f.lo, f.hi, context.temp_allocator) {return false}
	path.field_trial(&trial, f, p, game.solid_at(path.with_block(&ask), p))
	if _, ok := path.field_cost(&trial, r.start); !ok {return true}
	body := f.body
	it := entities_each(w)
	for e in entities_next(&it) {
		st := entity_steer(w, e)
		if st == nil || st.mode != .Follow || st.route != h || st.arrived {continue}
		at := path.body_block(entity_pos(w, e), body)
		if _, had := path.field_cost(f, at); !had {continue} 	// (no way before either)
		if _, ok := path.field_cost(&trial, at); !ok {return true}
	}
	return false
}

// --- Steering -----------------------------------------------------------------

// entity_steer: a steered walker's Steer (nil for any other entity).
entity_steer :: proc(w: ^World, h: game.Entity_Handle) -> ^Steer {
	return game.store_get(&w.entity_world.store, h, C_STEER, Steer)
}

// entity_go: the walker heads for target (the bottom centre of its box there) by a
// path of its own; false for an entity that is not a steered walker.
entity_go :: proc(w: ^World, h: game.Entity_Handle, target: [3]f64) -> bool {
	st := entity_steer(w, h)
	if st == nil {return false}
	if st.mode == .Go && st.target == target && !st.arrived {return true}
	st.mode, st.target, st.plan, st.arrived, st.stuck = .Go, target, true, false, 0
	st.path.count, st.step = 0, 0
	return true
}

// entity_follow: the walker follows the route to its goal; false for an entity that
// is not a steered walker, or a route that is gone.
entity_follow :: proc(w: ^World, h: game.Entity_Handle, route: Route_Handle) -> bool {
	st := entity_steer(w, h)
	if st == nil || base.pool_get(&w.entities.walkers.routes, route) == nil {return false}
	st.mode, st.route, st.arrived, st.stuck = .Follow, route, false, 0
	return true
}

// entity_stand: the walker stops where it is.
entity_stand :: proc(w: ^World, h: game.Entity_Handle) {
	if st := entity_steer(w, h); st != nil {st.mode, st.arrived = .Stand, false}
}

// entity_arrived: the walker reached its point, or its route's goal.
entity_arrived :: proc(w: ^World, h: game.Entity_Handle) -> bool {
	st := entity_steer(w, h)
	return st != nil && st.arrived
}

// entity_set_speed: how fast the walker goes, blocks a second (0: its kind's
// walk_speed).
entity_set_speed :: proc(w: ^World, h: game.Entity_Handle, speed: f32) {
	if st := entity_steer(w, h); st != nil {st.speed = max(speed, 0)}
}

@(private = "file")
walk_query :: proc(w: ^World) -> game.Block_Query {
	return {&w.chunks, chunks_block, &w.server.registry.blocks, {}}
}

// system_steer: every steered walker's wish for the walkers' physics. The changed
// blocks of the tick are looked at once, first: a walker whose way crosses one plans
// again.
system_steer :: proc(w: ^World, wishes: ^map[game.Entity_Handle]Wish) {
	wk := &w.entities.walkers
	defer clear(&wk.changed)
	query := walk_query(w)
	it := entities_each(w)
	for h in entities_next(&it) {
		st := entity_steer(w, h)
		if st == nil || !chunk_ready(w, entity_pos(w, h)) {continue}
		info := kind_info_of(w, h)
		body := path.body_of(info.box, info.walker.jump)
		if st.mode == .Go && !st.plan {
			for b in wk.changed {
				if path.crosses(&st.path, b.lo, b.hi, body) {
					st.plan = true
					break
				}
			}
		}
		wish, jump := steer_walk(w, h, st, info, body, query)
		wishes[h] = {wish, jump}
	}
}

@(private = "file")
kind_info_of :: proc(w: ^World, h: game.Entity_Handle) -> ^game.Kind_Info {
	return game.kind_info(w.server.registry, entity_kind(w, h))
}

// steer_walk: the wished-for velocity and whether to jump, this tick.
@(private = "file")
steer_walk :: proc(
	w: ^World,
	h: game.Entity_Handle,
	st: ^Steer,
	info: ^game.Kind_Info,
	body: path.Body,
	query: game.Block_Query,
) -> (
	wish: [2]f32,
	jump: bool,
) {
	pos := entity_pos(w, h)
	at := path.body_block(pos, body)
	toward: [3]f64 // the centre of the block it goes to next
	switch st.mode {
	case .Stand:
		return
	case .Follow:
		f := route_field(w, st.route)
		if f == nil {
			st.mode = .Stand
			return
		}
		if at == f.goal {
			st.arrived = true
			return
		}
		next, ok := path.field_next(f, at)
		if !ok {
			// (between blocks, or no way: straight on to the goal's column if that is
			// where it was going, else wait for the way to open)
			return
		}
		toward = path.body_center(next, body)
	case .Go:
		d := st.target - pos
		if d.x * d.x + d.z * d.z < ARRIVED * ARRIVED && abs(d.y) < 1.5 {
			st.arrived = true
			return
		}
		st.arrived = false
		if st.plan || st.step >= st.path.count || st.stuck > STUCK_TICKS {
			if !plan_way(w, st, at, body, query) {return}
		}
		next := st.path.steps[st.step]
		toward = path.body_center(next, body)
		flat := toward - pos
		if flat.x * flat.x + flat.z * flat.z < 0.2 * 0.2 && abs(f64(next.y) - pos.y) < 0.6 {
			st.step += 1
			if st.step >= st.path.count {
				if !st.path.whole {st.plan = true}
				toward = st.target
			} else {
				toward = path.body_center(st.path.steps[st.step], body)
			}
		}
		if st.step >= st.path.count {toward = st.target}
	}
	speed := st.speed if st.speed > 0 else info.walker.walk_speed
	to := [2]f64{toward.x - pos.x, toward.z - pos.z}
	dist := math.sqrt(to.x * to.x + to.y * to.y)
	if dist > 1e-6 {
		wish = {f32(to.x / dist), f32(to.y / dist)} * speed
		entity_set_yaw(w, h, turn_towards(entity_yaw(w, h), f32(math.atan2(-to.x, -to.y)), 0.3))
	}
	vel := entity_velocity(w, h)
	blocked := entity_on_ground(w, h) && abs(vel.x) + abs(vel.z) < 0.1 * speed
	if blocked {st.stuck += 1} else {st.stuck = 0}
	jump = entity_on_ground(w, h) && body.climb > 0 && (toward.y > pos.y + 0.5 || blocked)
	return
}

// plan_way: a new path from at to the walker's point, within the tick's node
// budget (the sheep's too); false when the budget is spent (it waits a tick) or
// it stands nowhere a path starts.
@(private = "file")
plan_way :: proc(
	w: ^World,
	st: ^Steer,
	at: game.Block_Pos,
	body: path.Body,
	query: game.Block_Query,
) -> bool {
	e := &w.entities
	if e.budget < PATH_BUDGET_EACH {return false}
	goal := path.body_block(st.target, body)
	for dy in ([]i32{0, 1, -1, 2, -2}) {
		if path.standable(query, goal + {0, dy, 0}, body) {
			goal.y += dy
			break
		}
	}
	e.budget -= PATH_BUDGET_EACH
	found, ok := path.find(query, at, goal, PATH_BUDGET_EACH, body)
	st.plan, st.stuck, st.step = false, 0, 0
	if !ok {
		st.path.count = 0
		return false
	}
	st.path = found
	if found.count == 0 && found.whole {return false} 	// (there already)
	return found.count > 0
}

// entities_of: the entities of a kind (0: any) within radius of center, nearest
// first (ties: lowest id), in the temp allocator: what a tower's aim, an ogre's
// nose or a city's census asks.
entities_of :: proc(
	w: ^World,
	kind: game.Kind_Id,
	center: [3]f64,
	radius: f64,
) -> []game.Entity_Handle {
	ids := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&w.entity_world.spatial,
		center,
		radius + ROCKET_REACH, // (the boxes are where they stood at the end of the last tick)
		{kind = u16(kind), none = {.Player}},
		&ids,
	)
	Near :: struct {
		h:  game.Entity_Handle,
		id: u32,
		d:  f64,
	}
	near := make([dynamic]Near, context.temp_allocator)
	for id in ids {
		h, ok := entity_find(w, u32(id))
		if !ok {continue}
		d := entity_pos(w, h) - center
		dd := d.x * d.x + d.y * d.y + d.z * d.z
		if dd <= radius * radius {append(&near, Near{h, u32(id), dd})}
	}
	slice.sort_by(
		near[:],
		proc(a, b: Near) -> bool {return a.d < b.d || (a.d == b.d && a.id < b.id)},
	)
	out := make([]game.Entity_Handle, len(near), context.temp_allocator)
	for n, i in near {out[i] = n.h}
	return out
}

// entity_set_max_health: the entity's most health, and its health now, both
// `health` (a game's wave makes its creeps tougher).
entity_set_max_health :: proc(w: ^World, h: game.Entity_Handle, health: int) {
	if hp := entity_health(w, h); hp != nil {
		hp.max = i32(max(health, 1))
		hp.health = hp.max
	}
}

// entity_max_health: the most health the entity has (its kind's, unless a game set it).
entity_max_health :: proc(w: ^World, h: game.Entity_Handle) -> int {
	if hp := entity_health(w, h); hp != nil {return int(hp.max)}
	return 0
}
