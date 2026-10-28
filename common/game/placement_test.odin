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

@(private = "file")
block_named :: proc(reg: ^Registry, name: string) -> Block {
	b, ok := registry_block(reg, name)
	if !ok {panic(name)}
	return b
}

@(private = "file")
sides_of :: proc(reg: ^Registry, b: Block) -> (sides: [4]bool) {
	for name, i in ROTATE_VALUES {sides[i] = state_is(&reg.blocks, b, name, "true")}
	return
}

@(test)
test_fence_states :: proc(t: ^testing.T) {
	reg := registry_base()
	defer registry_destroy(reg)
	w: Map_World
	defer delete(w)
	q := map_query(&w, reg)
	fence := block_named(reg, "planks_fence")
	type := type_named(reg, "planks_fence")
	at := Block_Pos{0, 1, 0}
	// Alone: no side.
	testing.expect_value(t, sides_of(reg, shape_update(reg, fence, at, q)), [4]bool{})
	// Beside another fence (east), stone (south), a stair's full back (west) and
	// its partial side, a slab's partial side, water: north, east, south, west.
	w[at + {1, 0, 0}] = fence
	w[at + {0, 0, 1}] = .Stone
	w[at + {-1, 0, 0}] = block_named(reg, "stone_stairs[facing=east,half=bottom]")
	w[at + {0, 0, -1}] = block_named(reg, "stone_slab[type=bottom]")
	got := sides_of(reg, shape_update(reg, fence, at, q))
	// A stair facing east has its high side east: the face toward the fence is full.
	testing.expect_value(t, got, [4]bool{false, true, true, true})
	// Facing west, the face toward the fence is the low step: partial, no join.
	w[at + {-1, 0, 0}] = block_named(reg, "stone_stairs[facing=west,half=bottom]")
	got = sides_of(reg, shape_update(reg, fence, at, q))
	testing.expect_value(t, got, [4]bool{false, true, true, false})
	// Water is not a wall.
	w[at + {0, 0, -1}] = block_named(reg, "water")
	got = sides_of(reg, shape_update(reg, fence, at, q))
	testing.expect_value(t, got[0], false)
	// Placing next to a fence gives the placed one the side.
	w[at + {1, 0, 0}] = fence
	_, placed, ok := placement(
		reg,
		type,
		{target = {-3, 0, 0}, face = .Pos_Y, hit = {8, 16, 8}},
		q,
	)
	testing.expect(t, ok)
	testing.expect_value(t, sides_of(reg, placed), [4]bool{})
	// Changing a cell updates the neighbours that follow it.
	w[at] = fence
	w[at + {1, 0, 0}] = fence
	changes: [4]Block_Change
	n := neighbour_updates(reg, at + {1, 0, 0}, q, &changes)
	testing.expect_value(t, n >= 1, true)
	found := false
	for c in changes[:n] {
		if c.pos == at {
			found = true
			testing.expect_value(t, sides_of(reg, c.b)[1], true) // east
		}
	}
	testing.expect(t, found, "the fence beside did not join")
}

@(test)
test_door_placement_and_companions :: proc(t: ^testing.T) {
	reg := registry_base()
	defer registry_destroy(reg)
	w: Map_World
	defer delete(w)
	q := map_query(&w, reg)
	door := type_named(reg, "planks_door")
	w[{0, 0, 0}] = .Stone
	ctx := Place_Context {
		target = {0, 0, 0},
		face   = .Pos_Y,
		hit    = {8, 16, 8},
		yaw    = 0,
	}
	pos, b, ok := placement(reg, door, ctx, q)
	testing.expect(t, ok)
	testing.expect_value(t, pos, Block_Pos{0, 1, 0})
	testing.expect_value(
		t,
		text(reg, b),
		"voxiverse:planks_door[facing=north,half=lower,open=false]",
	)
	at, other, has := companion(reg, b, pos)
	testing.expect(t, has)
	testing.expect_value(t, at, Block_Pos{0, 2, 0})
	testing.expect_value(
		t,
		text(reg, other),
		"voxiverse:planks_door[facing=north,half=upper,open=false]",
	)
	back, lower, has_back := companion(reg, other, at)
	testing.expect(t, has_back)
	testing.expect_value(t, back, pos)
	testing.expect_value(t, lower, b)
	_, _, plain := companion(reg, .Stone, {})
	testing.expect(t, !plain)
	// No room above: refused.
	w[{0, 2, 0}] = .Stone
	_, _, ok = placement(reg, door, ctx, q)
	testing.expect(t, !ok, "a door without room above")
	delete_key(&w, Block_Pos{0, 2, 0})
	// No floor: refused (a slab's top half is not a full face, nor air).
	_, _, ok = placement(reg, door, {target = {0, 0, 0}, face = .Pos_X, hit = {16, 8, 8}}, q)
	testing.expect(t, !ok, "a door over air")
	w[{1, -1, 0}] = block_named(reg, "stone_slab[type=bottom]")
	_, _, ok = placement(reg, door, {target = {0, 0, 0}, face = .Pos_X, hit = {16, 8, 8}}, q)
	testing.expect(t, !ok, "a door on a bottom slab")
	w[{1, -1, 0}] = block_named(reg, "stone_slab[type=top]")
	_, _, ok = placement(reg, door, {target = {0, 0, 0}, face = .Pos_X, hit = {16, 8, 8}}, q)
	testing.expect(t, ok, "a door on a top slab")
	// The upper half holds only on a lower half; the lower on a full top face.
	w[pos] = b
	testing.expect(t, support_holds(&reg.blocks, other, at, q))
	delete_key(&w, pos)
	testing.expect(t, !support_holds(&reg.blocks, other, at, q))
	delete_key(&w, Block_Pos{0, 0, 0})
	testing.expect(t, !support_holds(&reg.blocks, b, pos, q))
}

@(test)
test_edit_kind :: proc(t: ^testing.T) {
	reg := registry_base()
	defer registry_destroy(reg)
	tb := &reg.blocks
	closed := block_named(reg, "planks_door[facing=east,half=upper,open=false]")
	opened := block_named(reg, "planks_door[facing=east,half=upper,open=true]")
	turned := block_named(reg, "planks_door[facing=west,half=upper,open=false]")
	testing.expect_value(t, edit_kind(tb, .Stone, .Air), Edit_Kind.Break)
	testing.expect_value(t, edit_kind(tb, .Air, .Stone), Edit_Kind.Place)
	testing.expect_value(t, edit_kind(tb, closed, opened), Edit_Kind.Toggle)
	testing.expect_value(t, edit_kind(tb, opened, closed), Edit_Kind.Toggle)
	testing.expect_value(t, edit_kind(tb, closed, closed), Edit_Kind.Place)
	testing.expect_value(t, edit_kind(tb, closed, turned), Edit_Kind.Place)
	testing.expect_value(t, edit_kind(tb, .Stone, opened), Edit_Kind.Place)
}
