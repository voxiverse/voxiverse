package atmosphere

import "core:math"

import "client:render"
import "common:game"

// What falls, as drops for render's weather pass: a grid of columns round the
// eye, each with a few drops falling through a band of height that follows the
// eye, at places and phases drawn from the column, so they are the same from
// frame to frame and move only by falling. A drop below its column's top (the
// highest block that stops the sky's light: a roof, a tree's crown, the rock
// over a cave) is not drawn: one look-up a column, so rain stops under cover
// and never falls through a roof.

RAIN_RADIUS :: 14 // blocks round the eye that rain falls in
SNOW_RADIUS :: 12
FALL_ABOVE :: 18 // the band drops fall through: from this far above the eye ...
FALL_BELOW :: 8 // ... to this far below
RAIN_SPEED :: 15 // blocks a second
SNOW_SPEED :: 1.6
ASH_SPEED :: 1.1 // ash drifts down slower than snow, in flakes of grey
RAIN_PER_COLUMN :: 3 // drops a column holds in the heaviest fall
SNOW_PER_COLUMN :: 2
ASH_PER_COLUMN :: 3 // (a thicker fall of larger flakes than snow's)

// Column_Top: the top of block column (x, z) (game's column top: rain stops on it),
// false when it is not known (not loaded: nothing falls there).
Column_Top :: proc(data: rawptr, x, z: i32) -> (top: i32, ok: bool)

// sheltered: whether a drop at height y falls in a column whose top is `top` (it has
// landed, or is under a roof).
sheltered :: proc(top: i32, y: f64) -> bool {
	return y < f64(top) + 1
}

// drops_make adds this frame's drops to d (at most render.MAX_DROPS in all) and
// returns how many: what falls (none, rain, snow, ash) and how hard (0..1), the wind
// (x, z, blocks a second), the eye, the seconds the animation has run.
drops_make :: proc(
	d: ^render.Weather_Draw,
	kind: game.Precipitation,
	amount: f32,
	wind: [2]f32,
	eye: [3]f64,
	seconds: f64,
	tops: Column_Top,
	data: rawptr,
) -> int {
	if kind == .None || amount <= 0 {return 0}
	snow := kind == .Snow || kind == .Ash // (ash falls as snow does, slower and grey)
	radius: i32 = SNOW_RADIUS if snow else RAIN_RADIUS
	speed := f64(SNOW_SPEED if snow else RAIN_SPEED)
	per := f32(SNOW_PER_COLUMN if snow else RAIN_PER_COLUMN) * clamp(amount, 0, 1)
	if kind == .Ash {speed, per = ASH_SPEED, ASH_PER_COLUMN * clamp(amount, 0, 1)}
	span := f64(FALL_ABOVE + FALL_BELOW)
	ex, ez := i32(math.floor(eye.x)), i32(math.floor(eye.z))
	made := 0
	for dz in -radius ..= radius {
		for dx in -radius ..= radius {
			if dx * dx + dz * dz > radius * radius {continue}
			x, z := ex + dx, ez + dz
			top, known := tops(data, x, z)
			if !known {continue}
			h := column_hash(x, z)
			// A column holds per drops on average: whole ones, and one more by chance.
			count := int(per)
			if unit(h, 0) < per - f32(count) {count += 1}
			for k in 0 ..< count {
				g := column_hash(x + i32(k) * 7919, z - i32(k) * 104729)
				phase := f64(unit(g, 0))
				fall := math.mod(
					seconds * speed * (0.85 + 0.3 * f64(unit(g, 8))) + phase * span,
					span,
				)
				y := eye.y + FALL_ABOVE - fall
				if sheltered(top, y) {continue}
				at := [3]f64{f64(x) + f64(unit(g, 16)), y, f64(z) + f64(unit(g, 24))}
				if near_eye(at - eye) {continue} 	// (one in the face is a blot, not a drop)
				drop: render.Drop
				if snow {
					sway := f32(seconds) * 1.3 + f32(phase) * 6.28
					at.x += f64(math.sin(sway) * 0.3 + wind.x * 0.15)
					at.z += f64(math.cos(sway * 0.8) * 0.3 + wind.y * 0.15)
					size := 0.06 + 0.05 * unit(g, 4)
					color := [4]u8{245, 248, 255, 230}
					if kind == .Ash {
						size = 0.09 + 0.1 * unit(g, 4)
						// Greys from soot to pale cinder, an ember now and then.
						grey := u8(90 + 120 * unit(g, 12))
						color = {grey, grey - grey / 12, grey - grey / 8, 235}
						if unit(g, 20) < 0.04 {color = {235, 120, 50, 240}}
					}
					drop = {
						at     = at,
						height = size,
						width  = size,
						color  = color,
						shape  = .Flake,
					}
				} else {
					length := f32(0.5 + 0.35 * unit(g, 4))
					// The streak's bottom stops on the ground or roof under it.
					if at.y < f64(top) + 1 + f64(length) {length = f32(at.y - f64(top) - 1)}
					if length < 0.05 {continue}
					lean := wind * (length / RAIN_SPEED)
					near := f32(dx * dx + dz * dz) / f32(radius * radius)
					drop = {
						at     = at,
						lean   = lean,
						height = length,
						width  = 0.035,
						color  = {185, 200, 225, u8(190 - 90 * near)},
						shape  = .Streak,
					}
				}
				if !render.weather_drop(d, drop) {return made}
				made += 1
			}
		}
	}
	return made
}

// NEAR_EYE: drops nearer the eye than this are left out.
NEAR_EYE :: 1.2

@(private = "file")
near_eye :: proc(d: [3]f64) -> bool {
	return d.x * d.x + d.y * d.y + d.z * d.z < NEAR_EYE * NEAR_EYE
}

// column_hash: a column's own scramble, the same every frame.
@(private = "file")
column_hash :: proc(x, z: i32) -> u32 {
	h := u32(x) * 0x8da6b343 ~ u32(z) * 0xd8163841
	h ~= h >> 15
	h *= 0x2c1b3c6d
	h ~= h >> 12
	h *= 0x297a2d39
	h ~= h >> 15
	return h
}

@(private = "file")
unit :: proc(h: u32, shift: u32) -> f32 {
	return f32((h >> shift) & 0xff) / 256
}
