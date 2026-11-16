package grid

import "core:testing"

import "common:game"

// A grid's parts as blocks come and go: cables join what touches them, poles what they
// reach, machines join a conductor but never each other, and a part splits only where a
// removed block held it together.

@(private = "file")
CABLE :: Kind {
	type = 1,
}
@(private = "file")
POLE :: Kind {
	type  = 2,
	reach = 4,
}
@(private = "file")
MACHINE :: Kind {
	type = 3,
	node = true,
}

@(private = "file")
parts_count :: proc(g: ^Grid) -> int {return len(g.parts)}

@(private = "file")
same_part :: proc(g: ^Grid, a, b: game.Block_Pos) -> bool {
	pa, oka := grid_part_of(g, a)
	pb, okb := grid_part_of(g, b)
	return oka && okb && pa == pb
}

@(test)
test_a_grid_joins_and_splits_its_parts :: proc(t: ^testing.T) {
	g := grid_make({CABLE, POLE, MACHINE})
	defer grid_destroy(&g)
	// Two machines side by side do not join each other.
	grid_add(&g, {0, 0, 0}, MACHINE)
	grid_add(&g, {1, 0, 0}, MACHINE)
	testing.expect_value(t, parts_count(&g), 2)
	// A cable along them joins both.
	for x in i32(0) ..< 6 {grid_add(&g, {x, 1, 0}, CABLE)}
	testing.expect_value(t, parts_count(&g), 1)
	testing.expect(t, same_part(&g, {0, 0, 0}, {1, 0, 0}))
	id, _ := grid_part_of(&g, {0, 0, 0})
	// A pole four blocks past the cable's end reaches it; another machine by the pole.
	grid_add(&g, {9, 1, 0}, POLE)
	grid_add(&g, {12, 1, 0}, MACHINE)
	testing.expect_value(t, parts_count(&g), 1)
	testing.expect(t, same_part(&g, {12, 1, 0}, {0, 0, 0}))
	got, _ := grid_part_of(&g, {12, 1, 0})
	testing.expect_value(t, got, id) // (a part that grows keeps its number)
	// Breaking the cable in its middle splits it: the larger piece keeps the number.
	grid_remove(&g, {2, 1, 0})
	testing.expect_value(t, parts_count(&g), 2)
	testing.expect(t, !same_part(&g, {0, 0, 0}, {12, 1, 0}))
	testing.expect(t, same_part(&g, {3, 1, 0}, {12, 1, 0}))
	big, _ := grid_part_of(&g, {12, 1, 0})
	testing.expect_value(t, big, id)
	// Mended: one again.
	grid_add(&g, {2, 1, 0}, CABLE)
	testing.expect_value(t, parts_count(&g), 1)
	// The pole gone: its machine stands alone.
	grid_remove(&g, {9, 1, 0})
	testing.expect_value(t, parts_count(&g), 2)
	testing.expect(t, !same_part(&g, {12, 1, 0}, {0, 0, 0}))
	total := 0
	for part in grid_parts(&g) {total += len(part.members)}
	testing.expect_value(t, total, len(g.members))
}
