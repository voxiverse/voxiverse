package engine

import "core:math"

import "common:base"
import "common:game"

// The feel kit (docs/games.md, "Feel"): the short, small feedback a game's client part gives
// what happens in it, a line a call: a burst of particles, a flash on a creature. It is
// presentation only: nothing is sent, saved or simulated, and the server never knows.
//
// Every effect is timed by the feel clock (Feel.clock), which follows the server's ticks as
// they are heard rather than the wall clock: it runs with the frames, never more than
// FEEL_LEAD ticks ahead of the newest tick heard nor FEEL_LAG behind it. So a world that
// stands still (paused) holds its effects where they are, and a screenshot script's `ticks
// <n>` (the server hurried) finds an effect as far through as the ticks put it, to within a
// tick or two, however long the frames took.

FEEL_LEAD :: 3 // ticks the feel clock may run ahead of the newest tick heard (the network's jitter)
FEEL_LAG :: 1 // ... and behind it (it catches up at once: a hurried server)

// Feel: the session's feedback under way.
Feel :: struct {
	clock:       f64, // ticks: the feel clock (feel_advance)
	burst_puffs: int, // live puffs bursts made (at most MAX_BURST_PUFFS)
}

// feel_advance: a frame of dt seconds on the feel clock (session_update, after the messages
// are taken: the newest tick heard bounds it).
feel_advance :: proc(s: ^Session, dt: f32) {
	f := &s.feel
	f.clock += f64(dt) * game.TICK_RATE
	if c := &s.render_clock; c.heard {
		newest := f64(c.newest)
		f.clock = clamp(f.clock, newest - FEEL_LAG, newest + FEEL_LEAD)
	}
}

// feel_now: the feel clock's time for an effect that starts now: the tick of the message
// being taken, while one is (an effect of a hurried tick starts at its tick), else the clock.
feel_now :: proc(s: ^Session) -> f64 {
	return max(s.feel.clock, f64(s.rx.tick))
}

// feel_age: seconds on the feel clock since `from` (a feel_now), never less than 0.
feel_age :: proc(s: ^Session, from: f64) -> f32 {
	return f32(max(s.feel.clock - from, 0) / game.TICK_RATE)
}

// ---------------------------------------------------------------------------
// Bursts: a handful of puffs flung out of a point
// ---------------------------------------------------------------------------

// Burst: what a burst of particles looks like (burst).
Burst :: enum u8 {
	Impact, // a blow landing: chips of what was hit (its colour, or a material's: block_colour)
	Sparks, // metal on metal, a shot on stone: quick bright specks
	Smoke, // a puff of smoke drifting up: a machine placed, a thing gone
	Sparkle, // a pickup, a purchase: specks rising and fading
	Death, // a creature undone: pieces flung up and falling
	Splash, // water thrown up
}

// MAX_BURST_PUFFS: the puffs bursts may have alive at once, of the MAX_PUFFS every effect
// shares: a burst past it makes fewer pieces, or none, so no game can crowd out the
// engine's own effects or slow the frame.
MAX_BURST_PUFFS :: 256

// Burst_Look: a preset's pieces: how many, how fast and how long, as ranges each piece
// draws from.
@(private = "file")
Burst_Look :: struct {
	pieces:  int,
	speed:   [2]f32, // blocks a second, outward
	lift:    [2]f32, // ... and upward
	life:    [2]f32, // seconds
	size:    [2]f32, // half-width, blocks
	spread:  f32, // the radius they start within, blocks
	gravity: f32, // blocks/s² (below 0: they rise)
	drag:    f32,
	color:   [4]u8, // when the call gives none
}

@(private = "file", rodata)
BURSTS := [Burst]Burst_Look {
	.Impact = {
		pieces = 8,
		speed = {1.5, 3},
		lift = {1, 2.5},
		life = {0.25, 0.45},
		size = {0.035, 0.06},
		spread = 0.1,
		gravity = 16,
		drag = 1,
		color = {200, 190, 170, 255},
	},
	.Sparks = {
		pieces = 10,
		speed = {3, 6},
		lift = {0.5, 2},
		life = {0.12, 0.28},
		size = {0.02, 0.035},
		spread = 0.05,
		gravity = 10,
		drag = 3,
		color = {255, 214, 110, 255},
	},
	.Smoke = {
		pieces = 6,
		speed = {0.3, 0.8},
		lift = {0.4, 1},
		life = {0.6, 1},
		size = {0.12, 0.2},
		spread = 0.2,
		drag = 2,
		color = {128, 124, 118, 255},
	},
	.Sparkle = {
		pieces = 10,
		speed = {0.3, 1},
		lift = {0.8, 1.6},
		life = {0.45, 0.75},
		size = {0.025, 0.045},
		spread = 0.25,
		gravity = -0.5,
		drag = 2.5,
		color = {255, 232, 130, 255},
	},
	.Death = {
		pieces = 16,
		speed = {1.5, 3.5},
		lift = {2, 4.5},
		life = {0.5, 0.8},
		size = {0.05, 0.08},
		spread = 0.3,
		gravity = 18,
		drag = 0.5,
		color = {150, 150, 150, 255},
	},
	.Splash = {
		pieces = 12,
		speed = {0.8, 2},
		lift = {2.5, 4},
		life = {0.4, 0.7},
		size = {0.035, 0.06},
		spread = 0.2,
		gravity = 20,
		drag = 0.5,
		color = {96, 146, 220, 255},
	},
}

// burst: a burst of particles at `at` as the preset kind looks, in color (zero: the preset's
// own; a material's dust: block_colour), scale times as far and as big (a boss's death);
// fewer pieces, or none, when bursts have MAX_BURST_PUFFS alive already.
burst :: proc(s: ^Session, at: [3]f64, kind: Burst, color := [4]u8{}, scale: f32 = 1) {
	look := BURSTS[kind]
	tint := color if color.a != 0 else look.color
	rng := base.cosmetic_rng()
	pieces := min(look.pieces, MAX_BURST_PUFFS - s.feel.burst_puffs)
	for _ in 0 ..< pieces {
		angle := base.rng_f32_range(rng, 0, math.TAU)
		out := base.rng_f32_range(rng, look.speed[0], look.speed[1]) * scale
		start := [3]f64 {
			f64(math.cos(angle) * look.spread * scale),
			f64(base.rng_f32_range(rng, -0.5, 0.5) * look.spread * scale),
			f64(math.sin(angle) * look.spread * scale),
		}
		// (each piece a shade lighter or darker, so a burst is not one flat colour)
		shade := base.rng_f32_range(rng, 0.85, 1.12)
		c := tint
		for k in 0 ..< 3 {c[k] = u8(clamp(f32(c[k]) * shade, 0, 255))}
		if !puff_add(
			s,
			{
				position = at + start,
				velocity = {
					math.cos(angle) * out,
					base.rng_f32_range(rng, look.lift[0], look.lift[1]) * scale,
					math.sin(angle) * out,
				},
				life = base.rng_f32_range(rng, look.life[0], look.life[1]),
				size = base.rng_f32_range(rng, look.size[0], look.size[1]) * scale,
				gravity = look.gravity,
				drag = look.drag,
				color = c,
				burst = true,
			},
		) {break}
		s.feel.burst_puffs += 1
	}
}

// ---------------------------------------------------------------------------
// Flashes on creatures
// ---------------------------------------------------------------------------

ENTITY_FLASH_SECONDS :: 0.25

// entity_flash: the entity drawn in color for a moment (ENTITY_FLASH_SECONDS): red as every
// creature is when hurt, white for a critical blow, gold for a level gained.
entity_flash :: proc(s: ^Session, id: u32, color: [4]u8) {
	if e, known := &s.entities[id]; known {
		e.flash_at, e.flash_color = feel_now(s), color
	}
}

// entity_flashing: the colour an entity is drawn in now, if it flashes.
@(private)
entity_flashing :: proc(s: ^Session, e: ^Other_Entity) -> (color: [4]u8, ok: bool) {
	if e.flash_color.a == 0 || feel_age(s, e.flash_at) >= ENTITY_FLASH_SECONDS {return}
	return e.flash_color, true
}
