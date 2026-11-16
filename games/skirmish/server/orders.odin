package skirmish_server

import "common:game"
import "games:skirmish"
import "server:core"
import "server:play"

// Orders: what a side tells its units, buildings what to train and where to rally. A
// player's requests and the computer's choices both come here, and both are judged the
// same way: a unit not of the side, or gone, is not commanded (and counted, so a player is
// told); a cost not covered, a place a building does not fit, is refused.

// order_apply: the side's order carried out by each of its units it names; how many it
// named that were not its own (or not units).
order_apply :: proc(s: ^core.Server, side: ^Side, order: skirmish.Order) -> (refused: int) {
	w := s.home
	o := order
	units := make([dynamic]game.Entity_Handle, 0, int(o.count), context.temp_allocator)
	for id in o.ids[:min(int(o.count), skirmish.MAX_ORDER_IDS)] {
		h, ok := core.entity_find(w, id)
		m := mind(w, h) if ok else nil
		if m == nil || m.role != .Unit || core.entity_team(w, h) != side.team {
			refused += 1
			continue
		}
		append(&units, h)
	}
	if len(units) == 0 {return}
	at := game.Block_Pos{i32(o.at.x), i32(o.at.y), i32(o.at.z)}
	switch o.kind {
	case .Stop:
		for h in units {unit_send(s, h, .Stop, block_pos(block_of(core.entity_pos(w, h))), 0)}
	case .Move, .Attack_Move:
		group_send(s, units[:], o.kind, at)
	case .Attack:
		foe, ok := core.entity_find(w, o.target)
		if !ok || core.entity_team(w, foe) == side.team || core.entity_team(w, foe) == 0 {return}
		for h in units {unit_send(s, h, .Attack, at, o.target)}
	case .Gather:
		node, ok := core.entity_find(w, o.target)
		nm := mind(w, node) if ok else nil
		if nm == nil || nm.role != .Node {return}
		for h in units {
			if mind(w, h).unit != .Worker {continue}
			unit_send(s, h, .Gather, at, o.target)
			mind(w, h).resource = nm.resource
		}
	case .Build:
		if o.building not_in skirmish.BUILDABLE {return}
		workers := make([dynamic]game.Entity_Handle, context.temp_allocator)
		for h in units {if mind(w, h).unit == .Worker {append(&workers, h)}}
		if len(workers) == 0 {return}
		b := build(s, side, o.building, {at.x, at.z})
		if b == 0 {return}
		for h in workers {unit_send(s, h, .Build, at, core.entity_id(w, b))}
	}
	return
}

// group_send: a group sent to a point together, each to its own place around it (the
// nearest unit to the nearest place), every one following the same route.
group_send :: proc(
	s: ^core.Server,
	units: []game.Entity_Handle,
	kind: skirmish.Order_Kind,
	at: game.Block_Pos,
) {
	w := s.home
	goal := at
	if y, ok := floor_at(s, at.x, at.z); ok {goal.y = y}
	places := play.formation(s, w, goal, len(units))
	if len(places) == 0 {return}
	play.formation_assign(w, units, places)
	for h, i in units {unit_send(s, h, kind, places[min(i, len(places) - 1)], 0)}
}

// site: where a building of kind centred on a column would stand: its footprint's corner
// and floor, false when it does not fit (off the map, uneven or rough ground, something
// standing there).
site :: proc(
	s: ^core.Server,
	b: skirmish.Building,
	at: [2]i32,
) -> (
	corner: [2]i32,
	floor: i32,
	ok: bool,
) {
	w := s.home
	n := skirmish.BUILDINGS[b].size
	corner = skirmish.building_corner(b, at)
	if !skirmish.on_map(corner, n) {return}
	floor = floor_at(s, corner.x, corner.y) or_return
	for z in corner.y - 1 ..= corner.y + n {
		for x in corner.x - 1 ..= corner.x + n {
			// (the footprint level and clear, and a block round it to walk)
			if !play.standable(s, w, {x, floor, z}) {return}
		}
	}
	// No other building, node or unit in its way.
	middle := skirmish.building_middle(b, corner, floor)
	for e in core.entities_of(w, 0, middle, f64(n) + 3) {
		m := mind(w, e)
		if m == nil {continue}
		p := core.entity_pos(w, e)
		reach := f64(n) / 2 + 1
		if m.role != .Unit {reach += 1.5}
		if abs(p.x - middle.x) < reach && abs(p.z - middle.z) < reach {return}
	}
	return corner, floor, true
}

// build: a building begun for the side at a column, paid for; 0 when it cannot be (not
// covered, no room).
build :: proc(
	s: ^core.Server,
	side: ^Side,
	b: skirmish.Building,
	at: [2]i32,
) -> game.Entity_Handle {
	cost := skirmish.BUILDINGS[b].cost
	if !skirmish.can_afford(side.stock, cost) {return 0}
	corner, floor, fits := site(s, b, at)
	if !fits {return 0}
	h := building_raise(s, side, b, corner, floor, built = false)
	if h == 0 {return 0}
	for r in skirmish.Resource {side.stock[r] -= cost[r]}
	return h
}

// train: a unit queued at the side's building, paid for now; why not, or "".
train :: proc(s: ^core.Server, side: ^Side, at: u32, u: skirmish.Unit) -> string {
	w := s.home
	h, ok := core.entity_find(w, at)
	m := mind(w, h) if ok else nil
	if m == nil || m.role != .Building || core.entity_team(w, h) != side.team {
		return "That is not your building"
	}
	if !m.built {return "It is still being built"}
	if u not_in skirmish.BUILDINGS[m.building].trains {return "It does not train those"}
	if int(m.queued) >= skirmish.MAX_QUEUE {return "Its queue is full"}
	cost := skirmish.UNITS[u].cost
	if !skirmish.can_afford(side.stock, cost) {return "Not enough ore or wood"}
	for r in skirmish.Resource {side.stock[r] -= cost[r]}
	m.queue[m.queued] = u
	m.queued += 1
	return ""
}

// rally: where the side's building gathers what it trains.
rally :: proc(s: ^core.Server, side: ^Side, at: u32, to: [2]i32) {
	w := s.home
	h, ok := core.entity_find(w, at)
	m := mind(w, h) if ok else nil
	if m == nil || m.role != .Building || core.entity_team(w, h) != side.team {return}
	if to.x < 0 || to.y < 0 || to.x >= skirmish.MAP || to.y >= skirmish.MAP {return}
	m.rally = {i16(to.x), i16(to.y)}
}
