package towers_server

import "core:log"

import "common:base"
import "common:game"
import "games:towers"
import "server:core"

// The field: built for each run from its seed, so a run begins on clean ground whatever
// the last one's players built. Every block goes through the edit journal under a cause
// of the game's (core.game_act).

// AREA: what the game keeps loaded and builds in: the border round the field and the
// ground under it.
AREA :: core.Box{{-1, -2, -1}, {towers.SIZE_X, towers.WALL_HEIGHT + 3, towers.SIZE_Z}}

// INSIDE: above the field's floor, everything players or rocks can stand in.
INSIDE :: core.Box{{0, 0, 0}, {towers.SIZE_X - 1, towers.WALL_HEIGHT + 2, towers.SIZE_Z - 1}}

// ROUTE_AREA: where the creeps walk (they stand in y 0: the floor is flat and nothing
// they cannot climb is climbed).
ROUTE_AREA :: core.Box{{0, 0, 0}, {towers.SIZE_X - 1, 0, towers.SIZE_Z - 1}}

ROCKS_MIN, ROCKS_MAX :: 6, 10

// build: the border, the floor, the gate, the core and the rocks of the run's seed;
// false while the field's chunks are not all loaded, unless force (the wait is over:
// what is there is built, and said).
build :: proc(s: ^core.Server, force: bool) -> bool {
	w := s.home
	d := state(s)
	ready := core.world_ready(w, AREA)
	if !ready && !force {return false}
	act := core.game_act(s, w, .Structure)
	lo, hi := AREA.lo, AREA.hi
	fill :: proc(w: ^core.World, box: core.Box, block: game.Block, act: core.Act) {
		core.bulk_edit(w, {shape = box, op = .Set, block = block, partial = true}, act)
	}
	fill(w, INSIDE, .Air, act)
	fill(w, {{0, -1, 0}, {towers.SIZE_X - 1, -1, towers.SIZE_Z - 1}}, .Grass, act)
	fill(w, {{0, lo.y, 0}, {towers.SIZE_X - 1, -2, towers.SIZE_Z - 1}}, .Stone, act)
	top := i32(towers.WALL_HEIGHT - 1)
	walls := [4]core.Box {
		{{lo.x, lo.y, lo.z}, {lo.x, top, hi.z}},
		{{hi.x, lo.y, lo.z}, {hi.x, top, hi.z}},
		{{0, lo.y, lo.z}, {towers.SIZE_X - 1, top, lo.z}},
		{{0, lo.y, hi.z}, {towers.SIZE_X - 1, top, hi.z}},
	}
	for wall in walls {
		fill(w, wall, .Bedrock, act)
	}
	// The path's ends: sand from the gate, and round the core.
	g := towers.GATE
	fill(w, {{0, -1, g.z - 1}, {3, -1, g.z + 1}}, .Sand, act)
	fill(w, {{towers.CORE_X - 2, -1, g.z - 2}, {towers.SIZE_X - 1, -1, g.z + 1}}, .Sand, act)
	// The gate: an arch in the west wall, round the block the creeps come out at.
	fill(w, {{lo.x, 0, g.z - 1}, {lo.x, 3, g.z + 1}}, d.gate_block, act)
	fill(w, {{0, 0, g.z - 1}, {0, 3, g.z - 1}}, d.gate_block, act)
	fill(w, {{0, 0, g.z + 1}, {0, 3, g.z + 1}}, d.gate_block, act)
	fill(w, {{0, 3, g.z}, {0, 3, g.z}}, d.gate_block, act)
	// The core: two by two by two, glowing.
	fill(
		w,
		{{towers.CORE_X, 0, towers.MID_Z - 1}, {towers.CORE_X + 1, 1, towers.MID_Z}},
		d.core_block,
		act,
	)
	rocks(s, act)
	log.infof("towers field built run=%d seed=%d all_loaded=%v", d.run, d.seed, ready)
	return true
}

// rocks: the seed's rocks, two blocks high, on the build ground away from the gate's and
// the core's ends; one that shuts the way is taken away again.
@(private = "file")
rocks :: proc(s: ^core.Server, act: core.Act) {
	w := s.home
	d := state(s)
	r := base.rng_make(u64(d.seed) ~ 0x70c5)
	n := base.rng_int_range(&r, ROCKS_MIN, ROCKS_MAX + 1)
	for _ in 0 ..< n {
		x := i32(base.rng_int_range(&r, towers.BUILD_MIN_X + 3, towers.BUILD_MAX_X - 2))
		z := i32(base.rng_int_range(&r, 3, towers.SIZE_Z - 4))
		wide := i32(base.rng_int_range(&r, 1, 3))
		deep := i32(base.rng_int_range(&r, 1, 4))
		rock := core.Box{{x, 0, z}, {x + wide - 1, 1, z + deep - 1}}
		block := game.Block.Cobblestone if base.rng_int_max(&r, 2) == 0 else .Stone
		core.bulk_edit(w, {shape = rock, op = .Set, block = block, partial = true}, act)
		if !core.route_reaches(w, d.routes[.Brute], towers.GATE) {
			core.bulk_edit(w, {shape = rock, op = .Set, block = .Air, partial = true}, act)
		}
	}
}
