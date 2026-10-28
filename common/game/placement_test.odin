package game

import "core:math"
import "core:testing"

@(private = "file")
Map_World :: map[Block_Pos]Block

@(private = "file")
map_query :: proc(w: ^Map_World, reg: ^Registry) -> Block_Query {
	return {w, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			w := (^Map_World)(data)
			return w[p] or_else .Air, true
		}, &reg.blocks}
}

@(private = "file")
type_named :: proc(reg: ^Registry, name: string) -> Block_Type {
	b, ok := registry_block(reg, name)
	if !ok {panic(name)}
	return reg.blocks.type_of[b]
}

@(private = "file")
text :: proc(reg: ^Registry, b: Block) -> string {
	return state_text(reg, b)
}

@(test)
test_placement_rules :: proc(t: ^testing.T) {
	reg := registry_base()
	defer registry_destroy(reg)
	w: Map_World
	defer delete(w)
	q := map_query(&w, reg)
	stairs := type_named(reg, "stone_stairs")
	slab := type_named(reg, "stone_slab")
	other_slab := type_named(reg, "planks_slab")
	ladder := type_named(reg, "ladder")
	w[{0, 0, 0}] = .Stone

	// Stairs: facing from the yaw, at and around each boundary (45 degrees goes to the next).
	EPS :: 1e-3
	Q :: math.PI / 2
	cases := []struct {
		yaw:    f64,
		facing: string,
	} {
		{0, "north"},
		{Q / 2 - EPS, "north"},
		{Q / 2 + EPS, "west"},
		{Q, "west"},
		{Q + Q / 2 - EPS, "west"},
		{Q + Q / 2 + EPS, "south"},
		{2 * Q, "south"},
		{2 * Q + Q / 2 + EPS, "east"},
		{3 * Q, "east"},
		{3 * Q + Q / 2 - EPS, "east"},
		{3 * Q + Q / 2 + EPS, "north"},
		{2 * math.PI, "north"},
		{-Q, "east"},
		{-Q / 2 + EPS, "north"},
		{-Q / 2 - EPS, "east"},
		{5 * math.PI, "south"},
	}
	for c in cases {
		_, b, ok := placement(
			reg,
			stairs,
			{target = {0, 0, 0}, face = .Pos_Y, hit = {8, 16, 8}, yaw = f32(c.yaw)},
			q,
		)
		testing.expect(t, ok)
		testing.expectf(
			t,
			state_is(&reg.blocks, b, "facing", c.facing),
			"yaw %v: %s, want %s",
			c.yaw,
			text(reg, b),
			c.facing,
		)
	}
	// Exactly 45 degrees (the f32 nearest) goes to the next direction up.
	_, eb, _ := placement(reg, stairs, {target = {0, 0, 0}, face = .Pos_Y, yaw = f32(Q / 2)}, q)
	testing.expect(t, state_is(&reg.blocks, eb, "facing", "west"))

	// Half: from the face aimed at, and the height on a side.
	halves := []struct {
		face: Face,
		y:    u8,
		half: string,
	} {
		{.Pos_Y, 0, "bottom"},
		{.Neg_Y, 16, "top"},
		{.Pos_X, 7, "bottom"},
		{.Pos_X, 8, "top"},
		{.Neg_Z, 0, "bottom"},
		{.Pos_Z, 16, "top"},
	}
	for c in halves {
		pos, hb, hok := placement(
			reg,
			stairs,
			{target = {0, 0, 0}, face = c.face, hit = {8, c.y, 8}},
			q,
		)
		testing.expect(t, hok)
		testing.expectf(
			t,
			state_is(&reg.blocks, hb, "half", c.half),
			"%v at %d: %s",
			c.face,
			c.y,
			text(reg, hb),
		)
		testing.expect_value(t, pos, Block_Pos{0, 0, 0} + FACE_AXES[c.face].normal)
	}

	// Slabs: the half the same way; aimed at a slab's inner face, a double there.
	pos, sb, ok := placement(reg, slab, {target = {0, 0, 0}, face = .Pos_Y, hit = {8, 16, 8}}, q)
	testing.expect(t, ok && pos == {0, 1, 0} && state_is(&reg.blocks, sb, "type", "bottom"))
	w[{0, 1, 0}] = sb
	pos, sb, ok = placement(reg, slab, {target = {0, 1, 0}, face = .Pos_Y, hit = {8, 8, 8}}, q)
	testing.expect(
		t,
		ok && pos == {0, 1, 0} && state_is(&reg.blocks, sb, "type", "double"),
		"onto the bottom slab's top",
	)
	// Aimed at the stone's side with the cell holding a slab of the other half: a double there.
	w[{1, 0, 0}] = registry_block_must(reg, "stone_slab[type=top]")
	pos, sb, ok = placement(reg, slab, {target = {0, 0, 0}, face = .Pos_X, hit = {16, 3, 8}}, q)
	testing.expect(
		t,
		ok && pos == {1, 0, 0} && state_is(&reg.blocks, sb, "type", "double"),
		"the other half beside",
	)
	// The same half beside it: a single, and the cell is taken.
	pos, sb, ok = placement(reg, slab, {target = {0, 0, 0}, face = .Pos_X, hit = {16, 9, 8}}, q)
	testing.expect(t, ok && pos == {1, 0, 0} && state_is(&reg.blocks, sb, "type", "top"))
	cur := w[{1, 0, 0}]
	testing.expect(
		t,
		!can_place_at(&reg.blocks, cur, sb, pos, {position = {50, 50, 50}}),
		"no slab onto the same half",
	)
	// A slab of another type does not merge.
	_, ob, _ := placement(
		reg,
		other_slab,
		{target = {0, 0, 0}, face = .Pos_X, hit = {16, 3, 8}},
		q,
	)
	testing.expect(
		t,
		!can_place_at(&reg.blocks, cur, ob, {1, 0, 0}, {position = {50, 50, 50}}),
		"planks slab into a stone slab",
	)
	// The merge itself is allowed (and replaces it).
	_, db, _ := placement(reg, slab, {target = {0, 0, 0}, face = .Pos_X, hit = {16, 3, 8}}, q)
	testing.expect(
		t,
		can_place_at(&reg.blocks, cur, db, {1, 0, 0}, {position = {50, 50, 50}}),
		"the double completes",
	)

	// Ladders: sides only, against a full face.
	b: Block
	pos, b, ok = placement(reg, ladder, {target = {0, 0, 0}, face = .Pos_X}, q)
	testing.expect(
		t,
		ok && pos == {1, 0, 0} && state_is(&reg.blocks, b, "facing", "east"),
		text(reg, b),
	)
	_, _, ok = placement(reg, ladder, {target = {0, 0, 0}, face = .Pos_Y}, q)
	testing.expect(t, !ok, "a ladder on a top face")
	_, _, ok = placement(reg, ladder, {target = {0, 0, 0}, face = .Neg_Y}, q)
	testing.expect(t, !ok, "a ladder on a bottom face")
	w[{5, 0, 0}] = registry_block_must(reg, "stone_slab[type=bottom]")
	_, _, ok = placement(reg, ladder, {target = {5, 0, 0}, face = .Pos_X}, q)
	testing.expect(t, !ok, "a ladder on half a face")
	w[{5, 0, 0}] = registry_block_must(reg, "stone_slab[type=double]")
	_, _, ok = placement(reg, ladder, {target = {5, 0, 0}, face = .Pos_X}, q)
	testing.expect(t, ok, "a ladder on a double slab")
	// Default rule: the cell beside, in the default state.
	dirt := type_named(reg, "dirt")
	pos, b, ok = placement(reg, dirt, {target = {0, 0, 0}, face = .Neg_Z}, q)
	testing.expect(t, ok && pos == {0, 0, -1} && b == registry_block_must(reg, "dirt"))

	// can_place_at against a player: a slab above a crouching one.
	crouched := Player_State {
		position = {0.5, 0, 0.5},
		crouched = true,
	}
	standing := Player_State {
		position = {0.5, 0, 0.5},
	}
	bottom := registry_block_must(reg, "stone_slab[type=bottom]")
	top := registry_block_must(reg, "stone_slab[type=top]")
	testing.expect(
		t,
		!can_place_at(&reg.blocks, .Air, bottom, {0, 1, 0}, crouched),
		"a bottom slab at the crouching head",
	)
	testing.expect(
		t,
		can_place_at(&reg.blocks, .Air, top, {0, 1, 0}, crouched),
		"a top slab above the crouching head",
	)
	testing.expect(
		t,
		!can_place_at(&reg.blocks, .Air, top, {0, 1, 0}, standing),
		"a top slab in the standing head",
	)
	testing.expect(t, can_place_at(&reg.blocks, .Air, top, {0, 2, 0}, standing))
}

@(private = "file")
registry_block_must :: proc(reg: ^Registry, text: string) -> Block {
	b, ok := state_parse(reg, text)
	if !ok {panic(text)}
	return b
}
