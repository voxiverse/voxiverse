package game

import "core:math"

// Block edits: the rules for breaking and placing, shared so the client only
// predicts edits the server will accept (and the server checks the same
// rules, from its own idea of where the player is).

// EDIT_REACH_SLACK: extra reach the server allows, since it measures from
// where it has the player, which can lag the client by the round trip.
EDIT_REACH_SLACK :: 1.5

// can_break: players may remove it (not air, not the floor of the world).
can_break :: proc(t: ^Block_Table, b: Block) -> bool {
	return block_has(t, b, .Breakable)
}

// can_place: players may place it.
can_place :: proc(t: ^Block_Table, b: Block) -> bool {
	return block_has(t, b, .Placeable) || b == .Wheat_0 // (seeds)
}

// can_change: an edit (bulk, an explosion) may change it: what players may
// break, or what a placed block replaces (air, water).
can_change :: proc(t: ^Block_Table, b: Block) -> bool {
	return t.flags[b] & {.Breakable, .Replaceable} != {}
}

// can_place_at: block may go at pos, where current is: current gives way to
// it (or is a single slab the block completes), and the player is not
// standing there: none of the block's collision boxes overlaps theirs (a
// flower has none).
can_place_at :: proc(
	t: ^Block_Table,
	current, block: Block,
	pos: Block_Pos,
	player: Player_State,
) -> bool {
	if current == block {return false}
	if !block_has(t, current, .Replaceable) && !slab_completes(t, current, block) {return false}
	lo, hi := player_box(player)
	EPS :: 1e-6
	for box in shape_boxes(t, t.collision[block]) {
		blo, bhi := box_world(box, pos)
		if lo.x < bhi.x - EPS &&
		   hi.x > blo.x + EPS &&
		   lo.y < bhi.y - EPS &&
		   hi.y > blo.y + EPS &&
		   lo.z < bhi.z - EPS &&
		   hi.z > blo.z + EPS {
			return false
		}
	}
	return true
}

// slab_completes: placing block into the single slab current makes a double.
slab_completes :: proc(t: ^Block_Table, current, block: Block) -> bool {
	if t.type_of[current] != t.type_of[block] ||
	   t.types[t.type_of[block]].place != .Slab {return false}
	return state_is(t, block, "type", "double") && !state_is(t, current, "type", "double")
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
