package client

import "core:math"
import "core:math/rand"
import "core:time"

import "../game"
import "../render"
import "mesh"

// Entities as the client shows them: interpolated like the other players
// (players.odin), drawn as boxes in the entity pass. A critter has a body,
// a head that grazes and looks about (the server's pitch), and four legs
// that swing as fast as it walks; it flashes red when hit and bursts into a
// puff of pixels when it dies.

HURT_FLASH :: 250 * time.Millisecond
PUFF_SECONDS :: 0.7
PUFF_PIECES :: 14
MAX_PUFFS :: 1024

// Puff: a particle, a piece of something (a dying entity, debris, smoke,
// flame) flying out and falling, or drifting and slowing. It shrinks as it
// ages.
Puff :: struct {
	position: [3]f64,
	velocity: [3]f32,
	age:      f32, // seconds
	life:     f32, // seconds it lasts
	size:     f32, // half-width, blocks
	gravity:  f32, // blocks/s²
	drag:     f32, // fraction of its speed lost per second
	color:    [4]u8,
}

// puff_add adds p, unless there are MAX_PUFFS already (then it is dropped:
// effects are not worth growing memory for).
puff_add :: proc(s: ^Session, p: Puff) {
	if len(s.puffs) < cap(s.puffs) {append(&s.puffs, p)}
}

@(private = "file")
SMOKE :: [4]u8{70, 68, 66, 255}
@(private = "file")
FLAME :: [4]u8{255, 170, 60, 255}

@(private = "file")
WOOL :: [4]u8{232, 222, 200, 255}
@(private = "file")
HIDE :: [4]u8{122, 92, 70, 255}
@(private = "file")
HURT :: [4]u8{236, 84, 72, 255}

// entities_draw adds the entities and puffs to the entity pass and moves
// the puffs on by dt.
entities_draw :: proc(s: ^Session, d: ^render.Entity_Draw, dt: f32) {
	now := session_others_now(s)
	for _, &e in s.entities {
		v, ok := track_view(&e.track, now)
		if !ok {continue}
		moved := v.position - e.last_seen
		e.stride += f32(math.sqrt(moved.x * moved.x + moved.z * moved.z))
		e.last_seen = v.position
		hurt := e.hurt_at != {} && time.tick_since(e.hurt_at) < HURT_FLASH
		switch e.kind {
		case .Critter:
			critter(d, v, e.stride, hurt)
		case .Rocket:
			rocket(s, d, v)
		case .Item:
			dropped_item(s, d, v, e.stack)
		}
	}
	for i := 0; i < len(s.puffs); {
		p := &s.puffs[i]
		p.age += dt
		if p.age > p.life {
			unordered_remove(&s.puffs, i)
			continue
		}
		p.velocity.y -= p.gravity * dt
		p.velocity *= max(1 - p.drag * dt, 0)
		p.position += {f64(p.velocity.x * dt), f64(p.velocity.y * dt), f64(p.velocity.z * dt)}
		size := p.size * (1 - p.age / p.life * 0.6)
		render.entity_box(d, p.position, 0, 0, -size, size, p.color, .Body)
		i += 1
	}
}

// critter: a body, a head on a neck that pitches, four legs that swing.
@(private = "file")
critter :: proc(d: ^render.Entity_Draw, v: Other_View, stride: f32, hurt: bool) {
	wool, hide := WOOL, HIDE
	if hurt {wool, hide = HURT, HURT}
	p := v.position
	render.entity_box(d, p, v.yaw, 0, {-0.35, 0.35, -0.5}, {0.35, 0.85, 0.45}, wool, .Body)
	neck := p + turn_yaw({0, 0.72, -0.45}, v.yaw)
	render.entity_box(d, neck, v.yaw, v.pitch, {-0.2, -0.2, -0.38}, {0.2, 0.2, 0.02}, hide, .Head)
	swing := math.sin(stride * 5) * 0.6 // radians, as it walks
	for leg in ([4][3]f32{{-0.22, 0.38, -0.32}, {0.22, 0.38, -0.32}, {-0.22, 0.38, 0.3}, {0.22, 0.38, 0.3}}) {
		hip := p + turn_yaw(leg, v.yaw)
		phase := swing if (leg.x < 0) == (leg.z < 0) else -swing
		render.entity_box(
			d,
			hip,
			v.yaw,
			phase,
			{-0.08, -0.38, -0.08},
			{0.08, 0, 0.08},
			hide,
			.Legs,
		)
	}
}

// rocket: a dark body with a hot tail, leaving smoke.
@(private = "file")
rocket :: proc(s: ^Session, d: ^render.Entity_Draw, v: Other_View) {
	centre := v.position + {0, 0.15, 0}
	render.entity_box(
		d,
		centre,
		v.yaw,
		v.pitch,
		{-0.1, -0.1, -0.35},
		{0.1, 0.1, 0.35},
		{60, 62, 70, 255},
		.Body,
	)
	tail := centre + turn_yaw({0, 0, 0.4}, v.yaw)
	render.entity_box(d, tail, v.yaw, v.pitch, -0.07, 0.07, FLAME, .Body)
	if rand.float32() < 0.6 {
		puff_add(
			s,
			Puff {
				position = tail,
				velocity = {
					rand.float32_range(-0.4, 0.4),
					rand.float32_range(0.2, 0.8),
					rand.float32_range(-0.4, 0.4),
				},
				life = 1.2,
				size = 0.12,
				drag = 2,
				color = SMOKE,
			},
		)
	}
}

// explosion_effects: the debris of what was there (the blocks are still
// the old ones: the bulk edit comes after), smoke, and the boom.
explosion_effects :: proc(s: ^Session, center: [3]f64, radius: f64) {
	for _ in 0 ..< min(60, (cap(s.puffs) - len(s.puffs)) / 2) {
		// A random point in the sphere; a piece of its block, flung out.
		p: [3]f64
		for {
			p = {rand.float64_range(-1, 1), rand.float64_range(-1, 1), rand.float64_range(-1, 1)}
			if p.x * p.x + p.y * p.y + p.z * p.z <= 1 {break}
		}
		at := center + p * radius
		b, _ := world_block(
			&s.world,
			{i32(math.floor(at.x)), i32(math.floor(at.y)), i32(math.floor(at.z))},
		)
		if !game.block_collides(b) {continue}
		out := [3]f32{f32(p.x), f32(p.y) + 0.6, f32(p.z)} * rand.float32_range(6, 14)
		puff_add(
			s,
			{
				position = at,
				velocity = out,
				life = rand.float32_range(0.8, 1.6),
				size = 0.11,
				gravity = 22,
				color = debris_colour(s, b),
			},
		)
	}
	for _ in 0 ..< 24 {
		dir := [3]f32 {
			rand.float32_range(-1, 1),
			rand.float32_range(-0.2, 1),
			rand.float32_range(-1, 1),
		}
		puff_add(
			s,
			{
				position = center,
				velocity = dir * f32(radius) * 1.6,
				life = rand.float32_range(1, 2),
				size = rand.float32_range(0.25, 0.45),
				drag = 2,
				color = SMOKE,
			},
		)
	}
	for _ in 0 ..< 10 {
		dir := [3]f32 {
			rand.float32_range(-1, 1),
			rand.float32_range(-1, 1),
			rand.float32_range(-1, 1),
		}
		puff_add(
			s,
			{
				position = center,
				velocity = dir * 8,
				life = 0.25,
				size = 0.3,
				drag = 2,
				color = FLAME,
			},
		)
	}
	append(&s.sounds, Sound_Event{.Explosion, .Air, center, 1})
}

// entity_died: its puff and its last sound.
entity_died :: proc(s: ^Session, e: ^Other_Entity) {
	at := e.last_seen
	for _ in 0 ..< PUFF_PIECES {
		angle := rand.float32_range(0, math.TAU)
		speed := rand.float32_range(1.5, 3.5)
		offset := [3]f64 {
			f64(rand.float32_range(-0.3, 0.3)),
			f64(rand.float32_range(0.3, 0.8)),
			f64(rand.float32_range(-0.3, 0.3)),
		}
		puff_add(
			s,
			{
				position = at + offset,
				velocity = {
					math.cos(angle) * speed,
					rand.float32_range(2, 5),
					math.sin(angle) * speed,
				},
				life = PUFF_SECONDS,
				size = 0.07,
				gravity = 18,
				color = WOOL if rand.float32() < 0.7 else HIDE,
			},
		)
	}
	append(&s.sounds, Sound_Event{.Entity_Die, .Air, at + {0, 0.5, 0}, 1})
}

// entity_aimed: the nearest entity on the ray within reach (and nearer
// than max_distance), if any.
entity_aimed :: proc(
	s: ^Session,
	origin, dir: [3]f64,
	max_distance: f64,
) -> (
	id: u32,
	distance: f64,
	ok: bool,
) {
	now := session_others_now(s)
	distance = max_distance
	for key, &e in s.entities {
		if !game.ENTITY_INFO[e.kind].hittable {continue}
		v, seen := track_view(&e.track, now)
		if !seen {continue}
		lo, hi := game.entity_box(e.kind, v.position)
		if d, hit := game.ray_box(origin, dir, lo, hi, distance); hit && d <= distance {
			id, distance, ok = key, d, true
		}
	}
	return
}

// turn_yaw turns an offset as a body facing yaw turns it.
@(private = "file")
turn_yaw :: proc(p: [3]f32, yaw: f32) -> [3]f64 {
	c, s := math.cos(yaw), math.sin(yaw)
	return {f64(p.x * c + p.z * s), f64(p.y), f64(-p.x * s + p.z * c)}
}

// dropped_item: a small cube of the item's colour, turning and bobbing
// (more of them stacked for a bigger stack).
@(private = "file")
dropped_item :: proc(s: ^Session, d: ^render.Entity_Draw, v: Other_View, stack: game.Stack) {
	info, _ := game.item_info(stack.item)
	colour := [4]u8{60, 60, 64, 255} // a tool
	if info.block != .Air {colour = block_colour(s, info.block)}
	t := f32(time.duration_seconds(time.tick_since({}))) // (any steady clock)
	spin := t * 1.5
	bob := f64(math.sin(t * 2.5) * 0.06 + 0.06)
	cubes := 1 if stack.count < 8 else (2 if stack.count < 32 else 3)
	for k in 0 ..< cubes {
		offset := [3]f64{f64(k) * 0.07, f64(k) * 0.05, f64(k) * -0.06}
		render.entity_box(
			d,
			v.position + {0, bob, 0} + offset,
			spin,
			0,
			{-0.12, 0, -0.12},
			{0.12, 0.24, 0.12},
			colour,
			.Body,
		)
	}
}

// block_colour: b's look in one colour (the average of its side).
@(private = "file")
block_colour :: proc(s: ^Session, b: game.Block) -> [4]u8 {
	side, _, _ := mesh.block_faces(b)
	sum: [3]u32
	n: u32
	for c in s.texels[side] {
		if c.a == 0 {continue}
		sum += {u32(c.r), u32(c.g), u32(c.b)}
		n += 1
	}
	if n == 0 {return {128, 128, 128, 255}}
	return {u8(sum.r / n), u8(sum.g / n), u8(sum.b / n), 255}
}

// debris_colour: a piece of b, broken up: one of the pixels of its side
// (not a hole in it).
@(private = "file")
debris_colour :: proc(s: ^Session, b: game.Block) -> [4]u8 {
	side, _, _ := mesh.block_faces(b)
	pixels := &s.texels[side]
	for _ in 0 ..< 8 {
		c := pixels[rand.int_max(len(pixels))]
		if c.a != 0 {return {c.r, c.g, c.b, 255}}
	}
	return {128, 128, 128, 255}
}
