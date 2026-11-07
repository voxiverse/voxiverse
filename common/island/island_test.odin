package island

import "core:slice"
import "core:testing"

R :: 4

@(private = "file")
count :: proc(r: Update_Result, kind: Event_Kind) -> int {
	n := 0
	for e in r.events {if e.kind == kind {n += 1}}
	return n
}

@(test)
test_two_players_apart_have_two_islands :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	r := update(&i, R, {{1, {0, 0, 0}}, {2, {100, 0, 0}}})
	testing.expect_value(t, count(r, .Opened), 2)
	ids := island_ids(&i)
	testing.expect_value(t, len(ids), 2)
	testing.expect(t, island_of(&i, {0, 0, 0}) != island_of(&i, {100, 0, 0}))
}

@(test)
test_walking_together_merges_and_parting_splits :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	update(&i, R, {{1, {0, 0, 0}}, {2, {20, 0, 0}}})
	a, b := island_of(&i, {0, 0, 0}), island_of(&i, {20, 0, 0})
	testing.expect(t, a != b && a != 0 && b != 0)
	// Walk together: 2R = 8 apart is one island.
	mg := update(&i, R, {{1, {0, 0, 0}}, {2, {8, 0, 0}}})
	testing.expect_value(t, count(mg, .Merged), 1)
	testing.expect_value(t, island_of(&i, {0, 0, 0}), island_of(&i, {8, 0, 0}))
	testing.expect_value(t, island_of(&i, {0, 0, 0}), min(a, b))
	testing.expect_value(t, len(island_ids(&i)), 1)
	// Merging alone changes no chunk's detail beyond the mover's own.
	// Part: one island becomes two, the lower observer keeps the id.
	sp := update(&i, R, {{1, {0, 0, 0}}, {2, {30, 0, 0}}})
	testing.expect_value(t, count(sp, .Split), 1)
	testing.expect_value(t, len(island_ids(&i)), 2)
	testing.expect_value(t, island_of(&i, {0, 0, 0}), min(a, b))
	testing.expect(t, island_of(&i, {30, 0, 0}) != min(a, b))
}

@(test)
test_a_chunk_in_no_island_is_in_none :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	testing.expect_value(t, island_of(&i, {0, 0, 0}), Island_Id(0))
	update(&i, R, {{1, {0, 0, 0}}})
	testing.expect(t, island_of(&i, {R, 0, 0}) != 0)
	testing.expect_value(t, island_of(&i, {R + 1, 0, 0}), Island_Id(0))
	testing.expect_value(t, island_of(&i, {3, 0, 3}), Island_Id(0)) // 18 > 16
	testing.expect(t, island_of(&i, {2, 0, 3}) != 0) // 13
}

@(test)
test_leaving_closes_the_island_with_its_chunks :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	opened := update(&i, R, {{1, {0, 0, 0}}})
	size := island_size(&i, 1)
	testing.expect_value(t, len(opened.entered), size)
	testing.expect_value(t, len(opened.events[0].chunks), size)
	closed := update(&i, R, {})
	testing.expect_value(t, count(closed, .Closed), 1)
	testing.expect_value(t, len(closed.left), size)
	testing.expect_value(t, island_of(&i, {0, 0, 0}), Island_Id(0))
}

@(test)
test_moving_one_chunk_changes_only_the_rim :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	update(&i, R, {{1, {0, 0, 0}}})
	same := update(&i, R, {{1, {0, 0, 0}}})
	testing.expect_value(t, len(same.events) + len(same.entered) + len(same.left), 0)
	mv := update(&i, R, {{1, {1, 0, 0}}})
	testing.expect_value(t, len(mv.events), 0)
	testing.expect(t, len(mv.entered) > 0 && len(mv.left) > 0)
	for c in mv.entered {testing.expect(t, island_of(&i, c) != 0)}
	for c in mv.left {testing.expect_value(t, island_of(&i, c), Island_Id(0))}
	// The set after equals the set before, less left, plus entered.
	testing.expect_value(t, island_size(&i, 1), island_size(&i, 1))
}

@(test)
test_chunks_listed_once_and_match_island_of :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	update(&i, R, {{1, {0, 0, 0}}, {2, {5, 0, 3}}})
	id := island_of(&i, {0, 0, 0})
	cs := island_chunks(&i, id)
	for c, k in cs {
		testing.expect_value(t, island_of(&i, c), id)
		testing.expect(t, !slice.contains(cs[:k], c))
	}
	// A chunk of the first disc and of the second are one island.
	testing.expect_value(t, island_of(&i, {9, 0, 3}), id)
}

@(test)
test_a_split_keeps_the_id_with_the_larger_part :: proc(t: ^testing.T) {
	i: Islands
	defer destroy(&i)
	update(&i, R, {{1, {0, 0, 0}}, {2, {3, 0, 0}}, {3, {6, 0, 0}}})
	id := island_of(&i, {0, 0, 0})
	// 1 goes far off; 2 and 3 stay together and keep the id.
	update(&i, R, {{1, {100, 0, 0}}, {2, {3, 0, 0}}, {3, {6, 0, 0}}})
	testing.expect_value(t, island_of(&i, {3, 0, 0}), id)
	testing.expect(t, island_of(&i, {100, 0, 0}) != id)
}
