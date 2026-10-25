package client

import "core:math"

import "../ui"

// The menus' background (PLAN.md M20): a starfield drifting towards the
// viewer, a warp but slow and sparse: wonder, not hurry. Each star is a
// point in a box ahead of the camera; it comes nearer at STAR_SPEED, is drawn
// as a square of whole pixels growing as it nears, with a short fading
// trail behind it, and fades in from the distance (nothing pops). A star
// that passes the viewer or leaves the screen starts again far away.
// Settings' reduce_motion holds them still.

STARS :: 300
STAR_SPEED :: 0.05 // of the box's depth a second: about 20 s from far to near
STAR_NEAR :: 0.04 // depth at which a star has passed
STAR_TRAIL :: 3 // squares behind each star
STAR_TRAIL_STEP :: 0.012 // depth between them

Star :: struct {
	x, y: f32, // across the box, -1..1
	z:    f32, // depth, STAR_NEAR..1 (1: far)
	gone: bool, // drawn off the screen: starts again far away
}

Starfield :: struct {
	stars:  [STARS]Star,
	random: u32,
	seeded: bool,
}

@(private = "file")
star_random :: proc(f: ^Starfield) -> f32 {
	f.random = f.random * 1664525 + 1013904223
	return f32(f.random >> 8) / f32(1 << 24)
}

@(private = "file")
star_spawn :: proc(f: ^Starfield, s: ^Star, z: f32) {
	s.x = star_random(f) * 2 - 1
	s.y = star_random(f) * 2 - 1
	s.z = z
}

// starfield_update moves the stars on by dt seconds (none: reduce motion).
starfield_update :: proc(f: ^Starfield, dt: f32, still: bool) {
	if !f.seeded {
		f.random = 0x5eed
		for &s in f.stars {star_spawn(f, &s, STAR_NEAR + star_random(f) * (1 - STAR_NEAR))}
		f.seeded = true
	}
	if still {return}
	for &s in f.stars {
		s.z -= min(dt, 0.1) * STAR_SPEED
		if s.z < STAR_NEAR || s.gone {
			star_spawn(f, &s, 1)
			s.gone = false
		}
	}
}

// starfield_draw draws the stars over the whole screen (first: behind
// everything else).
starfield_draw :: proc(ctx: ^ui.Context, f: ^Starfield) {
	r := ctx.screen
	centre := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
	spread := max(r.w, r.h) * 0.28
	project :: proc(centre: ui.Vec2, spread: f32, s: Star, z: f32) -> ui.Vec2 {
		return centre + {s.x, s.y} / z * spread
	}
	for &s in f.stars {
		near := 1 - s.z // 0 far .. 1 near
		fade := math.smoothstep(f32(0), 0.35, near) // fading in from the distance
		size := math.floor(1 + near * 2.5) // whole pixels: crunchy
		for k := STAR_TRAIL; k >= 0; k -= 1 {
			z := s.z + f32(k) * STAR_TRAIL_STEP
			if z > 1 {continue}
			p := project(centre, spread, s, z)
			if p.x < r.x - 4 || p.y < r.y - 4 || p.x > r.x + r.w + 4 || p.y > r.y + r.h + 4 {
				if k == 0 {s.gone = true}
				continue
			}
			alpha := fade * (1 - f32(k) / f32(STAR_TRAIL + 1)) * 0.85
			grey := u8(200 + 55 * near)
			ui.fill_rect(
				ctx,
				{math.floor(p.x - size / 2), math.floor(p.y - size / 2), size, size},
				{grey, grey, grey, u8(alpha * 255)},
			)
		}
	}
}
