package game

import "core:math"

// Block edits: the rules for breaking and placing, shared so the client only
// predicts edits the server will accept (and the server checks the same
// rules, from its own idea of where the player is).

// EDIT_REACH_SLACK: extra reach the server allows, since it measures from
// where it has the player, which can lag the client by the round trip.
EDIT_REACH_SLACK :: 1.5

// can_break: players may remove it (not air, not the floor of the world).
can_break :: proc(b: Block) -> bool {
	return BLOCK_INFO[b].breakable
}

// can_place: players may place it.
can_place :: proc(b: Block) -> bool {
	return BLOCK_INFO[b].placeable
}

// can_change: an edit (bulk, an explosion) may change it: what players may
// break, or what a placed block replaces (air, water).
can_change :: proc(b: Block) -> bool {
	return BLOCK_INFO[b].breakable || BLOCK_INFO[b].replaceable
}

// can_place_at: block may go at pos, where current is: current gives way
// to it, and the player is not standing there (unless block lets them
// through: a flower).
can_place_at :: proc(current, block: Block, pos: Block_Pos, player: Player_State) -> bool {
	if !BLOCK_INFO[current].replaceable || current == block {return false}
	if !BLOCK_INFO[block].collides {return true}
	lo, hi := player_box(player)
	b := [3]f64{f64(pos.x), f64(pos.y), f64(pos.z)}
	EPS :: 1e-6
	overlaps :=
		lo.x < b.x + 1 - EPS &&
		hi.x > b.x + EPS &&
		lo.y < b.y + 1 - EPS &&
		hi.y > b.y + EPS &&
		lo.z < b.z + 1 - EPS &&
		hi.z > b.z + EPS
	return !overlaps
}

// in_reach: the block's nearest point is within reach of the eyes.
in_reach :: proc(eye: [3]f64, pos: Block_Pos, reach: f64) -> bool {
	nearest: [3]f64
	for axis in 0 ..< 3 {
		lo := f64(pos[axis])
		nearest[axis] = clamp(eye[axis], lo, lo + 1)
	}
	d := nearest - eye
	return math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) <= reach
}

player_eye :: proc(s: Player_State) -> [3]f64 {
	return s.position + {0, player_eye_height(s), 0}
}
