package skirmish_server

import "core:math"

import "common:base"
import "common:game"
import "games:skirmish"
import "server:core"
import "server:play"

// The field: a square of skirmish.MAP blocks walled round, laid out from the seed and the
// match's number. Its low ground is grass; a plateau stands HIGH blocks over the middle,
// climbed by ramps of steps on its four sides; two ridges of rock too high to climb run
// from it to the walls, north to south and east to west, each with a gap (a choke) in each
// half, so the four corners meet only through the chokes and over the plateau. Each corner
// is a base: a side's headquarters stands there with crystal outcrops and groves around
// it; more lie on the plateau and by the chokes, worth fighting for. Boulders break up the
// low ground.

FIELD :: play.Arena {
	origin   = {0, skirmish.GROUND - 1, 0},
	size     = {skirmish.MAP, skirmish.HIGH + 4, skirmish.MAP},
	wall_top = skirmish.GROUND + skirmish.HIGH + 4,
	depth    = 2,
}

// FIELD_AREA: where walkers go (their routes' area): the field's floor and what stands on it.
FIELD_AREA :: core.Box {
	{0, skirmish.GROUND, 0},
	{skirmish.MAP - 1, skirmish.GROUND + skirmish.HIGH + 2, skirmish.MAP - 1},
}

MID :: skirmish.MAP / 2
PLATEAU :: 13 // blocks from the middle to the plateau's edge
RIDGE :: 5 // blocks a ridge stands over the low ground (too high to climb)
CHOKE :: 4 // a choke's width
BASE_INSET :: 18 // a corner's headquarters, blocks from the walls

Node_Place :: struct {
	at:       [2]i32,
	resource: skirmish.Resource,
}

Field :: struct {
	nodes:  [32]Node_Place,
	count:  int,
	chokes: [4][2]i32, // the middles of the ridges' gaps
}

// field_corners: the corners the sides of a match take (two: opposite).
field_corners :: proc(sides: int) -> [skirmish.MAX_SIDES][2]i32 {
	lo, hi := i32(BASE_INSET), i32(skirmish.MAP - 1 - BASE_INSET)
	return {{lo, lo}, {hi, hi}, {hi, lo}, {lo, hi}}
}

// field_rng: the match's own randomness (the universe's seed and the match's number).
@(private = "file")
field_rng :: proc(s: ^core.Server) -> base.Rng {
	return base.rng_make(u64(s.config.seed) ~ (u64(state(s).match + 1) * 0x9e37_79b9_7f4a_7c15))
}

// field_build: the field's blocks, built once its chunks are there; false until then.
field_build :: proc(s: ^core.Server) -> bool {
	g := state(s)
	r := field_rng(s)
	t := game.template_make(FIELD.size, context.temp_allocator)
	top := FIELD.size.y - 1
	n := i32(skirmish.MAP)
	// The floor (template y 0 is the world's y GROUND - 1).
	game.template_fill(&t, {0, 0, 0}, {n - 1, 0, n - 1}, .Grass)
	// The plateau and its ramps.
	lo, hi := i32(MID - PLATEAU), i32(MID + PLATEAU - 1)
	h := i32(skirmish.HIGH)
	game.template_fill(&t, {lo, 0, lo}, {hi, h - 1, hi}, .Dirt)
	game.template_fill(&t, {lo, h, lo}, {hi, h, hi}, .Grass)
	// (each side's ramp lies off its middle, turning the same way round: every corner has
	// one, and the ridges meet the plateau beside it)
	for step in i32(1) ..= h {
		// (a step down outward each block: the walkers climb one block)
		y := h - step + 1
		a0, a1 := i32(MID + 5), i32(MID + 8)
		b0, b1 := i32(MID - 9), i32(MID - 6)
		game.template_fill(&t, {a0, 1, lo - step}, {a1, y, lo - step}, .Grass)
		game.template_fill(&t, {hi + step, 1, a0}, {hi + step, y, a1}, .Grass)
		game.template_fill(&t, {b0, 1, hi + step}, {b1, y, hi + step}, .Grass)
		game.template_fill(&t, {lo - step, 1, b0}, {lo - step, y, b1}, .Grass)
	}
	// The ridges, each with a choke in each half.
	ridge := i32(RIDGE)
	g.field = {}
	k := 0
	for half in 0 ..< 2 {
		// along z (x = MID): north half then south
		z0, z1 := i32(1), lo - 1
		if half == 1 {z0, z1 = hi + 1, n - 2}
		gap := i32(base.rng_int_range(&r, int(z0) + 4, int(z1) - 4 - CHOKE))
		game.template_fill(&t, {MID - 1, 1, z0}, {MID, ridge, z1}, .Stone)
		game.template_fill(&t, {MID - 1, 1, gap}, {MID, top, gap + CHOKE - 1}, .Air)
		g.field.chokes[k] = {MID, gap + CHOKE / 2}
		k += 1
		// along x (z = MID): west half then east
		x0, x1 := i32(1), lo - 1
		if half == 1 {x0, x1 = hi + 1, n - 2}
		gap = i32(base.rng_int_range(&r, int(x0) + 4, int(x1) - 4 - CHOKE))
		game.template_fill(&t, {x0, 1, MID - 1}, {x1, ridge, MID}, .Stone)
		game.template_fill(&t, {gap, 1, MID - 1}, {gap + CHOKE - 1, top, MID}, .Air)
		g.field.chokes[k] = {gap + CHOKE / 2, MID}
		k += 1
	}
	// The resources: three outcrops and three groves round each corner, two outcrops on the
	// plateau, a grove by each choke.
	corners := field_corners(skirmish.MAX_SIDES)
	for c in corners {
		out := [2]i32{-1 if c.x < MID else 1, -1 if c.y < MID else 1}
		for i in 0 ..< 3 {
			d := i32(9 + i * 2)
			j := [2]i32{i32(base.rng_int_range(&r, -2, 3)), i32(base.rng_int_range(&r, -2, 3))}
			node_add(&g.field, c + {out.x * d, i32(i - 1) * 4} + j, .Ore)
			node_add(&g.field, c + {i32(i - 1) * 5, out.y * d} + j, .Wood)
		}
	}
	node_add(&g.field, {MID - 5, MID + 3}, .Ore)
	node_add(&g.field, {MID + 4, MID - 4}, .Ore)
	for ch in g.field.chokes {
		side := [2]i32{3, 0} if ch.x == MID else {0, 3}
		node_add(&g.field, ch + side * (1 if base.rng_int_max(&r, 2) == 0 else -1), .Wood)
	}
	// Boulders on the low ground, away from the bases and the nodes.
	for _ in 0 ..< 14 {
		at := [2]i32 {
			i32(base.rng_int_range(&r, 4, int(n) - 6)),
			i32(base.rng_int_range(&r, 4, int(n) - 6)),
		}
		if near_base(at, 16) ||
		   abs(at.x - MID) <= PLATEAU + 5 && abs(at.y - MID) <= PLATEAU + 5 {continue}
		if near_node(&g.field, at, 4) {continue}
		size := i32(base.rng_int_range(&r, 1, 3))
		game.template_fill(&t, {at.x, 1, at.y}, {at.x + size, size, at.y + size}, .Cobblestone)
	}
	built, _ := play.arena_build(s, s.home, FIELD, &t, force = false)
	return built
}

@(private = "file")
node_add :: proc(f: ^Field, at: [2]i32, resource: skirmish.Resource) {
	if f.count >= len(f.nodes) {return}
	f.nodes[f.count] = {at, resource}
	f.count += 1
}

@(private = "file")
near_base :: proc(at: [2]i32, d: i32) -> bool {
	for c in field_corners(skirmish.MAX_SIDES) {
		if abs(at.x - c.x) < d && abs(at.y - c.y) < d {return true}
	}
	return false
}

@(private = "file")
near_node :: proc(f: ^Field, at: [2]i32, d: i32) -> bool {
	for node in f.nodes[:f.count] {
		if abs(at.x - node.at.x) < d && abs(at.y - node.at.y) < d {return true}
	}
	return false
}

// floor_at: the y a walker stands in at a column of the field (false: none, a ridge).
floor_at :: proc(s: ^core.Server, x, z: i32) -> (i32, bool) {
	p, ok := play.ground_at(s, s.home, x, skirmish.GROUND + skirmish.HIGH, z, skirmish.HIGH + 1)
	return p.y, ok
}

// nodes_place: the match's crystal outcrops and groves, each with what it holds.
nodes_place :: proc(s: ^core.Server) {
	g := state(s)
	w := s.home
	for node in g.field.nodes[:g.field.count] {
		y := floor_at(s, node.at.x, node.at.y) or_continue
		kind := g.crystal if node.resource == .Ore else g.grove
		h := core.entity_spawn(
			w,
			kind,
			{f64(node.at.x) + 0.5, f64(y), f64(node.at.y) + 0.5},
			false,
		)
		if h == 0 {continue}
		m := mind(w, h)
		m.role, m.resource = .Node, node.resource
		m.left = skirmish.NODE_ORE if node.resource == .Ore else skirmish.NODE_WOOD
	}
}

// side_place: a side's headquarters at its corner, built, and its workers by its door.
side_place :: proc(s: ^core.Server, side: ^Side) {
	g := state(s)
	corner := skirmish.building_corner(.Headquarters, side.start)
	building_raise(s, side, .Headquarters, corner, skirmish.GROUND, built = true)
	door := [2]i32{side.start.x, side.start.y + (4 if side.start.y < MID else -4)}
	places := play.formation(s, s.home, {door.x, skirmish.GROUND, door.y}, g.playing.workers)
	for p in places {unit_spawn(s, side, .Worker, p)}
}

// field_distance: blocks between two columns (straight).
field_distance :: proc(a, b: [2]f64) -> f64 {
	d := a - b
	return math.sqrt(d.x * d.x + d.y * d.y)
}
