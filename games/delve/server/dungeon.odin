package delve_server

import "core:fmt"
import "core:log"
import "core:math"

import "common:base"
import "common:game"
import "games:delve"
import "server:core"

// The dungeon in the world: x and z from 0 (its corner) to its size, its floor the flat
// world's ground (y -1), WALL_HEIGHT blocks of wall round every room and corridor. Each
// new dungeon is built over the last one from its seed; every block goes through the
// edit journal under a cause of the game's.

SPAN :: delve.MAX_GRID * delve.CELL // the most a dungeon spans, x and z

// AREA: what the game keeps loaded and builds in (the biggest dungeon, a border round it).
AREA :: core.Box{{-2, -3, -2}, {SPAN + 1, delve.WALL_HEIGHT + 2, SPAN + 1}}

// dungeon_begin: a new dungeon of a depth, built as soon as its ground is there; the
// last one's creatures and loot go.
dungeon_begin :: proc(s: ^core.Server, depth: int) {
	d := state(s)
	foes_clear(s)
	d.depth = depth
	d.seed = base.rng_u32(&d.rng)
	delve.dungeon_plan(&d.plan, d.seed, depth)
	d.warden = 0
	set_phase(s, .Building)
	if depth > 1 {
		event := delve.Descended{u8(clamp(depth, 0, 255))}
		for &c in s.clients {if here(s, &c) {core.game_event(s, &c, &event)}}
		core.announce(s, fmt.tprintf("&eDown to depth %d&r", depth))
	}
	log.infof("delve dungeon depth=%d seed=%d rooms=%d", depth, d.seed, d.plan.room_count)
}

// dungeon_build: the dungeon's blocks, its creatures and its chests; false while its
// ground is not all loaded, unless force.
dungeon_build :: proc(s: ^core.Server, force: bool) -> bool {
	w := s.home
	d := state(s)
	if !core.world_ready(w, AREA) && !force {return false}
	act := core.game_act(s, w, .Structure)
	fill :: proc(w: ^core.World, box: core.Box, block: game.Block, act: core.Act) {
		core.bulk_edit(w, {shape = box, op = .Set, block = block, partial = true}, act)
	}
	size := delve.dungeon_size(&d.plan)
	top := i32(delve.WALL_HEIGHT - 1)
	// The last dungeon goes; this one's walls stand in a block of stone, and the
	// rooms and corridors are carved out of it.
	fill(w, {{AREA.lo.x, 0, AREA.lo.z}, {AREA.hi.x, AREA.hi.y, AREA.hi.z}}, .Air, act)
	fill(w, {{AREA.lo.x, -1, AREA.lo.z}, {AREA.hi.x, -1, AREA.hi.z}}, .Grass, act)
	fill(w, {{-1, -1, -1}, {size.x, -1, size.y}}, d.floor, act)
	fill(w, {{-1, 0, -1}, {size.x, top, size.y}}, d.wall, act)
	carve :: proc(w: ^core.World, a: delve.Area, top: i32, act: core.Act) {
		fill(w, {{a.lo.x, 0, a.lo.y}, {a.hi.x, top, a.hi.y}}, .Air, act)
	}
	for room in d.plan.rooms[:d.plan.room_count] {carve(w, room.area, top, act)}
	for p in d.plan.passages[:d.plan.pass_count] {
		carve(w, p.legs[0], top, act)
		carve(w, p.legs[1], top, act)
	}
	populate(s)
	return true
}

// room_point: the middle of a room's floor (where a delver or a creature stands).
room_point :: proc(a: delve.Area) -> [3]f64 {
	m := delve.room_middle(a)
	return {f64(m.x) + 0.5, 0, f64(m.y) + 0.5}
}

start_point :: proc(s: ^core.Server) -> [3]f64 {
	d := state(s)
	return room_point(d.plan.rooms[d.plan.start].area)
}

// exit_area: the way down's blocks, in the floor of the warden's room.
exit_area :: proc(s: ^core.Server) -> core.Box {
	d := state(s)
	m := delve.room_middle(d.plan.rooms[d.plan.boss].area)
	return {{m.x - 1, -1, m.y - 1}, {m.x + 1, -1, m.y + 1}}
}

// populate: creatures in every room but the start, more deeper; the warden and its
// guards in its room; a chest in some rooms.
populate :: proc(s: ^core.Server) {
	d := state(s)
	r := &d.rng
	for room, i in d.plan.rooms[:d.plan.room_count] {
		if i == d.plan.start {continue}
		a := room.area
		place :: proc(r: ^base.Rng, a: delve.Area) -> [3]f64 {
			return {
				f64(base.rng_int_range(r, int(a.lo.x) + 1, int(a.hi.x))) + 0.5,
				0,
				f64(base.rng_int_range(r, int(a.lo.y) + 1, int(a.hi.y))) + 0.5,
			}
		}
		if i == d.plan.boss {
			if h := foe_spawn(s, .Warden, room_point(a), false); h != 0 {
				d.warden = core.entity_id(s.home, h)
				d.warden_call = s.tick + u64(delve.WARDEN_CALL_SECONDS * game.TICK_RATE)
			}
			for _ in 0 ..< 2 {foe_spawn(s, .Husk, place(r, a), d.depth >= 3)}
			continue
		}
		groups := 1 + base.rng_int_max(r, 2) + d.depth / 2
		for _ in 0 ..< groups {
			roll := base.rng_int_max(r, 10)
			at := place(r, a)
			switch {
			case roll < 3:
				// A pack of biters.
				for k in 0 ..< 3 {foe_spawn(s, .Biter, at + {f64(k % 2), 0, f64(k / 2)}, false)}
			case roll < 6:
				foe_spawn(s, .Husk, at, elite_roll(s))
			case roll < 8:
				foe_spawn(s, .Spitter, at, elite_roll(s))
			case:
				foe_spawn(s, .Brute, at, elite_roll(s))
			}
		}
		if base.rng_int_max(r, 10) < 4 {
			core.entity_spawn(s.home, d.chest, place(r, a), false)
		}
	}
}

// elite_roll: whether a creature made now is an elite (more likely deeper).
elite_roll :: proc(s: ^core.Server) -> bool {
	d := state(s)
	return base.rng_f64(&d.rng) < 0.1 + 0.04 * f64(d.depth)
}

// way_down: a delver on the way down takes everyone to the next dungeon.
way_down :: proc(s: ^core.Server) {
	d := state(s)
	e := exit_area(s)
	for &c in s.clients {
		if !here(s, &c) || c.dead {continue}
		p := c.player.position
		x, z := i32(math.floor(p.x)), i32(math.floor(p.z))
		if x >= e.lo.x && x <= e.hi.x && z >= e.lo.z && z <= e.hi.z && p.y < 1 {
			core.announce(s, fmt.tprintf("&e%s takes the way down&r", core.client_name(&c)))
			dungeon_begin(s, d.depth + 1)
			return
		}
	}
}

// open_way: the warden is dead: the way down glows in its room's floor.
open_way :: proc(s: ^core.Server) {
	d := state(s)
	core.bulk_edit(
		s.home,
		{shape = exit_area(s), op = .Set, block = d.exit},
		core.game_act(s, s.home, .Structure),
	)
	set_phase(s, .Open)
}
