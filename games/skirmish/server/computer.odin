package skirmish_server

import "common:game"
import "games:skirmish"
import "server:core"

// The computer opponent: a simple, honest script for each side no player takes. Every two
// seconds it looks at its own side alone (what the server tells a player of its side: its
// stock, its units, its buildings), and gives its orders through order_apply, train and
// build, as a player's requests do: no free stock, no sight through the fog. It keeps its
// workers gathering (the resource it has less of), trains workers up to a count, puts up
// its buildings in a fixed order by its headquarters, trains soldiers and archers (and
// rams once it has a workshop), and when its army reaches the wave's size it sends all of
// it to attack-move on the nearest corner it does not hold (where a side starts: the map
// is no secret), each wave larger than the last.

COMPUTER_EVERY :: 2 * game.TICK_RATE // ticks between its looks
COMPUTER_WORKERS :: 8
@(rodata)
BUILD_ORDER := [?]skirmish.Building {
	.Depot,
	.Barracks,
	.Tower,
	.Depot,
	.Workshop,
	.Barracks,
	.Depot,
}
WAVE_GROWTH :: 3 // units more in each wave

Computer :: struct {
	wave:    int, // the army it waits for before it attacks
	next:    int, // the step of BUILD_ORDER it is at
	waves:   int, // waves sent
	archers: bool, // the next unit a barracks trains is an archer
}

computers_tick :: proc(s: ^core.Server) {
	g := state(s)
	for &side, i in g.sides {
		if side.team == 0 || side.human || side.lost {continue}
		if (s.tick + u64(i) * 7) % COMPUTER_EVERY != 0 {continue}
		computer_think(s, &side)
	}
}

// Own: what a side has, as it is told it.
Own :: struct {
	workers, idle_workers, army: [dynamic]game.Entity_Handle,
	buildings:                   [dynamic]game.Entity_Handle,
	have:                        [skirmish.Building]int,
	headquarters:                game.Entity_Handle,
}

computer_think :: proc(s: ^core.Server, side: ^Side) {
	w := s.home
	c := &side.computer
	own := Own {
		workers      = make([dynamic]game.Entity_Handle, context.temp_allocator),
		idle_workers = make([dynamic]game.Entity_Handle, context.temp_allocator),
		army         = make([dynamic]game.Entity_Handle, context.temp_allocator),
		buildings    = make([dynamic]game.Entity_Handle, context.temp_allocator),
	}
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		m := mind(w, h)
		if m == nil || m.role == .Node || core.entity_team(w, h) != side.team {continue}
		switch m.role {
		case .Unit:
			if m.unit == .Worker {
				append(&own.workers, h)
				if m.order == .Stop {append(&own.idle_workers, h)}
			} else {
				append(&own.army, h)
			}
		case .Building:
			append(&own.buildings, h)
			own.have[m.building] += 1
			if m.building == .Headquarters {own.headquarters = h}
		case .Node:
		}
	}
	// Idle workers to the resource it has less of.
	for h in own.idle_workers {
		r := skirmish.Resource.Ore if side.stock[.Ore] <= side.stock[.Wood] + 50 else .Wood
		node := node_nearest(s, core.entity_pos(w, h), r, 40)
		if node ==
		   0 {node = node_nearest(s, core.entity_pos(w, h), .Wood if r == .Ore else .Ore, 60)}
		if node == 0 {continue}
		order_one(s, side, h, .Gather, core.entity_pos(w, node), core.entity_id(w, node))
	}
	// Workers.
	if own.headquarters != 0 && len(own.workers) < COMPUTER_WORKERS {
		if hm := mind(w, own.headquarters); hm.queued == 0 {
			train(s, side, core.entity_id(w, own.headquarters), .Worker)
		}
	}
	// The next building of its order, by its headquarters.
	if c.next < len(BUILD_ORDER) && own.headquarters != 0 && len(own.workers) > 2 {
		b := BUILD_ORDER[c.next]
		if skirmish.can_afford(side.stock, skirmish.BUILDINGS[b].cost) {
			if at, ok := computer_site(s, side, b); ok {
				builder := own.workers[c.next % len(own.workers)]
				o := skirmish.Order {
					kind     = .Build,
					count    = 1,
					at       = {i16(at.x), 0, i16(at.y)},
					building = b,
				}
				o.ids[0] = core.entity_id(w, builder)
				order_apply(s, side, o)
				c.next += 1
			}
		}
	}
	// The army.
	for h in own.buildings {
		m := mind(w, h)
		if !m.built || m.queued > 0 {continue}
		#partial switch m.building {
		case .Barracks:
			train(s, side, core.entity_id(w, h), .Archer if c.archers else .Soldier)
			c.archers = !c.archers
		case .Workshop:
			train(s, side, core.entity_id(w, h), .Ram)
		}
	}
	if len(own.army) >= c.wave {
		target := computer_target(s, side)
		o := skirmish.Order {
			kind = .Attack_Move,
			at   = {i16(target.x), skirmish.GROUND, i16(target.y)},
		}
		for h in own.army {
			o.ids[o.count] = core.entity_id(w, h)
			o.count += 1
			if int(o.count) == skirmish.MAX_ORDER_IDS {
				order_apply(s, side, o)
				o.count = 0
			}
		}
		if o.count > 0 {order_apply(s, side, o)}
		c.waves += 1
		c.wave += WAVE_GROWTH
	}
}

// order_one: one unit's order, as a request would give it.
order_one :: proc(
	s: ^core.Server,
	side: ^Side,
	h: game.Entity_Handle,
	kind: skirmish.Order_Kind,
	at: [3]f64,
	target: u32,
) {
	o := skirmish.Order {
		kind   = kind,
		count  = 1,
		target = target,
		at     = {i16(at.x), i16(at.y), i16(at.z)},
	}
	o.ids[0] = core.entity_id(s.home, h)
	order_apply(s, side, o)
}

// computer_site: a place by its headquarters a building fits, tried ring by ring.
computer_site :: proc(s: ^core.Server, side: ^Side, b: skirmish.Building) -> ([2]i32, bool) {
	toward := [2]i32{1 if side.start.x < MID else -1, 1 if side.start.y < MID else -1}
	for ring in i32(6) ..= 14 {
		for step in i32(-ring) ..= ring {
			for at in ([4][2]i32{side.start + {step, ring} * toward, side.start + {ring, step} * toward, side.start + {step, -ring} * toward, side.start + {-ring, step} * toward}) {
				if _, _, ok := site(s, b, at); ok {return at, true}
			}
		}
	}
	return {}, false
}

// computer_target: the nearest corner where a side started that is not its own and has not
// lost (the map's layout is no secret; what stands there now is).
computer_target :: proc(s: ^core.Server, side: ^Side) -> [2]i32 {
	g := state(s)
	best, at := f64(1e18), side.start
	for &other in g.sides {
		if other.team == 0 || other.team == side.team || other.lost {continue}
		d := field_distance(
			{f64(side.start.x), f64(side.start.y)},
			{f64(other.start.x), f64(other.start.y)},
		)
		if d < best {best, at = d, other.start}
	}
	return at
}
