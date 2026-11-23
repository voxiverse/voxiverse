package sandbox_server

import "core:math"
import "core:slice"

import "common:game"
import "common:worldgen"
import "server:core"

// Sites: the places the sandbox builds on its home world from the seed alone (the ruin:
// ruin.odin; the remains round the home gate: remains.odin), and what they share: the land
// as the world's generator makes it under one (land_at, site_ground), footprints that keep
// clear of each other (Footprint) and ground levelled to build on (site_level).

// Site: where a levelled site stands: its lowest corner and the floor's layer (who stands
// on it stands at floor + 1), the lowest and the highest the land stands under it (as the
// generator makes it), and whether the ground was found dry and level.
Site :: struct {
	origin: game.Block_Pos,
	floor:  i32,
	lo, hi: i32,
	level:  bool,
}

// Land: what the sandbox asks of a world's generator about its land, with the seed its land
// is made from (terrain_seed).
Land :: struct {
	generator: worldgen.Kind,
	seed:      i64,
	params:    worldgen.Params,
}

land_of :: proc(w: ^core.World) -> Land {return {w.generator, terrain_seed(w), w.params}}

// land_at: the top block of the land at column (x, z) as the generator makes it (before its
// trees and anything built), and whether it is dry ground to build on: no sea, beach, river,
// lake, mountain, ice or overhang.
land_at :: proc(l: ^Land, x, z: i32) -> (top: i32, dry: bool) {
	switch l.generator {
	case .Flat:
		return worldgen.FLAT_TOP, true
	case .Classic:
		return worldgen.classic_height(l.seed, x, z), true
	case .Earth:
	}
	c := worldgen.column_at(&l.params, l.seed, x, z)
	top = i32(math.floor(c.height))
	dry = true
	#partial switch c.biome {
	case .Ocean, .Frozen_Ocean, .River, .Beach, .Mountains, .Ice_Sheet:
		dry = false
	}
	if c.rough > 0 || c.river > 0.3 || c.height < f32(l.params.sea_level) + 2 {dry = false}
	if l.params.planet != 0 {
		lake, _ := worldgen.planet_lake_at(x, z)
		if lake >= 0.5 {dry = false}
	}
	return
}

// site_ground: for a site whose middle is column (x, z) and which reaches edge blocks from
// it, sampled on a grid of 5 by 5 over it (land_at): the floor's layer (the middle height of
// the samples, and on Earth never under the sea's top), the lowest and the highest the land
// stands, and whether all of it is dry ground.
site_ground :: proc(l: ^Land, x, z, edge: i32) -> (floor, lo, hi: i32, dry: bool) {
	steps := [5]i32{-edge, -edge / 2, 0, edge / 2, edge}
	heights: [25]i32
	dry = true
	for dz, j in steps {
		for dx, i in steps {
			top, here := land_at(l, x + dx, z + dz)
			heights[i + j * 5] = top
			dry &&= here
		}
	}
	slice.sort(heights[:])
	lo, hi = heights[0], heights[24]
	floor = heights[12]
	if l.generator == .Earth {floor = max(floor, l.params.sea_level + 1)}
	return
}

// site_level: the ground of area levelled at floor, so what is built on it is neither buried
// nor perched: everything over the floor cleared (to the area's top), the hollows and the
// water under it filled with stone (from the area's bottom), the floor's layer grass.
site_level :: proc(w: ^core.World, area: core.Box, floor: i32, act: core.Act) {
	a := area
	above := core.Box{{a.lo.x, floor + 1, a.lo.z}, a.hi}
	core.bulk_edit(w, {shape = above, op = .Set, block = .Air, partial = true}, act)
	under := core.Box{a.lo, {a.hi.x, floor - 1, a.hi.z}}
	for from in ([2]game.Block{.Air, .Water}) {
		e := core.Bulk_Edit {
			shape   = under,
			op      = .Replace,
			from    = from,
			block   = .Stone,
			partial = true,
		}
		core.bulk_edit(w, e, act)
	}
	top := core.Box{{a.lo.x, floor, a.lo.z}, {a.hi.x, floor, a.hi.z}}
	core.bulk_edit(w, {shape = top, op = .Set, block = .Grass, partial = true}, act)
}

// Footprint: the columns a site covers, lo..hi inclusive (x, z).
Footprint :: struct {
	lo, hi: [2]i32,
}

// footprint_meets: a and b come within margin blocks of each other.
footprint_meets :: proc(a, b: Footprint, margin: i32) -> bool {
	return(
		a.lo.x - margin <= b.hi.x &&
		b.lo.x - margin <= a.hi.x &&
		a.lo.y - margin <= b.hi.y &&
		b.lo.y - margin <= a.hi.y \
	)
}
