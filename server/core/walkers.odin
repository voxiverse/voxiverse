package core

import "base:runtime"
import "core:math"
import "core:slice"

import "common:base"
import "common:game"
import "server:path"

// Walkers a game steers: entities whose kind has `"brain": "steered"` (a walker
// with no mind of its own) stand until their game sends them somewhere, and then
// walk there by the shared body physics:
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
// each tick, from its tick or its creatures' mind (Game.think).

MAX_ROUTES :: 16 // routes a world holds at once
MAX_CHANGED_BOXES :: 64 // changed boxes kept a tick for the walkers (more: their bounds)
STUCK_TICKS :: game.TICK_RATE // a walker going nowhere this long plans again
ARRIVED :: 0.35 // blocks from its point (horizontally) a walker has arrived

// C_STEER: a steered walker's Steer (large: set at spawn).
C_STEER :: game.FIRST_SERVER_COMPONENT + 1

Route_Handle :: distinct u32

Steer_Mode :: enum u8 {
	Stand, // still, where it is
	Go, // to a point (target), by its own path
	Follow, // along a route
	Keep, // within a band of distances from a point: closer when further, away when nearer
	Glide, // along the points a game gave, over ground it knows is walkable: no physics (entity_glide)
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
	arrived: bool, // at its point, or at the route's goal (Keep: within its band)
	near:    f32, // Keep: the band, blocks from target (horizontally)
	far:     f32,
	planned: [3]f64, // the target its path was planned to (Keep plans again when it moved)
	ready:   int, // ticks until its attack is ready again
	struck:  int, // ticks its Striking look still shows
	shown:   [3]f64, // Glide: where its players are told it is (glide_shown)
	shown_y: f32, // ... and its yaw
}

// GLIDE_SEND_TICKS: a gliding walker's place is told its players every this many
// ticks (staggered by id): its legs are straight, and the client, drawing it between
// the places it was told, loses nothing of them, while a crowd costs a third.
GLIDE_SEND_TICKS :: 3

STRIKE_SHOW :: game.TICK_RATE / 3 // ticks a blow or a shot shows (the Striking look)
SEPARATION :: 2.5 // blocks a second at which walkers that overlap move apart

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

// entity_keep: the walker keeps within near..far blocks (horizontally) of target,
// facing it: it walks closer when further (straight on when it sees the point, else by
// its own path) and backs away when nearer. Chasing is keep(0, reach), keeping
// distance keep(range - 2, range), fleeing keep(radius, radius + 1). Called again with
// a moving target (a player's feet each tick), it plans again only when the target has
// moved off its path's end. False for an entity that is not a steered walker.
entity_keep :: proc(w: ^World, h: game.Entity_Handle, target: [3]f64, near, far: f32) -> bool {
	st := entity_steer(w, h)
	if st == nil {return false}
	if st.mode != .Keep {st.plan, st.path.count, st.step, st.stuck = true, 0, 0, 0}
	st.mode, st.target = .Keep, target
	st.near, st.far = max(near, 0), max(far, near, 0.1)
	return true
}

// entity_glide: the walker goes along points (the blocks it stands in, in order; at
// most path.MAX_PATH of them, the rest dropped) in straight legs at its speed, with no
// physics: no gravity, no collision, no push from others, nothing it can trip on. For
// the many simple walkers of a game that knows its ground (a town's citizens on its
// roads, a factory's carriers on its paths): the game finds the way (its own graph,
// route_cost) and the engine only moves them, at a fraction of a walker's cost. Arrived
// at the last point, it stands (entity_arrived). False for an entity that is not a
// steered walker, or no points.
entity_glide :: proc(w: ^World, h: game.Entity_Handle, points: []game.Block_Pos) -> bool {
	st := entity_steer(w, h)
	if st == nil || len(points) == 0 {return false}
	n := min(len(points), path.MAX_PATH)
	copy(st.path.steps[:n], points[:n])
	st.path.count, st.path.whole, st.step = n, true, 0
	if st.mode != .Glide {st.shown, st.shown_y = entity_pos(w, h), entity_yaw(w, h)}
	st.mode, st.arrived, st.stuck = .Glide, false, 0
	entity_set_velocity(w, h, {})
	return true
}

// glide_step: one tick along the points (system_steer).
@(private = "file")
glide_step :: proc(w: ^World, h: game.Entity_Handle, st: ^Steer, info: ^game.Kind_Info) {
	if st.arrived {return}
	left := f64(st.speed if st.speed > 0 else info.walker.walk_speed) * f64(game.TICK_SECONDS)
	pos := entity_pos(w, h)
	for left > 0 && st.step < st.path.count {
		b := st.path.steps[st.step]
		to := [3]f64{f64(b.x) + 0.5, f64(b.y), f64(b.z) + 0.5}
		d := to - pos
		l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
		if l > 1e-6 && (d.x != 0 || d.z != 0) {
			entity_set_yaw(w, h, f32(math.atan2(-d.x, -d.z)))
		}
		if l <= left {
			pos, left = to, left - l
			st.step += 1
			continue
		}
		pos += d * (left / l)
		left = 0
	}
	entity_set_pos(w, h, pos)
	if st.step >= st.path.count {st.arrived = true}
	if st.arrived || (w.server.tick + u64(entity_id(w, h))) % GLIDE_SEND_TICKS == 0 {
		st.shown, st.shown_y = pos, entity_yaw(w, h)
	}
}

// glide_shown: where a gliding walker is told to be (it moves every tick, its players
// are told every GLIDE_SEND_TICKS); false for one not gliding.
glide_shown :: proc(w: ^World, h: game.Entity_Handle) -> (pos: [3]f64, yaw: f32, ok: bool) {
	st := entity_steer(w, h)
	if st == nil || st.mode != .Glide {return}
	return st.shown, st.shown_y, true
}

// entity_gliding: the walker glides (entity_glide), so its body's physics is not run.
entity_gliding :: proc(w: ^World, h: game.Entity_Handle) -> bool {
	st := entity_steer(w, h)
	return st != nil && st.mode == .Glide
}

// entity_sees: nothing solid lies between the entity's eyes (near the top of its box)
// and p.
entity_sees :: proc(w: ^World, h: game.Entity_Handle, p: [3]f64) -> bool {
	info := kind_info_of(w, h)
	eye := entity_pos(w, h) + {0, f64(info.box[1]) * 0.85, 0}
	return sees(w, eye, p)
}

@(private)
sees :: proc(w: ^World, from, to: [3]f64) -> bool {
	d := to - from
	l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	if l < 1e-6 {return true}
	_, blocked := game.raycast(walk_query(w), from, d / l, l)
	return !blocked
}

// Target: what a creature attacks: a player, or another entity.
Target :: union {
	^Client,
	game.Entity_Handle,
}

// Strike: what an attack came to.
Strike :: enum u8 {
	Not_Ready, // its cooldown is still running (or it has no attack)
	Too_Far, // the target is out of its reach (or gone)
	Refused, // it landed and did nothing (the target cannot be hurt: protected, a mode...)
	Hit,
	Killed,
}

// entity_strike: the creature strikes at target with its kind's attack, if the attack
// is ready and the target within its reach (box to box): the damage its kind says (a
// game's harming hook may change it), credited to the creature; then it waits its
// cooldown, and shows the Striking look. A struck entity is knocked back as a
// player's blow knocks it.
entity_strike :: proc(w: ^World, h: game.Entity_Handle, target: Target) -> Strike {
	st := entity_steer(w, h)
	info := kind_info_of(w, h)
	a, fights := info.attack.?
	if st == nil || !fights || st.ready > 0 {return .Not_Ready}
	lo, hi := game.entity_box(info, entity_pos(w, h))
	tlo, thi: [3]f64
	switch v in target {
	case ^Client:
		if v == nil ||
		   v.world != w ||
		   v.state != .Playing ||
		   v.dead ||
		   bodiless(w.server, v) {return .Too_Far}
		tlo, thi = game.player_box(v.player)
	case game.Entity_Handle:
		if !entity_listed(w, v) || v == h {return .Too_Far}
		tlo, thi = game.entity_box(kind_info_of(w, v), entity_pos(w, v))
	}
	if box_gap(lo, hi, tlo, thi) > f64(a.reach) {return .Too_Far}
	attack_begin(w, h, st, a, (tlo + thi) / 2)
	id := entity_id(w, h)
	switch v in target {
	case ^Client:
		source := Damage_Source {
			kind     = .Hit,
			creature = id,
			kind_of  = entity_kind(w, h),
			pos      = entity_pos(w, h),
			placed   = true,
		}
		switch damage(w.server, v, a.damage, source) {
		case .Hurt:
			return .Hit
		case .Killed:
			return .Killed
		case .Ignored, .Blocked:
			return .Refused
		}
	case game.Entity_Handle:
		harm := Entity_Harm {
			amount   = max(int(math.round(a.damage)), 1),
			kind     = .Hit,
			creature = id,
		}
		return .Killed if entity_attack(w, v, entity_pos(w, h), harm) else .Hit
	}
	return .Refused
}

// entity_shoot: the creature shoots its kind's shot at p, if its attack is ready (the
// game judges range and sight: entity_sees): the projectile flies from its chest
// straight at p and hurts what it hits by the attack's damage, credited to the
// creature. False: not ready, or no shot, or the world is full.
entity_shoot :: proc(w: ^World, h: game.Entity_Handle, p: [3]f64) -> bool {
	st := entity_steer(w, h)
	info := kind_info_of(w, h)
	a, fights := info.attack.?
	if st == nil || !fights || a.shot == 0 || st.ready > 0 {return false}
	from := entity_pos(w, h) + {0, f64(info.box[1]) * 0.7, 0}
	d := p - from
	l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	if l < 1e-6 {return false}
	dir := d / l
	shot := entity_spawn(w, a.shot, from, false)
	if shot == 0 {return false}
	attack_begin(w, h, st, a, p)
	speed := game.kind_info(w.server.registry, a.shot).projectile.speed
	entity_set_velocity(w, shot, {f32(dir.x), f32(dir.y), f32(dir.z)} * speed)
	entity_set_look(w, shot, f32(math.atan2(-dir.x, -dir.z)), f32(math.asin(clamp(dir.y, -1, 1))))
	owner := entity_owner(w, shot)
	owner.entity, owner.damage = entity_id(w, h), a.damage
	return true
}

// attack_begin: the attack is spent: the cooldown starts, the look shows, it faces at.
@(private = "file")
attack_begin :: proc(
	w: ^World,
	h: game.Entity_Handle,
	st: ^Steer,
	a: game.Kind_Attack_Info,
	at: [3]f64,
) {
	st.ready = max(int(math.round(a.cooldown * game.TICK_RATE)), 1)
	st.struck = STRIKE_SHOW
	d := at - entity_pos(w, h)
	if d.x * d.x + d.z * d.z > 1e-6 {entity_set_yaw(w, h, f32(math.atan2(-d.x, -d.z)))}
}

// entity_striking: the creature struck or shot a moment ago (its Striking look).
entity_striking :: proc(w: ^World, h: game.Entity_Handle) -> bool {
	st := entity_steer(w, h)
	return st != nil && st.struck > 0
}

// shot_lands: a projectile that does not explode hit a player or an entity (what): the
// damage its owner gave it, credited to its shooter (a creature or a player).
shot_lands :: proc(w: ^World, h: game.Entity_Handle, what: Shot_Hit) {
	s := w.server
	owner := entity_owner(w, h)
	kind := entity_kind(w, h)
	shooter: Maybe(u16)
	if owner.client >= 0 &&
	   player_of(s, Player_Ref{u16(owner.client), owner.generation}) !=
		   nil {shooter = u16(owner.client)}
	from_kind: game.Kind_Id
	if owner.entity != 0 {
		if e, there := entity_find(w, owner.entity); there {from_kind = entity_kind(w, e)}
	}
	if what.player >= 0 && what.player < len(s.clients) {
		damage(
			s,
			&s.clients[what.player],
			owner.damage,
			{
				kind = .Weapon,
				attacker = shooter,
				creature = owner.entity,
				kind_of = from_kind,
				weapon = game.kind_name(game.kind_info(s.registry, kind)),
				pos = entity_pos(w, h),
				placed = true,
			},
		)
	} else if what.entity != 0 {
		if e, there := entity_find(w, what.entity); there {
			harm := Entity_Harm {
				amount   = max(int(math.round(owner.damage)), 1),
				kind     = .Weapon,
				creature = owner.entity,
				weapon   = game.kind_name(game.kind_info(s.registry, kind)),
			}
			if seat, set := shooter.?; set {harm.by = &s.clients[seat]}
			entity_attack(w, e, entity_pos(w, h), harm)
		}
	}
}

// box_gap: how far apart two boxes are (0: they touch or overlap).
@(private = "file")
box_gap :: proc(alo, ahi, blo, bhi: [3]f64) -> f64 {
	g: [3]f64
	for i in 0 ..< 3 {g[i] = max(blo[i] - ahi[i], alo[i] - bhi[i], 0)}
	return math.sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
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
		if st.mode == .Glide {
			glide_step(w, h, st, info)
			continue
		}
		body := path.body_of(info.box, info.walker.jump)
		if st.mode == .Go && !st.plan {
			for b in wk.changed {
				if path.crosses(&st.path, b.lo, b.hi, body) {
					st.plan = true
					break
				}
			}
		}
		if st.ready > 0 {st.ready -= 1}
		if st.struck > 0 {st.struck -= 1}
		wish, jump := steer_walk(w, h, st, info, body, query)
		wishes[h] = {wish + separation(w, h, info), jump}
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
	backing: bool // Keep: too near, it backs away
	switch st.mode {
	case .Stand, .Glide:
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
		ok: bool
		toward, ok = path_toward(w, st, pos, at, body, query)
		if !ok {return}
	case .Keep:
		d := st.target - pos
		flat := math.sqrt(d.x * d.x + d.z * d.z)
		if flat > 1e-6 {
			face := f32(math.atan2(-d.x, -d.z))
			entity_set_yaw(w, h, turn_towards(entity_yaw(w, h), face, 0.4))
		}
		st.arrived = flat >= f64(st.near) && flat <= f64(st.far)
		switch {
		case st.arrived:
			return
		case flat < f64(st.near):
			// Too near: straight back, away from it; backed against a wall, along it
			// (to one side or the other, by its id).
			away := [2]f64{-d.x, -d.z} / max(flat, 1e-6)
			if flat < 1e-6 {away = {1, 0}}
			if st.stuck > STUCK_TICKS / 4 {
				away = {-away.y, away.x} if entity_id(w, h) % 2 == 0 else {away.y, -away.x}
			}
			toward = pos + {away.x, 0, away.y}
			backing = true
		case abs(d.y) < 1.5 && sees(w, pos + {0, 0.5, 0}, st.target + {0, 0.5, 0}):
			// In sight on its own level: straight at it.
			toward = st.target
			st.plan = true // (a path, when it is out of sight again, starts afresh)
		case:
			moved := st.target - st.planned
			if moved.x * moved.x + moved.z * moved.z > 2 * 2 {st.plan = true}
			ok: bool
			toward, ok = path_toward(w, st, pos, at, body, query)
			if !ok {return}
		}
	}
	speed := st.speed if st.speed > 0 else info.walker.walk_speed
	to := [2]f64{toward.x - pos.x, toward.z - pos.z}
	dist := math.sqrt(to.x * to.x + to.y * to.y)
	if dist > 1e-6 {
		wish = {f32(to.x / dist), f32(to.y / dist)} * speed
		if st.mode != .Keep {
			entity_set_yaw(
				w,
				h,
				turn_towards(entity_yaw(w, h), f32(math.atan2(-to.x, -to.y)), 0.3),
			)
		}
	}
	vel := entity_velocity(w, h)
	blocked := entity_on_ground(w, h) && abs(vel.x) + abs(vel.z) < 0.1 * speed
	if blocked {st.stuck += 1} else {st.stuck = 0}
	// (backing away it does not jump at what it backs into: it slides along it)
	jump =
		entity_on_ground(w, h) && body.climb > 0 && (toward.y > pos.y + 0.5 || blocked) && !backing
	return
}

// path_toward: the block the walker heads for next on its way to st.target by its own
// path, planned again when wanted (a block changed on it, it ran out, it is stuck);
// false while it has no way (the budget is spent, or there is none).
@(private = "file")
path_toward :: proc(
	w: ^World,
	st: ^Steer,
	pos: [3]f64,
	at: game.Block_Pos,
	body: path.Body,
	query: game.Block_Query,
) -> (
	toward: [3]f64,
	ok: bool,
) {
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
	return toward, true
}

// separation: a walker overlapping another walker or a player moves out of it, at up
// to SEPARATION blocks a second (players are not pushed: their own clients move them).
@(private = "file")
separation :: proc(w: ^World, h: game.Entity_Handle, info: ^game.Kind_Info) -> (push: [2]f32) {
	pos := entity_pos(w, h)
	r := f64(info.box[0]) / 2
	near := make([dynamic]game.Entity_Id, context.temp_allocator)
	game.spatial_sphere(
		&w.entity_world.spatial,
		pos,
		r + 1 + ROCKET_REACH / 2,
		{all = {.Hittable}, exclude = game.Entity_Id(entity_id(w, h))},
		&near,
	)
	away :: proc(from, other: [3]f64, room: f64, salt: u32) -> [2]f32 {
		d := [2]f64{from.x - other.x, from.z - other.z}
		l := math.sqrt(d.x * d.x + d.y * d.y)
		if l >= room || abs(from.y - other.y) > 1.5 {return {}}
		if l < 1e-4 {
			// (one on top of another: apart by their ids, the same way every run)
			a := f64(salt % 16) * math.TAU / 16
			return {f32(base.cos(a)), f32(base.sin(a))} * SEPARATION
		}
		return {f32(d.x / l), f32(d.y / l)} * f32(1 - l / room) * SEPARATION
	}
	for id in near {
		other, there := entity_find(w, u32(id))
		if !there {continue}
		oinfo := kind_info_of(w, other)
		if oinfo.physics != .Walker {continue}
		push += away(pos, entity_pos(w, other), r + f64(oinfo.box[0]) / 2, u32(id))
	}
	for i in players_near(w, pos, r + 1, 2) {
		c := &w.server.clients[i]
		if c.dead {continue}
		push += away(pos, c.player.position, r + game.PLAYER_WIDTH / 2, entity_id(w, h))
	}
	return
}

// plan_way: a new path from at to the walker's point, within the tick's node
// budget; false when the budget is spent (it waits a tick) or
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
	st.planned = st.target
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
