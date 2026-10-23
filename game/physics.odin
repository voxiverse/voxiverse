package game

import "core:math"

// Player movement: one procedure both sides run each tick (the server for
// every player, the client to predict its own), so the same inputs on the
// same world give the same result.
//
// The player is an axis-aligned box PLAYER_WIDTH wide and PLAYER_HEIGHT
// tall; its position is the centre of its feet. Movement is resolved one
// axis at a time (vertical first), each a sweep over every block between
// where the box is and where it would go, so no speed tunnels through a
// wall. Chunks that are not loaded count as solid: nobody falls out of the
// world they have.

PLAYER_WIDTH :: 0.6
PLAYER_HEIGHT :: 1.8
PLAYER_EYE :: 1.62
PITCH_LIMIT :: 1.56 // radians: looking straight up or down is not allowed

Button :: enum u8 {
	Jump,
	Sneak,
	Sprint,
	Toggle_Fly, // pressed this tick (the client turns a double-tapped jump into this)
}

Player_Input :: struct {
	move:    [2]f32, // x: right, y: forward; length at most 1
	yaw:     f32, // radians, turning left from -z
	pitch:   f32, // radians, up (only for looking; movement ignores it)
	buttons: bit_set[Button;u8],
}

Player_State :: struct {
	position:  [3]f64, // centre of the feet
	velocity:  [3]f32,
	on_ground: bool,
	flying:    bool,
}

// Block_Query reads the world for physics: loaded is false where the chunk
// is not loaded (treated as solid).
Block_Query :: struct {
	data: rawptr,
	get:  proc(data: rawptr, p: Block_Pos) -> (b: Block, loaded: bool),
}

// player_step advances the player by dt seconds (one tick).
player_step :: proc(
	s: ^Player_State,
	input: Player_Input,
	rules: ^Rules,
	q: Block_Query,
	dt: f32,
) {
	if !rules.allow_flying {
		s.flying = false
	} else if .Toggle_Fly in input.buttons {
		s.flying = !s.flying
	}
	move := input.move
	if l := math.sqrt(move.x * move.x + move.y * move.y); l > 1 {move /= l}
	forward := [2]f32{-math.sin(input.yaw), -math.cos(input.yaw)}
	right := [2]f32{math.cos(input.yaw), -math.sin(input.yaw)}
	wish := right * move.x + forward * move.y

	sprint, sneak, jump :=
		.Sprint in input.buttons, .Sneak in input.buttons, .Jump in input.buttons
	speed: f32
	switch {
	case s.flying:
		speed = rules.fly_sprint_speed if sprint else rules.fly_speed
	case sneak:
		speed = rules.sneak_speed
	case sprint:
		speed = rules.sprint_speed
	case:
		speed = rules.walk_speed
	}
	control := rules.ground_control if s.flying || s.on_ground else rules.air_control
	follow := 1 - math.exp(-control * dt)
	target := wish * speed
	s.velocity.x += (target.x - s.velocity.x) * follow
	s.velocity.z += (target.y - s.velocity.z) * follow
	vy_before: f32
	if s.flying {
		up: f32 = (1 if jump else 0) - (1 if sneak else 0)
		s.velocity.y += (up * speed - s.velocity.y) * follow
		vy_before = s.velocity.y
	} else {
		if s.on_ground && jump {s.velocity.y = math.sqrt(2 * rules.gravity * rules.jump_height)}
		vy_before = s.velocity.y
		s.velocity.y = max(s.velocity.y - rules.gravity * dt, -rules.terminal_velocity)
	}

	// Vertically, the average of the velocity before and after gravity: the
	// exact parabola, so jumps reach jump_height whatever the tick rate.
	vy := (vy_before + s.velocity.y) / 2
	delta := [3]f64{f64(s.velocity.x * dt), f64(vy * dt), f64(s.velocity.z * dt)}
	s.on_ground = false
	for axis in ([3]int{1, 0, 2}) {
		moved, hit := sweep(s.position, PLAYER_WIDTH, PLAYER_HEIGHT, axis, delta[axis], q)
		s.position[axis] += moved
		if hit {
			if axis == 1 && delta.y < 0 {s.on_ground = true}
			s.velocity[axis] = 0
		}
	}
	if s.flying && s.on_ground {s.flying = false} 	// landing ends flight
}

// player_box is the player's box at position (feet centre).
player_box :: proc(position: [3]f64) -> (lo, hi: [3]f64) {
	half :: PLAYER_WIDTH / 2
	return position - {half, 0, half}, position + {half, PLAYER_HEIGHT, half}
}

// solid_at: a block that stops movement (unloaded chunks too; above the
// world is open air, below it solid).
solid_at :: proc(q: Block_Query, p: Block_Pos) -> bool {
	if p.y >= WORLD_MAX_Y {return false}
	if p.y < WORLD_MIN_Y {return true}
	b, loaded := q.get(q.data, p)
	return !loaded || block_solid(b)
}

// sweep moves a box (width across, height up, position at the centre of
// its bottom) along one axis by up to delta and returns how far it got and
// whether a block stopped it. Players and entities share it.
sweep :: proc(
	position: [3]f64,
	width, height: f64,
	axis: int,
	delta: f64,
	q: Block_Query,
) -> (
	moved: f64,
	hit: bool,
) {
	if delta == 0 {return 0, false}
	EPS :: 1e-7 // touching a block's face is not overlapping it
	half := width / 2
	lo, hi := position - {half, 0, half}, position + {half, height, half}
	// The blocks the box covers on the other two axes.
	a1, a2 := (axis + 1) % 3, (axis + 2) % 3
	from1, to1 := i32(math.floor(lo[a1] + EPS)), i32(math.floor(hi[a1] - EPS))
	from2, to2 := i32(math.floor(lo[a2] + EPS)), i32(math.floor(hi[a2] - EPS))
	layer_solid :: proc(
		q: Block_Query,
		axis, a1, a2: int,
		layer, from1, to1, from2, to2: i32,
	) -> bool {
		for i in from1 ..= to1 {
			for j in from2 ..= to2 {
				p: Block_Pos
				p[axis], p[a1], p[a2] = layer, i, j
				if solid_at(q, p) {return true}
			}
		}
		return false
	}
	if delta > 0 {
		face := hi[axis]
		first := i32(math.floor(face - EPS)) + 1 // the first layer beyond the face
		last := i32(math.ceil(face + delta)) - 1
		for layer in first ..= last {
			if layer_solid(
				q,
				axis,
				a1,
				a2,
				layer,
				from1,
				to1,
				from2,
				to2,
			) {return f64(layer) - face, true}
		}
	} else {
		face := lo[axis]
		first := i32(math.floor(face + EPS)) - 1
		last := i32(math.floor(face + delta))
		for layer := first; layer >= last; layer -= 1 {
			if layer_solid(
				q,
				axis,
				a1,
				a2,
				layer,
				from1,
				to1,
				from2,
				to2,
			) {return f64(layer + 1) - face, true}
		}
	}
	return delta, false
}
