package client

import "core:math"

import "../ui"

// The menus' background (PLAN.md M20): a starfield streaming towards the
// viewer, a warp, unhurried. Each star is a point in a box ahead of the
// camera coming nearer at STAR_SPEED; it is drawn as a streak of whole
// pixels (crunchy, never smoothed) from where it was STAR_TRAIL ago to
// where it is, brightest at the head, fading in from the distance so
// nothing pops. Most are white; some carry a faint tint. A star that
// passes the viewer or leaves the screen starts again far away. Settings'
// reduce_motion holds them still (points, no streaks).

STARS :: 260
STAR_SPEED :: 0.16 // of the box's depth a second: about 6 s from far to near
STAR_NEAR :: 0.04 // depth at which a star has passed
STAR_TRAIL :: 0.035 // depth behind the head the streak reaches back
STAR_STREAK_MAX :: 90 // pixels: the longest streak (the nearest stars)

// STAR_TINTS: a star's colour, picked at its start: white mostly, then
// pale blue, warm gold and a little violet; never saturated.
@(rodata)
STAR_TINTS := [?][3]u8 {
	{255, 255, 255},
	{255, 255, 255},
	{255, 255, 255},
	{165, 195, 255},
	{140, 180, 255},
	{255, 214, 150},
	{255, 190, 140},
	{200, 165, 255},
}

Star :: struct {
	x, y: f32, // across the box, -1..1
	z:    f32, // depth, STAR_NEAR..1 (1: far)
	tint: u8, // index into STAR_TINTS
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
	s.tint = u8(star_random(f) * len(STAR_TINTS)) % len(STAR_TINTS)
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
// everything else); still: points only.
starfield_draw :: proc(ctx: ^ui.Context, f: ^Starfield, still := false) {
	r := ctx.screen
	centre := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
	spread := max(r.w, r.h) * 0.28
	for &s in f.stars {
		head := centre + {s.x, s.y} / s.z * spread
		if head.x < r.x - 2 ||
		   head.y < r.y - 2 ||
		   head.x > r.x + r.w + 2 ||
		   head.y > r.y + r.h + 2 {
			s.gone = true
			continue
		}
		near := 1 - s.z // 0 far .. 1 near
		fade := math.smoothstep(f32(0), 0.4, near) // in from the distance
		tint := STAR_TINTS[s.tint]
		colour :: proc(tint: [3]u8, a: f32) -> ui.Color {
			return {tint.r, tint.g, tint.b, u8(clamp(a, 0, 1) * 255)}
		}
		// The streak: a pixel per step from the tail to the head, fading
		// towards the tail.
		if !still {
			tail := centre + {s.x, s.y} / min(s.z + STAR_TRAIL, 1.2) * spread
			d := head - tail
			steps := min(int(max(abs(d.x), abs(d.y))), STAR_STREAK_MAX)
			for i in 0 ..< steps {
				k := f32(i) / f32(steps) // 0 tail .. 1 head
				p := tail + d * k
				ui.fill_rect(
					ctx,
					{math.floor(p.x), math.floor(p.y), 1, 1},
					colour(tint, fade * k * k * 0.8),
				)
			}
		}
		// The head: a square of whole pixels, larger as it nears.
		size := math.floor(1 + near * near * 2.5)
		ui.fill_rect(
			ctx,
			{math.floor(head.x - size / 2), math.floor(head.y - size / 2), size, size},
			colour(tint, fade * (0.55 + 0.45 * near)),
		)
	}
}
