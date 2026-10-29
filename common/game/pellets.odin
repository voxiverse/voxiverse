package game

import "core:math"

import "../../base"

// The pattern of a shot's rays, one procedure for both sides: the server
// casts them, the client draws their tracers, and a seed gives the same rays
// on both (the numbers are the repo's own sin and cos, so on every platform).
// The seed is made of what both know: the shooter, the input sequence the
// Shoot message follows and the held slot.

// shot_seed: the seed of one shot.
shot_seed :: proc(player: u16, after: u32, slot: u8) -> u64 {
	return u64(player) << 40 ~ u64(after) << 8 ~ u64(slot) ~ 0x5DEECE66D
}

// aim_forward: the unit vector of a look (yaw turning left from -z, pitch up).
aim_forward :: proc(yaw, pitch: f32) -> [3]f64 {
	cp := base.cos(f64(pitch))
	return {-base.sin(f64(yaw)) * cp, base.sin(f64(pitch)), -base.cos(f64(yaw)) * cp}
}

// pellet_dirs: the rays of one shot of w aimed yaw/pitch: `pellets` of them
// (at least one), each inside a cone of `spread` radians around the aim,
// spread evenly over the disc by the seed.
pellet_dirs :: proc(
	seed: u64,
	yaw, pitch: f32,
	w: Weapon_Info,
) -> (
	dirs: [MAX_PELLETS][3]f64,
	count: int,
) {
	count = clamp(w.pellets, 1, MAX_PELLETS)
	for i in 0 ..< count {
		y, p := yaw, pitch
		if w.spread > 0 {
			h := (seed + u64(i) + 1) * 0x9E37_79B9_7F4A_7C15
			h ~= h >> 31
			h *= 0xD1B5_4A32_D192_ED03
			h ~= h >> 29
			radius := f64(w.spread) * math.sqrt(f64(h & 0xFFFF) / 65536)
			angle := f64((h >> 16) & 0xFFFF) / 65536 * math.TAU
			y += f32(radius * base.cos(angle))
			p = clamp(p + f32(radius * base.sin(angle)), -PITCH_LIMIT, PITCH_LIMIT)
		}
		dirs[i] = aim_forward(y, p)
	}
	return
}
