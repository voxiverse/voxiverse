package game

import "core:math"

// Voxel raycast (Amanatides & Woo): walks the blocks a ray passes through,
// in order, each exactly once, up to max_distance. Used for aiming at blocks
// on both sides: the client to show and request, the server to check the
// request (same reach, same line of sight).

Ray_Hit :: struct {
	block:    Block_Pos, // the solid block hit
	normal:   [3]i32, // the face the ray entered through (where a placed block goes); zero if it started inside
	distance: f64,
	point:    [3]f64, // where the ray met it: origin + dir * distance
}

// raycast returns the first solid, loaded block along the ray; unloaded
// chunks stop the ray without a hit. dir need not be normalized.
raycast :: proc(
	q: Block_Query,
	origin: [3]f64,
	dir: [3]f64,
	max_distance: f64,
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	length := math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
	if length == 0 {return}
	d := dir / length
	block := Block_Pos {
		i32(math.floor(origin.x)),
		i32(math.floor(origin.y)),
		i32(math.floor(origin.z)),
	}
	step: [3]i32
	t_max, t_delta: [3]f64 // distance to the next boundary on each axis; between boundaries
	for axis in 0 ..< 3 {
		switch {
		case d[axis] > 0:
			step[axis] = 1
			t_max[axis] = (f64(block[axis]) + 1 - origin[axis]) / d[axis]
			t_delta[axis] = 1 / d[axis]
		case d[axis] < 0:
			step[axis] = -1
			t_max[axis] = (origin[axis] - f64(block[axis])) / -d[axis]
			t_delta[axis] = 1 / -d[axis]
		case:
			t_max[axis] = math.INF_F64
			t_delta[axis] = math.INF_F64
		}
	}
	normal: [3]i32
	distance := 0.0
	for distance <= max_distance {
		if block.y >= WORLD_MIN_Y && block.y < WORLD_MAX_Y {
			b, loaded := q.get(q.data, block)
			if !loaded {return}
			if block_targetable(q.table, b) {
				sel := q.table.selection[b]
				if sel == SHAPE_CUBE {
					return {block, normal, distance, origin + d * distance}, true
				}
				if h, hit_box := ray_boxes(
					shape_boxes(q.table, sel),
					block,
					origin,
					d,
					distance,
					max_distance,
				); hit_box {
					return h, true
				}
			}
		}
		// Step into the next block along the axis whose boundary is nearest.
		axis := 0
		if t_max[1] < t_max[axis] {axis = 1}
		if t_max[2] < t_max[axis] {axis = 2}
		distance = t_max[axis]
		t_max[axis] += t_delta[axis]
		block[axis] += step[axis]
		normal = {}
		normal[axis] = -step[axis]
	}
	return
}

// ray_boxes: the nearest of a cell's selection boxes the ray hits, entered at
// or after entry and within max_distance (the slab method, in f64).
@(private = "file")
ray_boxes :: proc(
	boxes: []Box,
	cell: Block_Pos,
	origin, d: [3]f64,
	entry, max_distance: f64,
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	best := math.INF_F64
	for box in boxes {
		t_near, t_far := -math.INF_F64, math.INF_F64
		axis_in := -1
		inside_slabs := true
		for k in 0 ..< 3 {
			lo := f64(cell[k]) + f64(box.lo[k]) / 16
			hi := f64(cell[k]) + f64(box.hi[k]) / 16
			if d[k] == 0 {
				if origin[k] < lo || origin[k] > hi {inside_slabs = false}
				continue
			}
			t0, t1 := (lo - origin[k]) / d[k], (hi - origin[k]) / d[k]
			if t0 > t1 {t0, t1 = t1, t0}
			if t0 > t_near {t_near, axis_in = t0, k}
			t_far = min(t_far, t1)
		}
		if !inside_slabs || t_near > t_far || t_far < 0 {continue}
		t := max(t_near, 0)
		t = max(t, entry) if t_near > 0 else t
		if t > max_distance || t >= best {continue}
		best = t
		hit = {cell, {}, t, origin + d * t}
		if t_near > 0 && axis_in >= 0 {
			hit.normal[axis_in] = -1 if d[axis_in] > 0 else 1
		}
		ok = true
	}
	return
}
