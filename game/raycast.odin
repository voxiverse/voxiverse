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
			if block_solid(b) {return {block, normal, distance}, true}
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
