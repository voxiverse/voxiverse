package game

import "core:math"

import "../../base"

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
//
// In water (at the feet or the chest) players swim: slower and more
// sluggish across, sinking slowly unless jump swims them up (or sneak
// down); at the surface beside a ledge, jump lifts them out.
//
// Sneaking (Minecraft's) crouches: the box is PLAYER_SNEAK_HEIGHT tall
// (under a gap a standing player does not fit), the eyes lower, walking
// slows, and on the ground a move that would step off an edge is cut back,
// axis by axis, so one can lean out over a ledge to build. Released, the
// player stands up once there is room.

PLAYER_WIDTH :: 0.6
PLAYER_HEIGHT :: 1.8
PLAYER_EYE :: 1.62
PLAYER_SNEAK_HEIGHT :: 1.5
PLAYER_SNEAK_EYE :: 1.27
EDGE_DROP :: 0.6 // sneaking: ground at most this far below the feet is ground to stay on
EDGE_STEP :: 0.05 // sneaking: a move off an edge is cut back in steps of this
PITCH_LIMIT :: 1.56 // radians: looking straight up or down is not allowed

SWIM_SPEED :: 2.6 // blocks/s across (sprinting: 1.5 times)
SWIM_CONTROL :: 4 // 1/s: how quickly swimming follows input
SWIM_UP :: 3.2 // blocks/s holding jump
SWIM_SINK :: 1.2 // blocks/s holding nothing
SWIM_DOWN :: 3 // blocks/s holding sneak
SWIM_CLIMB :: 1.2 // blocks above the water a swimmer against a wall can rise (a ledge one high)

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
	crouched:  bool, // sneaking: the lower box (player_height)
	jump_held: bool, // the jump button was down last tick (an air jump needs a new press)
	air_jumps: u8, // jumps in the air left (mods.air_jumps, given back on the ground)
}

// player_height: the player's box's height (crouched: lower).
player_height :: proc(s: Player_State) -> f64 {
	return PLAYER_SNEAK_HEIGHT if s.crouched else PLAYER_HEIGHT
}

// player_eye_height: how far above the feet the eyes are.
player_eye_height :: proc(s: Player_State) -> f64 {
	return PLAYER_SNEAK_EYE if s.crouched else PLAYER_EYE
}

// Block_Query reads the world for physics: loaded is false where the chunk
// is not loaded (treated as solid).
Block_Query :: struct {
	data:  rawptr,
	get:   proc(data: rawptr, p: Block_Pos) -> (b: Block, loaded: bool),
	table: ^Block_Table, // what the blocks are (the registry's)
}

// player_step advances the player by dt seconds (one tick).
player_step :: proc(
	s: ^Player_State,
	input: Player_Input,
	rules: ^Rules,
	q: Block_Query,
	dt: f32,
	mods := MODS_NONE,
) {
	if !rules.allow_flying {
		s.flying = false
	} else if .Toggle_Fly in input.buttons {
		s.flying = !s.flying
	}
	move := input.move
	if l := math.sqrt(move.x * move.x + move.y * move.y); l > 1 {move /= l}
	forward := [2]f32{-base.sin(input.yaw), -base.cos(input.yaw)}
	right := [2]f32{base.cos(input.yaw), -base.sin(input.yaw)}
	wish := right * move.x + forward * move.y

	sprint, sneak, jump :=
		.Sprint in input.buttons, .Sneak in input.buttons, .Jump in input.buttons
	feet_wet, chest_wet := in_water(q, s.position, 0.2), in_water(q, s.position, 1.2)
	swimming := !s.flying && (feet_wet || chest_wet)
	// Crouched while sneaking on foot; up again once a standing box fits.
	if sneak && !s.flying && !swimming {
		s.crouched = true
	} else if s.crouched &&
	   !box_blocked(
			   q,
			   s.position + {0, PLAYER_SNEAK_HEIGHT, 0},
			   PLAYER_WIDTH,
			   PLAYER_HEIGHT - PLAYER_SNEAK_HEIGHT,
		   ) {
		s.crouched = false
	}
	speed: f32
	switch {
	case swimming:
		speed = SWIM_SPEED * (1.5 if sprint else 1)
	case s.flying:
		speed = rules.fly_sprint_speed if sprint else rules.fly_speed
	case sneak:
		speed = rules.sneak_speed * mods.speed
	case sprint:
		speed = rules.sprint_speed * mods.speed
	case:
		speed = rules.walk_speed * mods.speed
	}
	control := rules.ground_control if s.flying || s.on_ground else rules.air_control
	if swimming {control = SWIM_CONTROL}
	follow := 1 - base.exp(-control * dt)
	target := wish * speed
	s.velocity.x += (target.x - s.velocity.x) * follow
	s.velocity.z += (target.y - s.velocity.z) * follow
	vy_before: f32
	if swimming {
		// Buoyant: the vertical speed eases towards the swim's, no gravity.
		target_vy: f32 = -SWIM_SINK
		if jump {target_vy = SWIM_UP} else if sneak {target_vy = -SWIM_DOWN}
		s.velocity.y += (target_vy - s.velocity.y) * (1 - base.exp(-SWIM_CONTROL * 2 * dt))
		if jump && against_wall(q, s.position, wish) {
			// Against a wall: up it, fast enough to rise SWIM_CLIMB out of
			// the water onto a ledge.
			s.velocity.y = math.sqrt(2 * rules.gravity * SWIM_CLIMB)
		}
		vy_before = s.velocity.y
	} else if s.flying {
		up: f32 = (1 if jump else 0) - (1 if sneak else 0)
		s.velocity.y += (up * speed - s.velocity.y) * follow
		vy_before = s.velocity.y
	} else {
		jump_speed := math.sqrt(2 * rules.gravity * rules.jump_height * mods.jump)
		if s.on_ground {s.air_jumps = mods.air_jumps}
		if s.on_ground && jump {
			s.velocity.y = jump_speed
		} else if jump && !s.jump_held && !s.on_ground && s.air_jumps > 0 {
			s.velocity.y = jump_speed // a new press in the air
			s.air_jumps -= 1
		}
		vy_before = s.velocity.y
		s.velocity.y = max(s.velocity.y - rules.gravity * dt, -rules.terminal_velocity)
	}

	// Vertically, the average of the velocity before and after gravity: the
	// exact parabola, so jumps reach jump_height whatever the tick rate.
	vy := (vy_before + s.velocity.y) / 2
	delta := [3]f64{f64(s.velocity.x * dt), f64(vy * dt), f64(s.velocity.z * dt)}
	edge_guard := s.on_ground && s.crouched && !swimming
	s.on_ground = false
	for axis in ([3]int{1, 0, 2}) {
		if axis != 1 && edge_guard && supported(q, s.position) {
			// Not off the edge: back off until the feet stay over ground.
			d := delta[axis]
			for d != 0 {
				p := s.position
				p[axis] += d
				if supported(q, p) {break}
				d = 0 if abs(d) <= EDGE_STEP else d - math.sign(d) * EDGE_STEP
			}
			if d != delta[axis] {s.velocity[axis] = 0}
			delta[axis] = d
		}
		moved, hit := sweep(s.position, PLAYER_WIDTH, player_height(s^), axis, delta[axis], q)
		s.position[axis] += moved
		if hit {
			if axis == 1 && delta.y < 0 {s.on_ground = true}
			s.velocity[axis] = 0
		}
	}
	if s.flying && s.on_ground {s.flying = false} 	// landing ends flight
	s.jump_held = jump
}

// player_box is the player's box (feet centre at its position).
player_box :: proc(s: Player_State) -> (lo, hi: [3]f64) {
	half :: PLAYER_WIDTH / 2
	return s.position - {half, 0, half}, s.position + {half, player_height(s), half}
}

// supported: ground under a player's feet at position, within EDGE_DROP.
@(private = "file")
supported :: proc(q: Block_Query, position: [3]f64) -> bool {
	return box_blocked(q, position - {0, EDGE_DROP, 0}, PLAYER_WIDTH, EDGE_DROP)
}

// box_blocked: a block that stops movement overlaps the box (width across,
// height up from position, the centre of its bottom).
@(private = "file")
box_blocked :: proc(q: Block_Query, position: [3]f64, width, height: f64) -> bool {
	EPS :: 1e-7 // touching is not overlapping
	half := width / 2
	lo := [3]f64{position.x - half, position.y, position.z - half} + EPS
	hi := [3]f64{position.x + half, position.y + height, position.z + half} - EPS
	for y in i32(math.floor(lo.y)) ..= i32(math.floor(hi.y)) {
		for z in i32(math.floor(lo.z)) ..= i32(math.floor(hi.z)) {
			for x in i32(math.floor(lo.x)) ..= i32(math.floor(hi.x)) {
				if solid_at(q, {x, y, z}) {return true}
			}
		}
	}
	return false
}

// in_water: the block at height above the feet is water.
in_water :: proc(q: Block_Query, position: [3]f64, height: f64) -> bool {
	p := Block_Pos {
		i32(math.floor(position.x)),
		i32(math.floor(position.y + height)),
		i32(math.floor(position.z)),
	}
	b, loaded := q.get(q.data, p)
	_, water := water_level(b)
	return loaded && water
}

// against_wall: a block stands just ahead of the player (the way they move)
// at their feet: a ledge to climb out onto.
@(private = "file")
against_wall :: proc(q: Block_Query, position: [3]f64, wish: [2]f32) -> bool {
	l := math.sqrt(wish.x * wish.x + wish.y * wish.y)
	if l < 1e-3 {return false}
	ahead :=
		position +
		{
				f64(wish.x / l) * (PLAYER_WIDTH / 2 + 0.2),
				0.2,
				f64(wish.y / l) * (PLAYER_WIDTH / 2 + 0.2),
			}
	return solid_at(
		q,
		{i32(math.floor(ahead.x)), i32(math.floor(ahead.y)), i32(math.floor(ahead.z))},
	)
}

// solid_at: a block that stops movement (unloaded chunks too; above the
// world is open air, below it solid).
solid_at :: proc(q: Block_Query, p: Block_Pos) -> bool {
	if p.y >= WORLD_MAX_Y {return false}
	if p.y < WORLD_MIN_Y {return true}
	b, loaded := q.get(q.data, p)
	return !loaded || block_collides(q.table, b)
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
