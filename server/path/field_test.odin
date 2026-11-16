package path

import "core:testing"

import "common:game"

// walk: a walker's way from `from` by field_next until the goal or no way (at most
// `most` moves): the blocks it stands in, in order.
@(private = "file")
walk :: proc(
	f: ^Field,
	q: game.Block_Query,
	from: game.Block_Pos,
	most := 400,
) -> []game.Block_Pos {
	way := make([dynamic]game.Block_Pos, context.temp_allocator)
	at := from
	for _ in 0 ..< most {
		next, ok := field_next(f, at)
		if !ok {break}
		append(&way, next)
		at = next
	}
	return way[:]
}

// A field over open ground: every block has a way, the cost is the distance, and
// following it from anywhere ends at the goal.
@(test)
test_field_open_ground :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	f: Field
	if !testing.expect(t, field_make(&f, {-10, 1, -10}, {10, 3, 10})) {return}
	defer field_destroy(&f)
	reached := field_build(&f, q, {8, 1, 0})
	testing.expect_value(t, reached, 21 * 21) // (the ground floor: y 2 and 3 are midair)
	c, ok := field_cost(&f, {0, 1, 0})
	testing.expect(t, ok && abs(c - 8) < 0.001)
	_, ok = field_cost(&f, {0, 2, 0})
	testing.expect(t, !ok, "a way from midair")
	way := walk(&f, q, {-10, 1, -10})
	testing.expect(t, len(way) > 0 && way[len(way) - 1] == {8, 1, 0}, "did not arrive")
	testing.expect_value(t, len(way), 18) // (10 diagonal, then 8 straight)
}

// A wall across the way: around its end, and the cost is the longer way; a wall with
// no end shuts the way, and with_block asks about the last gap before it is filled.
@(test)
test_field_walls_and_the_last_gap :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	f: Field
	if !testing.expect(t, field_make(&f, {-12, 1, -12}, {12, 4, 12})) {return}
	defer field_destroy(&f)
	wall(&b, 0, -12, 9, 1, 2) // x 0, from the edge to z 9: a gap at z 10..12
	field_build(&f, q, {6, 1, 0})
	c, ok := field_cost(&f, {-6, 1, 0})
	testing.expect(t, ok && c > 20, "went through the wall")
	for p in walk(&f, q, {-6, 1, 0}) {
		testing.expect(t, p.x != 0 || p.z >= 10, "a way through the wall")
	}

	// Filling the gap but one: the way squeezes through it.
	wall(&b, 0, 10, 11, 1, 2)
	field_build(&f, q, {6, 1, 0})
	_, ok = field_cost(&f, {-6, 1, 0})
	testing.expect(t, ok, "one gap left, and no way")

	// Would a block in the last gap shut the way? Not for a climber, which steps up on
	// it; for a walker that does not climb, it would. Asked first, then done.
	ask := With_Block{q, {0, 1, 12}, .Stone}
	field_build(&f, with_block(&ask), {6, 1, 0})
	_, ok = field_cost(&f, {-6, 1, 0})
	testing.expect(t, ok, "a climber does not step up on the block")
	field_build(&f, with_block(&ask), {6, 1, 0}, {1, 1, 0})
	_, ok = field_cost(&f, {-6, 1, 0})
	testing.expect(t, !ok, "a block in the last gap left a way")
	field_build(&f, q, {6, 1, 0}, {1, 1, 0})
	_, ok = field_cost(&f, {-6, 1, 0})
	testing.expect(t, ok, "asking changed the blocks")
}

// A body two blocks tall does not pass under a beam a short one walks under; one two
// wide does not pass a gap one wide.
@(test)
test_field_bodies :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	f: Field
	if !testing.expect(t, field_make(&f, {-8, 1, -8}, {8, 4, 8})) {return}
	defer field_destroy(&f)
	// A wall at x 0 with a gap at z 0, one wide, roofed at y 2 (one high).
	wall(&b, 0, -8, -1, 1, 3)
	wall(&b, 0, 1, 8, 1, 3)
	b.solid[{0, 2, 0}], b.solid[{0, 3, 0}] = true, true
	field_build(&f, q, {5, 1, 0}, SMALL)
	_, ok := field_cost(&f, {-5, 1, 0})
	testing.expect(t, ok, "a small body does not pass the gap")
	field_build(&f, q, {5, 1, 0}, {1, 2, 1})
	_, ok = field_cost(&f, {-5, 1, 0})
	testing.expect(t, !ok, "a tall body passed under the beam")
	delete_key(&b.solid, game.Block_Pos{0, 2, 0})
	delete_key(&b.solid, game.Block_Pos{0, 3, 0})
	field_build(&f, q, {5, 1, 0}, {1, 2, 1})
	_, ok = field_cost(&f, {-5, 1, 0})
	testing.expect(t, ok, "a tall body does not pass the open gap")
	field_build(&f, q, {5, 1, 0}, {2, 1, 1})
	_, ok = field_cost(&f, {-5, 1, 0})
	testing.expect(t, !ok, "a wide body passed a gap one wide")
}

// An area too large is refused; a goal outside it, or where nothing stands, reaches
// nothing.
@(test)
test_field_limits :: proc(t: ^testing.T) {
	f: Field
	testing.expect(t, !field_make(&f, {0, 0, 0}, {1024, 16, 1024}))
	testing.expect(t, !field_make(&f, {0, 0, 0}, {-1, 0, 0}))
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	if !testing.expect(t, field_make(&f, {-4, 1, -4}, {4, 2, 4})) {return}
	defer field_destroy(&f)
	testing.expect_value(t, field_build(&f, q, {20, 1, 0}), 0)
	testing.expect_value(t, field_build(&f, q, {0, 2, 0}), 0)
}

// A path crosses a changed block when it goes through it or beside it.
@(test)
test_path_crosses :: proc(t: ^testing.T) {
	p := Path {
		count = 3,
	}
	p.steps[0], p.steps[1], p.steps[2] = {1, 1, 0}, {2, 1, 0}, {3, 1, 0}
	testing.expect(t, crosses(&p, {2, 1, 1}, {2, 1, 1}))
	testing.expect(t, crosses(&p, {4, 1, 0}, {4, 2, 0}))
	testing.expect(t, !crosses(&p, {2, 1, 4}, {2, 1, 4}))
	testing.expect(t, !crosses(&p, {9, 1, 0}, {12, 3, 0}))
}
