package game

import "core:math"

// Collision shared by everything that moves through blocks: bodies, players
// and projectiles. `sweep` (physics.odin) is the one axis-at-a-time move;
// this file builds on it: step_up (walking up a stair or slab), collide_move
// (a whole move, axis by axis), cast_box (the earliest hit of a box moving
// along a line, which no step can tunnel through). All of them see the
// blocks' collision boxes and the boxes of Block_Query.extra alike.

// Step_Result is what a successful step_up gives.
Step_Result :: struct {
	position: [3]f64,
	velocity: [3]f32, // x and z as the stepped move left them; y as given
}

// step_up: a box on the ground that was stopped sideways tries the same
// horizontal move from `step` higher (up, across, down by what it rose) and
// keeps it only if it landed and went strictly farther (by |dx| + |dz|) than
// the move that stopped. position: where the box is after the normal moves;
// from: where the horizontal moves began; delta: the move; vel: the velocity
// before the moves. false: nothing changes.
step_up :: proc(
	q: Block_Query,
	position: [3]f64,
	half_width, height: f64,
	from, delta: [3]f64,
	vel: [3]f32,
	step: f64,
) -> (
	Step_Result,
	bool,
) {
	width := half_width * 2
	normal := abs(position.x - from.x) + abs(position.z - from.z)
	p := from
	rose, _ := sweep(p, width, height, 1, step, q)
	if rose <= 0 {return {}, false}
	p.y += rose
	v := vel
	for axis in ([2]int{0, 2}) {
		moved, hit := sweep(p, width, height, axis, delta[axis], q)
		p[axis] += moved
		if hit {v[axis] = 0}
	}
	dropped, landed := sweep(p, width, height, 1, -rose, q)
	if !landed {return {}, false}
	p.y += dropped
	if abs(p.x - from.x) + abs(p.z - from.z) <= normal {return {}, false}
	return {position = p, velocity = v}, true
}

// Collide is where collide_move left a box.
Collide :: struct {
	position:  [3]f64,
	velocity:  [3]f32, // zeroed on each axis that hit
	hit:       [3]bool, // per axis: a collision box stopped it
	on_ground: bool, // stopped by something below
	stepped:   bool, // step_up carried it over a ledge
}

// collide_move moves a box (position: the centre of its bottom) by delta, one
// axis at a time in the order y, x, z, each through `sweep`: velocity is
// zeroed on an axis that hit, on_ground is set by a downward hit on y. With
// step > 0, a box that was on the ground and stopped on x or z then tries
// step_up. (Players keep their own loop, the sneak edge guard runs between
// its axes, and call step_up.)
collide_move :: proc(
	q: Block_Query,
	position: [3]f64,
	half_width, height: f64,
	delta: [3]f64,
	velocity: [3]f32,
	step: f64,
) -> (
	c: Collide,
) {
	width := half_width * 2
	c.position, c.velocity = position, velocity
	stepped_from: [3]f64
	stopped: bool
	for axis in ([3]int{1, 0, 2}) {
		if axis == 0 {stepped_from = c.position}
		moved, hit := sweep(c.position, width, height, axis, delta[axis], q)
		c.position[axis] += moved
		if hit {
			if axis == 1 && delta.y < 0 {c.on_ground = true}
			if axis != 1 {stopped = true}
			c.hit[axis] = true
			c.velocity[axis] = 0
		}
	}
	if step > 0 && stopped && c.on_ground {
		if r, ok := step_up(
			q,
			c.position,
			half_width,
			height,
			stepped_from,
			delta,
			velocity,
			step,
		); ok {
			c.position = r.position
			c.velocity.x, c.velocity.z = r.velocity.x, r.velocity.z
			c.stepped = true
		}
	}
	return
}

// cast_box: the earliest time of impact, in [0, 1], of the box [lo, hi]
// moving by delta against the collision boxes (cells and extra) in its swept
// bounds: per box a slab test on the Minkowski sum, ties to the lowest axis.
// A box already overlapped at the start is ignored (as sweep ignores a face
// it starts inside). axis: the axis of the face hit. hit false: it goes the
// whole way (fraction 1).
cast_box :: proc(
	q: Block_Query,
	lo, hi: [3]f64,
	delta: [3]f64,
) -> (
	fraction: f64,
	axis: int,
	hit: bool,
) {
	fraction = 1
	slo, shi := lo, hi
	for k in 0 ..< 3 {
		slo[k] = min(lo[k], lo[k] + delta[k])
		shi[k] = max(hi[k], hi[k] + delta[k])
	}
	test :: proc(blo, bhi, lo, hi, delta: [3]f64, fraction: ^f64, axis: ^int, hit: ^bool) {
		EPS :: 1e-7
		// Already overlapped at the start: ignored.
		if blo.x < hi.x - EPS &&
		   bhi.x > lo.x + EPS &&
		   blo.y < hi.y - EPS &&
		   bhi.y > lo.y + EPS &&
		   blo.z < hi.z - EPS &&
		   bhi.z > lo.z + EPS {
			return
		}
		enter, leave := -math.INF_F64, math.INF_F64
		enter_axis := 0
		for k in 0 ..< 3 {
			if delta[k] == 0 {
				if blo[k] >= hi[k] || bhi[k] <= lo[k] {return}
				continue
			}
			t0, t1 := (blo[k] - hi[k]) / delta[k], (bhi[k] - lo[k]) / delta[k]
			if delta[k] < 0 {t0, t1 = t1, t0}
			if t0 > enter {enter, enter_axis = t0, k}
			leave = min(leave, t1)
		}
		if enter > leave || enter < 0 || enter > fraction^ {return}
		if enter == fraction^ && (!hit^ || enter_axis >= axis^) {return}
		fraction^, axis^, hit^ = enter, enter_axis, true
	}
	for y in i32(math.floor(slo.y)) ..= i32(math.floor(shi.y)) {
		for z in i32(math.floor(slo.z)) ..= i32(math.floor(shi.z)) {
			for x in i32(math.floor(slo.x)) ..= i32(math.floor(shi.x)) {
				p := Block_Pos{x, y, z}
				for box in cell_boxes(q, p) {
					blo, bhi := box_world(box, p)
					test(blo, bhi, lo, hi, delta, &fraction, &axis, &hit)
				}
			}
		}
	}
	if q.extra.boxes != nil {
		for box in extra_boxes(q, slo, shi) {
			test(box.lo, box.hi, lo, hi, delta, &fraction, &axis, &hit)
		}
	}
	return
}
