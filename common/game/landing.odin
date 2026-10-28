package game

import "core:math"

// Landings: where a player arriving somewhere (joining, a teleport, a
// spawn) stands, so nobody arrives inside blocks. The server finds it once
// the blocks there are loaded.

Landing_Mode :: enum u8 {
	Exact, // there, or the nearest free spot above
	Ground, // on the highest ground of the column (at or below there)
}

// LANDING_REACH: how far a landing looks up (Exact) for a free spot.
LANDING_REACH :: 64

// fits: a player's feet and head at feet are in no block (water is fine).
fits :: proc(q: Block_Query, feet: Block_Pos) -> (fits: bool, loaded: bool) {
	for dy in i32(0) ..< 2 {
		p := feet + {0, dy, 0}
		if p.y >= WORLD_MAX_Y {continue}
		if p.y < WORLD_MIN_Y {return false, true}
		b, ok := q.get(q.data, p)
		if !ok {return false, false}
		if block_collides(q.table, b) {return false, true}
	}
	return true, true
}

// landing_spot: where a player arriving at p stands (feet, the block's
// middle across), or false while a block it must see is not loaded.
// Ground: down from p to the first block that stops a player or is water
// (standing on it, or swimming in it); Exact: p if the player fits there,
// else up to the first spot where they do.
landing_spot :: proc(q: Block_Query, p: [3]f64, mode: Landing_Mode) -> ([3]f64, bool) {
	feet := Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	feet.y = clamp(feet.y, WORLD_MIN_Y + 1, WORLD_MAX_Y - 1)
	switch mode {
	case .Exact:
		for dy in i32(0) ..< LANDING_REACH {
			at := feet + {0, dy, 0}
			if at.y >= WORLD_MAX_Y {break}
			ok, loaded := fits(q, at)
			if !loaded {return {}, false}
			if ok {
				y := p.y if dy == 0 else f64(at.y)
				return {p.x, y, p.z}, true
			}
		}
		return {p.x, f64(WORLD_MAX_Y), p.z}, true // (nowhere fits: above everything)
	case .Ground:
		for y := feet.y; y > WORLD_MIN_Y; y -= 1 {
			below, ok := q.get(q.data, {feet.x, y - 1, feet.z})
			if !ok {return {}, false}
			_, water := water_level(below)
			if !block_collides(q.table, below) && !water {continue}
			if water {y -= 1} 	// in it, the head above the surface
			// Ground found: stand on it, or (under a ledge) where they fit.
			return landing_spot(q, {p.x, f64(y), p.z}, .Exact)
		}
		return landing_spot(q, {p.x, f64(WORLD_MIN_Y + 1), p.z}, .Exact)
	}
	return p, true
}
