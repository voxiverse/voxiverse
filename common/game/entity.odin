package game

import "core:math"

import "common:base"

// Entities: things in the world other than blocks and players (for now one
// kind, the sheep). The server simulates them (server/core/entities.odin) and
// tells each client about the ones near it; both sides share these
// definitions and the physics.

// Entity kinds are the registry's (registry_entities.odin, data/entities/*.json): a
// Kind_Id names one, kind_info reads its numbers.

// Entity_Body: where an entity is and how it moves.
Entity_Body :: struct {
	position:  [3]f64, // centre of its bottom
	velocity:  [3]f32,
	on_ground: bool,
}

// kind_box: a kind's box (width, height) in f64. The pack's numbers are f32 and short
// decimals; rounding to six places gives back the f64 the physics was always tuned
// with (0.8, not 0.800000011920929), so the simulation's results do not move.
kind_box :: proc(info: ^Kind_Info) -> [2]f64 {
	return {math.round(f64(info.box[0]) * 1e6) / 1e6, math.round(f64(info.box[1]) * 1e6) / 1e6}
}

// body_step moves an entity by dt: its velocity follows wish (horizontal,
// blocks/s) on the ground (slowly in the air), gravity pulls it, jump
// leaps when on the ground; blocks stop it as they stop players.
body_step :: proc(
	b: ^Entity_Body,
	info: ^Kind_Info,
	wish: [2]f32,
	jump: bool,
	rules: ^Rules,
	q: Block_Query,
	dt: f32,
) {
	control := rules.ground_control if b.on_ground else rules.air_control
	follow := 1 - base.exp(-control * dt)
	b.velocity.x += (wish.x - b.velocity.x) * follow
	b.velocity.z += (wish.y - b.velocity.z) * follow
	if b.on_ground && jump {b.velocity.y = math.sqrt(2 * rules.gravity * info.walker.jump)}
	vy_before := b.velocity.y
	b.velocity.y = max(b.velocity.y - rules.gravity * dt, -rules.terminal_velocity)
	vy := (vy_before + b.velocity.y) / 2
	delta := [3]f64{f64(b.velocity.x * dt), f64(vy * dt), f64(b.velocity.z * dt)}
	c := collide_move(
		q,
		b.position,
		kind_box(info)[0] / 2,
		kind_box(info)[1],
		delta,
		b.velocity,
		0,
	)
	b.position, b.velocity, b.on_ground = c.position, c.velocity, c.on_ground
}

// entity_box is an entity's box at position.
entity_box :: proc(info: ^Kind_Info, position: [3]f64) -> (lo, hi: [3]f64) {
	box := kind_box(info)
	half := box[0] / 2
	return position - {half, 0, half}, position + {half, box[1], half}
}

// ray_box: where a ray (unit dir) from origin enters the box, if it does
// within max_distance (0 if it starts inside).
ray_box :: proc(origin, dir: [3]f64, lo, hi: [3]f64, max_distance: f64) -> (f64, bool) {
	enter, leave := 0.0, max_distance
	for i in 0 ..< 3 {
		if dir[i] == 0 {
			if origin[i] < lo[i] || origin[i] > hi[i] {return 0, false}
			continue
		}
		a, b := (lo[i] - origin[i]) / dir[i], (hi[i] - origin[i]) / dir[i]
		enter, leave = max(enter, min(a, b)), min(leave, max(a, b))
	}
	return enter, enter <= leave
}

// ATTACK_KNOCKBACK: how hard a hit pushes (blocks/s, away and up).
ATTACK_KNOCKBACK :: [2]f32{6, 5}
