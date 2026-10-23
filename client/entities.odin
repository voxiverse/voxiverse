package client

import "core:math"
import "core:math/rand"
import "core:time"

import "../game"
import "../render"

// Entities as the client shows them: interpolated like the other players
// (players.odin), drawn as boxes in the entity pass. A critter has a body,
// a head that grazes and looks about (the server's pitch), and four legs
// that swing as fast as it walks; it flashes red when hit and bursts into a
// puff of pixels when it dies.

HURT_FLASH :: 250 * time.Millisecond
PUFF_SECONDS :: 0.7
PUFF_PIECES :: 14

// Puff: one piece of a dying entity, flying out and falling.
Puff :: struct {
	position: [3]f64,
	velocity: [3]f32,
	age:      f32, // seconds
	color:    [4]u8,
}

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
		}
	}
	for i := 0; i < len(s.puffs); {
		p := &s.puffs[i]
		p.age += dt
		if p.age > PUFF_SECONDS {
			unordered_remove(&s.puffs, i)
			continue
		}
		p.velocity.y -= 18 * dt
		p.position += {f64(p.velocity.x * dt), f64(p.velocity.y * dt), f64(p.velocity.z * dt)}
		size := 0.07 * (1 - p.age / PUFF_SECONDS * 0.6)
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

// entity_died: its puff and its last sound.
entity_died :: proc(s: ^Session, e: ^Other_Entity) {
	at := e.last_seen
	for _ in 0 ..< PUFF_PIECES {
		angle := rand.float32_range(0, math.TAU)
		speed := rand.float32_range(1.5, 3.5)
		append(
			&s.puffs,
			Puff {
				position = at +
				{
						f64(rand.float32_range(-0.3, 0.3)),
						f64(rand.float32_range(0.3, 0.8)),
						f64(rand.float32_range(-0.3, 0.3)),
					},
				velocity = {
					math.cos(angle) * speed,
					rand.float32_range(2, 5),
					math.sin(angle) * speed,
				},
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
