package skirmish_server

import "core:math"

import "common:game"
import "games:skirmish"
import "server:core"
import "server:play"

// The units, the buildings and the nodes as the game's records on its entities (Mind, the
// game's entity_data), and their life each tick. A unit carries out its order: it marches
// to its place in its group (play.march: the order's route, shared), fights (play.fight)
// what it is told to or, on an attack-move or standing, the nearest foe within its sight;
// a worker walks between its node and the nearest drop-off, or to the building it puts up.
// A building trains what is queued at it while its side has room, gathers the trained at
// its rally point, and a tower shoots the nearest foe in reach.

Role :: enum u8 {
	Unit,
	Building,
	Node,
}

// Mind: the game's record on each of its entities (game.MAX_ENTITY_DATA at most).
Mind :: struct {
	target:   u32, // Attack: the foe; Gather: the node; Build: the building
	foe:      u32, // the foe it fights now (0: none)
	place:    [3]i16, // where its order sends it (its place in its group)
	rally:    [2]i16, // a building's
	work:     u16, // a worker's ticks at its node; a building's ticks built
	left:     u16, // a node's
	training: u16, // a building's ticks into the first queued
	queue:    [skirmish.MAX_QUEUE]skirmish.Unit,
	queued:   u8,
	carrying: u8,
	look:     u8, // ticks to its next look for a foe
	role:     Role,
	unit:     skirmish.Unit,
	building: skirmish.Building,
	order:    skirmish.Order_Kind,
	resource: skirmish.Resource,
	built:    bool, // a building's: standing (not being put up)
	arrived:  bool, // at its place
	route:    core.Route_Handle,
}

#assert(size_of(Mind) <= game.MAX_ENTITY_DATA)

LOOK_TICKS :: 6 // ticks between a unit's looks for a foe (staggered by its id)
NODE_REACH :: 2.2 // blocks from a node's middle a worker works it within
DROP_REACH :: 1.6 // blocks from a building's edge a worker leaves its load within
BUILD_REACH :: 1.6 // ... and puts it up within

mind :: proc(w: ^core.World, h: game.Entity_Handle) -> ^Mind {return core.entity_data(w, h, Mind)}

block_of :: proc(p: [3]f64) -> [3]i16 {return {
		i16(math.floor(p.x)),
		i16(math.floor(p.y + 0.01)),
		i16(math.floor(p.z)),
	}}

block_pos :: proc(p: [3]i16) -> game.Block_Pos {return {i32(p.x), i32(p.y), i32(p.z)}}

// unit_spawn: a unit of the side's standing in block p, its team, sight and record set.
unit_spawn :: proc(
	s: ^core.Server,
	side: ^Side,
	u: skirmish.Unit,
	p: game.Block_Pos,
) -> game.Entity_Handle {
	g := state(s)
	w := s.home
	h := core.entity_spawn(w, g.units[u], play.place_point(p), false)
	if h == 0 {return 0}
	core.entity_set_team(w, h, side.team)
	core.entity_set_vision(w, h, skirmish.UNITS[u].vision)
	m := mind(w, h)
	m.role, m.unit, m.order = .Unit, u, .Stop
	m.place = {i16(p.x), i16(p.y), i16(p.z)}
	m.look = u8(core.entity_id(w, h) % LOOK_TICKS)
	return h
}

// building_raise: a building of the side's with its footprint's lowest corner at `corner`
// on the floor y: its blocks placed, its entity (flag, health, sight) in the middle; built
// (standing) or just begun, its health growing as workers put it up.
building_raise :: proc(
	s: ^core.Server,
	side: ^Side,
	b: skirmish.Building,
	corner: [2]i32,
	floor: i32,
	built: bool,
) -> game.Entity_Handle {
	g := state(s)
	w := s.home
	act := core.game_act(s, w, .Structure)
	core.structure_place(w, &g.templates[b], {corner.x, floor, corner.y}, 0, act)
	h := core.entity_spawn(w, g.buildings[b], skirmish.building_middle(b, corner, floor), false)
	if h == 0 {return 0}
	core.entity_set_team(w, h, side.team)
	core.entity_set_vision(w, h, skirmish.BUILDINGS[b].vision)
	m := mind(w, h)
	m.role, m.building, m.built = .Building, b, built
	n := i32(skirmish.BUILDINGS[b].size)
	m.rally = {i16(corner.x + n / 2), i16(corner.y + n + 1)}
	if !built {
		// (it starts a tenth whole and grows with the work: build_step)
		most := core.entity_max_health(w, h)
		core.entity_harm(w, h, {amount = most - most / 10, kind = .Game})
	}
	return h
}

// building_footprint: the corner and floor of a building's entity.
building_footprint :: proc(
	w: ^core.World,
	h: game.Entity_Handle,
	b: skirmish.Building,
) -> (
	corner: [2]i32,
	floor: i32,
) {
	p := core.entity_pos(w, h)
	n := f64(skirmish.BUILDINGS[b].size)
	return {i32(math.round(p.x - n / 2)), i32(math.round(p.z - n / 2))}, i32(math.round(p.y))
}

building_record :: proc(m: ^Mind) -> skirmish.Building_Record {
	r := skirmish.Building_Record {
		building = m.building,
		queue    = m.queue,
		queued   = m.queued,
		rally    = m.rally,
		built    = 100,
	}
	if !m.built {
		r.built = u8(clamp(f32(m.work) / build_ticks(m.building) * 100, 0, 99))
	}
	if m.queued > 0 {
		r.training = u8(clamp(f32(m.training) / train_ticks(m.queue[0]) * 100, 0, 100))
	}
	return r
}

build_ticks :: proc(b: skirmish.Building) -> f32 {return(
		skirmish.BUILDINGS[b].seconds *
		game.TICK_RATE \
	)}
train_ticks :: proc(u: skirmish.Unit) -> f32 {return skirmish.UNITS[u].seconds * game.TICK_RATE}

// units_tick: every side's supply and counts, then every entity of the game's its turn.
units_tick :: proc(s: ^core.Server) {
	g := state(s)
	w := s.home
	for &side in g.sides {side.supply, side.cap, side.units, side.built = 0, 0, 0, 0}
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		m := mind(w, h)
		if m == nil || m.role == .Node {continue}
		side := side_team(s, core.entity_team(w, h))
		if side == nil {continue}
		switch m.role {
		case .Unit:
			side.supply += skirmish.UNITS[m.unit].supply
			side.units += 1
		case .Building:
			if m.built {
				side.cap += skirmish.BUILDINGS[m.building].supply
				side.built += 1
			}
		case .Node:
		}
	}
	for &side in g.sides {side.cap = min(side.cap, skirmish.SUPPLY_LIMIT)}
	it = core.entities_each(w)
	for h in core.entities_next(&it) {
		m := mind(w, h)
		if m == nil {continue}
		switch m.role {
		case .Unit:
			unit_step(s, h, m)
		case .Building:
			building_step(s, h, m)
		case .Node:
		}
	}
}

// building_step: a standing building trains what is queued; a tower shoots.
building_step :: proc(s: ^core.Server, h: game.Entity_Handle, m: ^Mind) {
	w := s.home
	if !m.built {return}
	side := side_team(s, core.entity_team(w, h))
	if side == nil || side.lost {return}
	if m.queued > 0 {
		u := m.queue[0]
		if m.training < u16(train_ticks(u)) {
			m.training += 1
		} else if side.supply + skirmish.UNITS[u].supply <= side.cap {
			if trained(s, side, h, m, u) {
				copy(m.queue[:], m.queue[1:m.queued])
				m.queued -= 1
				m.training = 0
			}
		}
	}
	if m.building == .Tower {
		if m.look > 0 {
			m.look -= 1
			return
		}
		foe := play.foe_nearest(w, h, skirmish.TOWER_REACH)
		if foe == 0 {return}
		m.look = skirmish.TOWER_COOLDOWN
		from := core.entity_pos(w, h) + {0, 4, 0}
		shot_shown(s, from, core.entity_pos(w, foe) + {0, 1, 0})
		core.entity_harm(
			w,
			foe,
			{
				amount = skirmish.TOWER_DAMAGE,
				kind = .Game,
				creature = core.entity_id(w, h),
				from = from,
			},
		)
	}
}

// trained: a unit of the side's out of the building's door, sent to its rally point.
trained :: proc(
	s: ^core.Server,
	side: ^Side,
	h: game.Entity_Handle,
	m: ^Mind,
	u: skirmish.Unit,
) -> bool {
	w := s.home
	corner, floor := building_footprint(w, h, m.building)
	n := skirmish.BUILDINGS[m.building].size
	door, ok := play.ground_at(s, w, corner.x + n / 2, floor, corner.y + n, 3)
	if !ok {door, ok = play.ground_at(s, w, corner.x + n / 2, floor, corner.y - 1, 3)}
	if !ok {return false}
	e := unit_spawn(s, side, u, door)
	if e == 0 {return false}
	rally := game.Block_Pos{i32(m.rally.x), floor, i32(m.rally.y)}
	if y, standing := floor_at(s, rally.x, rally.z); standing {rally.y = y}
	if rally != door {unit_send(s, e, .Move, rally, 0)}
	return true
}

// unit_send: one unit's order (order_apply gives each of a group its place).
unit_send :: proc(
	s: ^core.Server,
	h: game.Entity_Handle,
	kind: skirmish.Order_Kind,
	place: game.Block_Pos,
	target: u32,
) {
	w := s.home
	g := state(s)
	m := mind(w, h)
	m.order, m.target, m.foe, m.arrived = kind, target, 0, false
	m.place = {i16(place.x), i16(place.y), i16(place.z)}
	m.route = 0
	if kind == .Move || kind == .Attack_Move {
		m.route, _ = play.routes_get(s, w, &g.routes, place, core.entity_kind(w, h))
	}
}

// unit_step: one tick of a unit's order.
unit_step :: proc(s: ^core.Server, h: game.Entity_Handle, m: ^Mind) {
	w := s.home
	info := skirmish.UNITS[m.unit]
	// Looking for a foe (staggered): standing, attack-moving, or there and done.
	looks := m.order == .Stop || m.order == .Attack_Move || (m.order == .Move && m.arrived)
	if m.unit == .Worker {looks = m.order == .Stop}
	if m.foe != 0 {
		if foe, ok := core.entity_find(w, m.foe);
		   !ok || core.entity_health_of(w, foe) <= 0 {m.foe = 0}
	}
	if looks && info.sight > 0 {
		if m.look == 0 {
			m.look = LOOK_TICKS
			if foe := play.foe_nearest(w, h, info.sight); foe != 0 {m.foe = core.entity_id(w, foe)}
		}
		m.look -= 1
	}
	if m.foe != 0 && looks {
		foe, _ := core.entity_find(w, m.foe)
		strike(s, h, foe, info.reach)
		return
	}
	switch m.order {
	case .Stop:
		core.entity_stand(w, h)
	case .Move, .Attack_Move:
		if !m.arrived {m.arrived = play.march(w, h, block_pos(m.place), m.route)}
	case .Attack:
		foe, ok := core.entity_find(w, m.target)
		if !ok || core.entity_health_of(w, foe) <= 0 || core.entity_team(w, foe) == 0 {
			m.order = .Stop
			return
		}
		strike(s, h, foe, info.reach)
	case .Gather:
		gather_step(s, h, m)
	case .Build:
		build_step(s, h, m)
	}
}

// strike: a fighter at a foe; an archer's blow shows as a shot.
strike :: proc(s: ^core.Server, h, foe: game.Entity_Handle, reach: f32) {
	w := s.home
	struck, _ := play.fight(w, h, foe, reach)
	if struck && mind(w, h).unit == .Archer {
		shot_shown(s, core.entity_pos(w, h) + {0, 1.3, 0}, core.entity_pos(w, foe) + {0, 0.9, 0})
	}
}

// shot_shown: a streak from one point to another, to the players who see either end.
shot_shown :: proc(s: ^core.Server, from, to: [3]f64) {
	shot := skirmish.Shot {
		{f32(from.x), f32(from.y), f32(from.z)},
		{f32(to.x), f32(to.y), f32(to.z)},
	}
	for &c in s.clients {
		if c.state != .Playing || c.world != s.home {continue}
		team := core.client_team(&c)
		if team != 0 &&
		   !core.team_sees(s.home, team, from) &&
		   !core.team_sees(s.home, team, to) {continue}
		core.game_event(s, &c, &shot)
	}
}

// gather_step: a worker between its node and the nearest drop-off of its side.
gather_step :: proc(s: ^core.Server, h: game.Entity_Handle, m: ^Mind) {
	w := s.home
	if m.carrying >= skirmish.CARRY {
		drop, ok := drop_off(s, h)
		if !ok {
			core.entity_stand(w, h)
			return
		}
		dm := mind(w, drop)
		if building_gap(w, h, drop, dm.building) <= DROP_REACH {
			side := side_team(s, core.entity_team(w, h))
			if side != nil {side.stock[m.resource] += int(m.carrying)}
			m.carrying = 0
			return
		}
		core.entity_go(w, h, core.entity_pos(w, drop))
		return
	}
	node, ok := core.entity_find(w, m.target)
	if !ok || mind(w, node) == nil || mind(w, node).left == 0 {
		// The node is spent: the nearest of the same within reach, else back with what it has.
		next := node_nearest(s, core.entity_pos(w, h), m.resource, 24)
		if next == 0 {
			if m.carrying > 0 {m.carrying = skirmish.CARRY} else {m.order = .Stop}
			return
		}
		m.target = core.entity_id(w, next)
		return
	}
	nm := mind(w, node)
	p, np := core.entity_pos(w, h), core.entity_pos(w, node)
	if field_distance({p.x, p.z}, {np.x, np.z}) > NODE_REACH {
		core.entity_go(w, h, np)
		return
	}
	core.entity_stand(w, h)
	m.resource = nm.resource
	m.work += 1
	if m.work < skirmish.GATHER_TICKS {return}
	m.work = 0
	take := min(u16(skirmish.CARRY), nm.left)
	nm.left -= take
	m.carrying = u8(take) if take == skirmish.CARRY else skirmish.CARRY
	if nm.left == 0 {core.entity_gone(w, node)}
}

// node_nearest: the nearest node of a resource with something left (0: none within reach).
node_nearest :: proc(
	s: ^core.Server,
	p: [3]f64,
	resource: skirmish.Resource,
	reach: f64,
) -> game.Entity_Handle {
	g := state(s)
	kind := g.crystal if resource == .Ore else g.grove
	for e in core.entities_of(s.home, kind, p, reach) {
		if m := mind(s.home, e); m != nil && m.left > 0 {return e}
	}
	return 0
}

// drop_off: the nearest standing headquarters or depot of the worker's side.
drop_off :: proc(s: ^core.Server, h: game.Entity_Handle) -> (game.Entity_Handle, bool) {
	w := s.home
	team := core.entity_team(w, h)
	best, found := f64(1e18), game.Entity_Handle(0)
	p := core.entity_pos(w, h)
	for e in core.entities_of(w, 0, p, skirmish.MAP) {
		m := mind(w, e)
		if m == nil || m.role != .Building || !m.built || core.entity_team(w, e) != team {continue}
		if m.building != .Headquarters && m.building != .Depot {continue}
		q := core.entity_pos(w, e)
		if d := field_distance({p.x, p.z}, {q.x, q.z}); d < best {best, found = d, e}
	}
	return found, found != 0
}

// building_gap: blocks between a unit and a building's footprint (horizontally).
building_gap :: proc(w: ^core.World, h, b: game.Entity_Handle, kind: skirmish.Building) -> f64 {
	p, q := core.entity_pos(w, h), core.entity_pos(w, b)
	half := f64(skirmish.BUILDINGS[kind].size) / 2
	dx := max(abs(p.x - q.x) - half, 0)
	dz := max(abs(p.z - q.z) - half, 0)
	return math.sqrt(dx * dx + dz * dz)
}

// build_step: a worker puts up its building; standing, the worker goes back to stand.
build_step :: proc(s: ^core.Server, h: game.Entity_Handle, m: ^Mind) {
	w := s.home
	b, ok := core.entity_find(w, m.target)
	bm := mind(w, b) if ok else nil
	if bm == nil || bm.built {
		m.order = .Stop
		return
	}
	if building_gap(w, h, b, bm.building) > BUILD_REACH {
		core.entity_go(w, h, approach(s, h, b, bm.building))
		return
	}
	core.entity_stand(w, h)
	bm.work += 1
	most := core.entity_max_health(w, b)
	grow := max(int(f32(most) * 0.9 / build_ticks(bm.building)), 1)
	core.entity_heal(w, b, grow)
	if f32(bm.work) >= build_ticks(bm.building) {bm.built = true}
}

// approach: the point of the ground by a building's footprint nearest the unit.
approach :: proc(s: ^core.Server, h, b: game.Entity_Handle, kind: skirmish.Building) -> [3]f64 {
	w := s.home
	p, q := core.entity_pos(w, h), core.entity_pos(w, b)
	half := f64(skirmish.BUILDINGS[kind].size) / 2 + 0.8
	at := [3]f64{clamp(p.x, q.x - half, q.x + half), q.y, clamp(p.z, q.z - half, q.z + half)}
	if abs(at.x - q.x) < half && abs(at.z - q.z) < half {at.z = q.z + half}
	return at
}

// harming: a ram's blow tells on a building; a soldier's or an archer's less so.
harming :: proc(s: ^core.Server, harm: ^core.Harming) {
	w := harm.world
	if w == nil || harm.entity == 0 || harm.creature == 0 {return}
	target := mind(w, harm.entity)
	by, ok := core.entity_find(w, harm.creature)
	if !ok || target == nil || target.role != .Building {return}
	striker := mind(w, by)
	if striker == nil || striker.role != .Unit {return}
	if striker.unit == .Ram {
		harm.amount *= skirmish.RAM_AGAINST_BUILDINGS
	} else {
		harm.amount *= skirmish.BUILDING_ARMOUR
	}
}

// entity_died: a building's blocks come down with it; a side counts its kills.
entity_died :: proc(
	s: ^core.Server,
	w: ^core.World,
	dead: core.Dead_Entity,
	harm: core.Entity_Harm,
) {
	g := state(s)
	if w != s.home {return}
	for kind, b in g.buildings {
		if kind != dead.kind {continue}
		n := f64(skirmish.BUILDINGS[b].size)
		corner := [2]i32 {
			i32(math.round(dead.position.x - n / 2)),
			i32(math.round(dead.position.z - n / 2)),
		}
		act := core.game_act(s, w, .Structure)
		core.structure_remove(
			w,
			&g.templates[b],
			{corner.x, i32(math.round(dead.position.y)), corner.y},
			0,
			act,
		)
	}
	if harm.creature == 0 {return}
	by, ok := core.entity_find(w, harm.creature)
	if !ok {return}
	if side := side_team(s, core.entity_team(w, by)); side != nil {side.killed += 1}
}
