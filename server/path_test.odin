package server

import "core:testing"

import "common:game"

@(private = "file")
Blocks :: struct {
	solid:  map[game.Block_Pos]bool,
	floor:  i32, // solid at and below this y everywhere
	region: [2]i32, // loaded for |x|, |z| <= region (else: unloaded)
}

@(private = "file")
query :: proc(b: ^Blocks) -> game.Block_Query {
	return {b, proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
			b := (^Blocks)(data)
			if abs(p.x) > b.region.x || abs(p.z) > b.region.y {return .Air, false}
			if p.y <= b.floor || p in b.solid {return .Stone, true}
			return .Air, true
		}, test_blocks()}
}

@(private = "file")
wall :: proc(b: ^Blocks, x: i32, z_from, z_to: i32, y_from, y_to: i32) {
	for z in z_from ..= z_to {
		for y in y_from ..= y_to {b.solid[{x, y, z}] = true}
	}
}

@(private = "file")
ends_at :: proc(p: Path) -> game.Block_Pos {
	return p.steps[p.count - 1] if p.count > 0 else {}
}

@(test)
test_path_straight_and_around :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	p, ok := find_path(q, {0, 1, 0}, {8, 1, 0}, 500)
	testing.expect(t, ok && p.whole && p.count == 8 && ends_at(p) == {8, 1, 0})

	// A wall two blocks high from z -5 to 5 at x 4: around its end.
	wall(&b, 4, -5, 5, 1, 2)
	p, ok = find_path(q, {0, 1, 0}, {8, 1, 0}, 2000)
	testing.expect(t, ok && p.whole && ends_at(p) == {8, 1, 0})
	for s in p.steps[:p.count] {
		testing.expectf(t, standable(q, s), "path through %v, where nothing can stand", s)
		testing.expect(t, s.x != 4 || abs(s.z) > 5, "path through the wall")
	}
}

@(test)
test_path_steps_and_drops :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	// A one-block step: walked up.
	wall(&b, 3, -40, 40, 1, 1)
	for x in i32(4) ..= 40 {wall(&b, x, -40, 40, 1, 1)} 	// a raised plateau from x 3 on
	p, ok := find_path(q, {0, 1, 0}, {6, 2, 0}, 500)
	testing.expect(t, ok && p.whole, "a one-block step is walkable")

	// The other way: a drop of one, fine; a cliff of 5, not.
	clear(&b.solid)
	for x in i32(-40) ..= 2 {wall(&b, x, -40, 40, 1, 5)} 	// high ground (top y 5) up to x 2
	p, ok = find_path(q, {0, 6, 0}, {6, 1, 0}, 2000)
	testing.expect(t, ok && !p.whole, "jumped off a cliff higher than MAX_DROP")
	testing.expect(t, p.count == 0 || ends_at(p).y == 6, "went down a cliff")
}

// No cutting corners: a diagonal past a solid block is not taken.
@(test)
test_path_no_corner_cutting :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	q := query(&b)
	b.solid[{1, 1, 0}] = true
	b.solid[{1, 2, 0}] = true
	p, ok := find_path(q, {0, 1, 0}, {1, 1, 1}, 200)
	testing.expect(t, ok && p.whole)
	testing.expect(t, p.count == 2, "squeezed diagonally past a block's corner")
}

// Out of budget, or the goal beyond loaded ground: the best way so far,
// which gets closer.
@(test)
test_path_partial :: proc(t: ^testing.T) {
	b := Blocks {
		region = {10, 10},
	}
	defer delete(b.solid)
	q := query(&b)
	p, ok := find_path(q, {0, 1, 0}, {30, 1, 0}, 2000)
	testing.expect(t, ok && !p.whole && p.count > 0)
	testing.expectf(
		t,
		ends_at(p).x == 10,
		"stopped at %v, not at the edge of the loaded ground",
		ends_at(p),
	)
	p, ok = find_path(q, {0, 1, 0}, {9, 1, 9}, 5)
	testing.expect(t, ok && !p.whole && p.count > 0)
	e := ends_at(p)
	testing.expect(t, e.x + e.z > 0, "a partial path that does not get closer")
	_, ok = find_path(q, {0, 5, 0}, {3, 1, 0}, 100)
	testing.expect(t, !ok, "a path from midair")
}
