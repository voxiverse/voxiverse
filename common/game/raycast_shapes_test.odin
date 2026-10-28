package game

import "core:math"
import "core:math/rand"
import "core:testing"

// The raycast over shapes: cubes hit exactly as before, boxes at their own faces.

@(private = "file")
frozen_raycast :: proc(
	q: Block_Query,
	origin: [3]f64,
	dir: [3]f64,
	max_distance: f64,
) -> (
	block: Block_Pos,
	normal: [3]i32,
	distance: f64,
	ok: bool,
) {
	length := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
	if length == 0 {return}
	d := dir / length
	cell := Block_Pos{i32(math.floor(origin.x)), i32(math.floor(origin.y)), i32(math.floor(origin.z))}
	step: [3]i32
	t_max, t_delta: [3]f64
	for axis in 0 ..< 3 {
		switch {
		case d[axis] > 0:
			step[axis] = 1
			t_max[axis] = (f64(cell[axis]) + 1 - origin[axis]) / d[axis]
			t_delta[axis] = 1 / d[axis]
		case d[axis] < 0:
			step[axis] = -1
			t_max[axis] = (origin[axis] - f64(cell[axis])) / -d[axis]
			t_delta[axis] = 1 / -d[axis]
		case:
			t_max[axis] = math.INF_F64
			t_delta[axis] = math.INF_F64
		}
	}
	n: [3]i32
	dist := 0.0
	for dist <= max_distance {
		if cell.y >= WORLD_MIN_Y && cell.y < WORLD_MAX_Y {
			b, loaded := q.get(q.data, cell)
			if !loaded {return}
			if block_targetable(q.table, b) {return cell, n, dist, true}
		}
		axis := 0
		if t_max[1] < t_max[axis] {axis = 1}
		if t_max[2] < t_max[axis] {axis = 2}
		dist = t_max[axis]
		t_max[axis] += t_delta[axis]
		cell[axis] += step[axis]
		n = {}
		n[axis] = -step[axis]
	}
	return
}

@(private = "file")
World :: map[Block_Pos]Block

@(private = "file")
world_query :: proc(w: ^World, reg: ^Registry) -> Block_Query {
	return {w, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			w := (^World)(data)
			return w[p] or_else .Air, true
		}, &reg.blocks}
}

@(test)
test_raycast_cubes_unchanged :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	w: World
	defer delete(w)
	r := rand.create(48)
	context.random_generator = rand.default_random_generator(&r)
	for x in i32(-6) ..< 6 {
		for y in i32(-6) ..< 6 {
			for z in i32(-6) ..< 6 {
				switch rand.int_max(6) {
				case 0, 1:
					w[{x, y, z}] = .Stone
				case 2:
					w[{x, y, z}] = .Tall_Grass
				case 3:
					w[{x, y, z}] = .Water
				}
			}
		}
	}
	q := world_query(&w, reg)
	mismatches := 0
	for _ in 0 ..< 10_000 {
		origin := [3]f64{rand.float64_range(-7, 7), rand.float64_range(-7, 7), rand.float64_range(-7, 7)}
		if rand.int_max(4) == 0 {origin = {math.round(origin.x), math.round(origin.y), math.round(origin.z)}}
		dir := [3]f64{rand.float64_range(-1, 1), rand.float64_range(-1, 1), rand.float64_range(-1, 1)}
		if rand.int_max(5) == 0 {dir[rand.int_max(3)] = 0}
		hit, ok := raycast(q, origin, dir, 8)
		block, normal, distance, ok2 := frozen_raycast(q, origin, dir, 8)
		if ok != ok2 {mismatches += 1; continue}
		if !ok {continue}
		if hit.block != block || hit.normal != normal || hit.distance != distance {mismatches += 1}
		length := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
		if hit.point != origin + dir / length * distance {mismatches += 1}
	}
	testing.expect_value(t, mismatches, 0)
}

@(private = "file")
put :: proc(w: ^World, reg: ^Registry, p: Block_Pos, text: string) {
	b, ok := state_parse(reg, text)
	if !ok {panic(text)}
	w[p] = b
}

@(private = "file")
near :: proc(a, b: [3]f64) -> bool {
	return abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.z - b.z) < 1e-9
}

@(test)
test_raycast_boxes :: proc(t: ^testing.T) {
	reg := states_registry(t)
	if reg == nil {return}
	w: World
	defer delete(w)
	put(&w, reg, {0, 0, 0}, "testpack:planks_slab[type=bottom]")
	q := world_query(&w, reg)
	// From above: the slab's top at y + 0.5, normal +y.
	hit, ok := raycast(q, {0.5, 3, 0.5}, {0, -1, 0}, 8)
	testing.expect(t, ok)
	testing.expect_value(t, hit.block, Block_Pos{0, 0, 0})
	testing.expect_value(t, hit.normal, [3]i32{0, 1, 0})
	testing.expect_value(t, hit.distance, 2.5)
	testing.expect(t, near(hit.point, {0.5, 0.5, 0.5}))
	// Over the slab (above its half): the wall behind is hit instead.
	w[{2, 0, 0}] = .Stone
	hit, ok = raycast(q, {-2, 0.8, 0.5}, {1, 0, 0}, 8)
	testing.expect(t, ok)
	testing.expect_value(t, hit.block, Block_Pos{2, 0, 0})
	testing.expect_value(t, hit.normal, [3]i32{-1, 0, 0})
	// Level with the slab: its side.
	hit, ok = raycast(q, {-2, 0.25, 0.5}, {1, 0, 0}, 8)
	testing.expect(t, ok)
	testing.expect_value(t, hit.block, Block_Pos{0, 0, 0})
	testing.expect_value(t, hit.normal, [3]i32{-1, 0, 0})
	testing.expect_value(t, hit.distance, 2.0)
	// A stair facing north: the riser (upper box z 0..8) and the step (the lower box's top at z 8..16).
	put(&w, reg, {5, 0, 0}, "testpack:planks_stairs[facing=north,half=bottom]")
	hit, ok = raycast(q, {5.5, 0.75, 2}, {0, 0, -1}, 8)
	testing.expect(t, ok)
	testing.expect_value(t, hit.block, Block_Pos{5, 0, 0})
	testing.expect_value(t, hit.normal, [3]i32{0, 0, 1})
	testing.expect(t, near(hit.point, {5.5, 0.75, 0.5}))
	hit, ok = raycast(q, {5.5, 3, 0.75}, {0, -1, 0}, 8)
	testing.expect(t, ok)
	testing.expect_value(t, hit.normal, [3]i32{0, 1, 0})
	testing.expect(t, near(hit.point, {5.5, 0.5, 0.75}))
	// From inside the cell, in the box: distance 0, no normal.
	hit, ok = raycast(q, {5.5, 0.25, 0.25}, {0, 1, 0}, 8)
	testing.expect(t, ok)
	testing.expect_value(t, hit.distance, 0)
	testing.expect_value(t, hit.normal, [3]i32{})
	// Out of reach: no hit.
	_, ok = raycast(q, {5.5, 0.75, 20}, {0, 0, -1}, 8)
	testing.expect(t, !ok)
}
