package game

import "core:math"

// Placement rules: where a placed type goes and in which state, from what
// the player aimed at. Shared: the client predicts what the server decides,
// and the server accepts an edit only if it gives the same cell and state.

// Place_Context: what a placement follows.
Place_Context :: struct {
	target: Block_Pos, // the cell aimed at (Ray_Hit.block)
	face:   Face, // the face aimed at (from Ray_Hit.normal)
	hit:    [3]u8, // where on it, in sixteenths of target (0..16)
	yaw:    f32, // the player's, at the input the edit follows
}

// EDIT_FACE_BREAK, EDIT_FACE_PLAIN: an Edit's face (0..5 is a Face) when it
// breaks, and when it carries no placement context (a hoe's tilling, a test's
// block put at a cell: only a type with the default rule, in its default state).
EDIT_FACE_BREAK :: 6
EDIT_FACE_PLAIN :: 7

face_of_normal :: proc(n: [3]i32) -> (face: Face, ok: bool) {
	for axes, f in FACE_AXES {
		if axes.normal == n {return f, true}
	}
	return {}, false
}

// hit_sixteenths: where the ray met the target cell, quantized: both sides
// run the rule on these numbers.
hit_sixteenths :: proc(point: [3]f64, target: Block_Pos) -> (hit: [3]u8) {
	for k in 0 ..< 3 {
		hit[k] = u8(clamp(i32(math.floor((point[k] - f64(target[k])) * 16)), 0, 16))
	}
	return
}

// facing_of_yaw: the way a player turned to yaw looks, as an index into
// ROTATE_VALUES (north, east, south, west). Yaw 0 looks north (-z) and grows
// towards west. A yaw exactly between two goes to the next one up.
facing_of_yaw :: proc(yaw: f32) -> int {
	TAU :: 2 * math.PI
	y := f64(yaw)
	m := y - TAU * math.floor(y / TAU)
	k := int(math.floor(m / (math.PI / 2) + 0.5)) & 3 // 0..3: north, west, south, east
	map_ := [4]int{0, 3, 2, 1}
	return map_[k]
}

// facing_vector: the direction of the state's `facing` property (north is -z,
// east +x), and whether it has one.
facing_vector :: proc(t: ^Block_Table, b: Block) -> (dir: [3]i32, ok: bool) {
	i, found := prop_index(t, t.type_of[b], "facing")
	if !found {return {}, false}
	switch t.types[t.type_of[b]].props[i].values[state_value(t, b, i)] {
	case "north":
		return {0, 0, -1}, true
	case "east":
		return {1, 0, 0}, true
	case "south":
		return {0, 0, 1}, true
	case "west":
		return {-1, 0, 0}, true
	}
	return {}, false
}

// state_set: b with the property called name set to value (false if the
// type has no such property or value).
state_set :: proc(t: ^Block_Table, b: Block, name, value: string) -> (Block, bool) {
	i, found := prop_index(t, t.type_of[b], name)
	if !found {return b, false}
	v, has := prop_value_index(t.types[t.type_of[b]].props[i], value)
	if !has {return b, false}
	return state_with(t, b, i, v), true
}

// state_is: b's property called name has value.
state_is :: proc(t: ^Block_Table, b: Block, name, value: string) -> bool {
	i, found := prop_index(t, t.type_of[b], name)
	if !found {return false}
	return t.types[t.type_of[b]].props[i].values[state_value(t, b, i)] == value
}

// half_of: the half of the cell a stair or slab goes in: aimed at a bottom
// face, the top; at a top face, the bottom; at a side, by the height aimed at.
@(private = "file")
half_of :: proc(ctx: Place_Context) -> string {
	switch ctx.face {
	case .Neg_Y:
		return "top"
	case .Pos_Y:
		return "bottom"
	case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
		return "top" if ctx.hit.y >= 8 else "bottom"
	}
	return "bottom"
}

// placement: where placing type goes and in which state, for ctx (ok false:
// it cannot be placed so).
placement :: proc(
	reg: ^Registry,
	type: Block_Type,
	ctx: Place_Context,
	q: Block_Query,
) -> (
	pos: Block_Pos,
	b: Block,
	ok: bool,
) {
	t := &reg.blocks
	def := &t.types[type]
	normal := FACE_AXES[ctx.face].normal
	pos = ctx.target + normal
	b = def.default
	switch def.place {
	case .Default:
		return pos, b, true
	case .Stairs:
		b = state_set(t, b, "facing", ROTATE_VALUES[facing_of_yaw(ctx.yaw)]) or_return
		b = state_set(t, b, "half", half_of(ctx)) or_return
		return pos, b, true
	case .Slab:
		// Aimed at a slab of the type on its inner face: it becomes a double there.
		target, loaded := q.get(q.data, ctx.target)
		if loaded && t.type_of[target] == type {
			inner :=
				(ctx.face == .Pos_Y && state_is(t, target, "type", "bottom")) ||
				(ctx.face == .Neg_Y && state_is(t, target, "type", "top"))
			if inner {
				b = state_set(t, b, "type", "double") or_return
				return ctx.target, b, true
			}
		}
		half := half_of(ctx)
		b = state_set(t, b, "type", half) or_return
		// Into a single slab of the type with the other half: a double.
		there, there_loaded := q.get(q.data, pos)
		if there_loaded && t.type_of[there] == type {
			other := "top" if half == "bottom" else "bottom"
			if state_is(t, there, "type", other) {
				b = state_set(t, b, "type", "double") or_return
			}
		}
		return pos, b, true
	case .Attached:
		if normal.y != 0 {return}
		for name in ROTATE_VALUES {
			dir: [3]i32
			switch name {
			case "north":
				dir = {0, 0, -1}
			case "east":
				dir = {1, 0, 0}
			case "south":
				dir = {0, 0, 1}
			case "west":
				dir = {-1, 0, 0}
			}
			if dir == normal {
				b = state_set(t, b, "facing", name) or_return
			}
		}
		if !support_holds(t, b, pos, q) {return pos, b, false}
		return pos, b, true
	}
	return
}

// support_holds: the block b at pos has what it needs around it: a plant, what
// it stands on; a block with a back (a ladder), what it is against. Unloaded
// cells hold.
support_holds :: proc(t: ^Block_Table, b: Block, pos: Block_Pos, q: Block_Query) -> bool {
	def := &t.defs[b]
	if def.support != NO_TAG {
		below, loaded := q.get(q.data, pos + {0, -1, 0})
		if loaded && !block_in_tag(t, below, def.support) {return false}
	}
	if def.back_full || def.back != NO_TAG {
		dir, has := facing_vector(t, b)
		if !has {return true}
		behind, loaded := q.get(q.data, pos - dir)
		if !loaded {return true}
		if def.back != NO_TAG && !block_in_tag(t, behind, def.back) {return false}
		if def.back_full {
			toward, _ := face_of_normal(dir)
			if !cover_full(shape_cover(t, t.render[behind]), toward) {return false}
		}
	}
	return true
}

// has_support_rule: b needs something around it (support_holds can fail).
has_support_rule :: proc(t: ^Block_Table, b: Block) -> bool {
	def := &t.defs[b]
	return def.support != NO_TAG || def.back != NO_TAG || def.back_full
}
