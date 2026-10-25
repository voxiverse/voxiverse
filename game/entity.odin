package game

import "core:math"

// Entities: things in the world other than blocks and players (for now one
// kind, the critter). The server simulates them (server/entities.odin) and
// tells each client about the ones near it; both sides share these
// definitions and the physics.

Entity_Kind :: enum u8 {
	Critter, // a passive, boxy animal: wanders, grazes, runs away when hit
	Rocket, // the creative rocket launcher's: flies, then explodes
	Item, // a dropped stack: falls, merges with its kind, picked up by walking over it
}

Entity_Info :: struct {
	name:       string,
	width:      f64, // box across (x and z)
	height:     f64,
	health:     int, // hits it takes
	walk_speed: f32, // blocks/s
	run_speed:  f32, // fleeing
	jump:       f32, // blocks it can jump up
	saved:      bool, // kept with the world (a rocket in flight is not)
	summonable: bool, // `summon <name>` makes one
	hittable:   bool, // players, rockets and explosions hit it
}

@(rodata)
ENTITY_INFO := [Entity_Kind]Entity_Info {
	.Critter = {
		name = "critter",
		width = 0.8,
		height = 0.9,
		health = 4,
		walk_speed = 1.4,
		run_speed = 4.2,
		jump = 1.2,
		saved = true,
		summonable = true,
		hittable = true,
	},
	.Rocket = {name = "rocket", width = 0.3, height = 0.3, health = 1},
	.Item = {name = "item", width = 0.25, height = 0.25, health = 1, saved = true},
}

ROCKET_SPEED :: 32 // blocks/s
ROCKET_GRAVITY :: 3 // blocks/s²: a slight drop
ROCKET_RADIUS :: 4 // blocks carved
ROCKET_LIFE :: 6 // seconds: then it goes off where it is

ITEM_PICKUP_DELAY :: 0.5 // seconds before a dropped stack can be picked up (by its dropper: 2)
ITEM_PICKUP_RANGE :: 1.5 // blocks from a player's feet
ITEM_MERGE_RANGE :: 1.0 // blocks: stacks of one item this near become one
ITEM_LIFE :: 300 // seconds: then a dropped stack is gone
ITEM_THROW :: 9 // blocks/s: a stack a player drops flies ahead

entity_kind_valid :: proc(k: u8) -> bool {
	return int(k) < len(Entity_Kind)
}

// Entity_Body: where an entity is and how it moves.
Entity_Body :: struct {
	position:  [3]f64, // centre of its bottom
	velocity:  [3]f32,
	on_ground: bool,
}

// body_step moves an entity by dt: its velocity follows wish (horizontal,
// blocks/s) on the ground (slowly in the air), gravity pulls it, jump
// leaps when on the ground; blocks stop it as they stop players.
body_step :: proc(
	b: ^Entity_Body,
	kind: Entity_Kind,
	wish: [2]f32,
	jump: bool,
	rules: ^Rules,
	q: Block_Query,
	dt: f32,
) {
	info := ENTITY_INFO[kind]
	control := rules.ground_control if b.on_ground else rules.air_control
	follow := 1 - math.exp(-control * dt)
	b.velocity.x += (wish.x - b.velocity.x) * follow
	b.velocity.z += (wish.y - b.velocity.z) * follow
	if b.on_ground && jump {b.velocity.y = math.sqrt(2 * rules.gravity * info.jump)}
	vy_before := b.velocity.y
	b.velocity.y = max(b.velocity.y - rules.gravity * dt, -rules.terminal_velocity)
	vy := (vy_before + b.velocity.y) / 2
	delta := [3]f64{f64(b.velocity.x * dt), f64(vy * dt), f64(b.velocity.z * dt)}
	b.on_ground = false
	for axis in ([3]int{1, 0, 2}) {
		moved, hit := sweep(b.position, info.width, info.height, axis, delta[axis], q)
		b.position[axis] += moved
		if hit {
			if axis == 1 && delta.y < 0 {b.on_ground = true}
			b.velocity[axis] = 0
		}
	}
}

// entity_box is an entity's box at position.
entity_box :: proc(kind: Entity_Kind, position: [3]f64) -> (lo, hi: [3]f64) {
	info := ENTITY_INFO[kind]
	half := info.width / 2
	return position - {half, 0, half}, position + {half, info.height, half}
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
