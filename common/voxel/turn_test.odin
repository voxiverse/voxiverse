package voxel

import "core:testing"

import "common:base"

// closure: every product of the generators, IDENTITY among them.
closure :: proc(generators: []Turn) -> [dynamic]Turn {
	group := make([dynamic]Turn, context.temp_allocator)
	append(&group, IDENTITY)
	for i := 0; i < len(group); i += 1 {
		for g in generators {
			p := g * group[i]
			found := false
			for q in group {if q == p {found = true; break}}
			if !found {append(&group, p)}
		}
	}
	return group
}

@(test)
test_turns_compose_as_the_cube_group :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	turns := closure({TURN_X, TURN_Y, TURN_Z})
	testing.expect_value(t, len(turns), 24)
	for m in turns {
		det :=
			m[0, 0] * (m[1, 1] * m[2, 2] - m[1, 2] * m[2, 1]) -
			m[0, 1] * (m[1, 0] * m[2, 2] - m[1, 2] * m[2, 0]) +
			m[0, 2] * (m[1, 0] * m[2, 1] - m[1, 1] * m[2, 0])
		testing.expect_value(t, det, 1)
		testing.expect(t, m * turn_inverse(m) == IDENTITY)
	}
	testing.expect_value(t, len(closure({TURN_X, TURN_Y, MIRROR_X})), 48)
	testing.expect(t, TURN_Y * TURN_Y * TURN_Y * TURN_Y == IDENTITY)
	testing.expect(t, MIRROR_Y * MIRROR_Y == IDENTITY)
	// A quarter turn about y takes +x to +z, as the engine turns templates.
	testing.expect_value(t, turn_cell(TURN_Y, {0, 0, 0}), Cell{-1, 0, 0})
	testing.expect_value(t, turn_cell(TURN_Y, {5, 2, 0}), Cell{-1, 2, 5})
	// Turning by a then b is turning by b * a, and a turn's transpose undoes it.
	rng := base.rng_make(0x7e2)
	for _ in 0 ..< 60 {
		a := turns[base.rng_int_max(&rng, len(turns))]
		b := turns[base.rng_int_max(&rng, len(turns))]
		if base.rng_int_max(&rng, 2) == 0 {b = MIRROR_Z * b}
		m := random_mask(&rng, random_bounds(&rng, 70), 30)
		defer mask_destroy(&m)
		once := mask_make(turn_bounds(a, m.bounds))
		defer mask_destroy(&once)
		turn(&once, m, a)
		testing.expect_value(t, mask_count(once), mask_count(m))
		twice := mask_make(turn_bounds(b, once.bounds))
		defer mask_destroy(&twice)
		turn(&twice, once, b)
		direct := mask_make(turn_bounds(b * a, m.bounds))
		defer mask_destroy(&direct)
		turn(&direct, m, b * a)
		testing.expect_value(t, direct.bounds, twice.bounds)
		testing.expect(t, same(direct, ref_of_tmp(twice)))
		back := mask_make(m.bounds)
		defer mask_destroy(&back)
		turn(&back, direct, turn_inverse(b * a))
		testing.expect(t, same(back, ref_of_tmp(m)))
		// With every cell past its bounds in the set, so is every cell past the turned ones.
		full := m
		full.outside = true
		around := turn_bounds(a, m.bounds)
		around = {around.lo - 2, around.hi + 2}
		wide := mask_make(around)
		defer mask_destroy(&wide)
		turn(&wide, full, a)
		testing.expect(t, wide.outside)
		for c in ref_cells(around) {
			if mask_get(wide, c) != mask_get(full, turn_cell(turn_inverse(a), c)) {
				testing.expectf(t, false, "turned outside differs at %v", c)
				break
			}
		}
	}
}
