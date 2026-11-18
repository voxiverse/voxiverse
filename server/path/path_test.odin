package path

import "base:runtime"
import "core:sync"
import "core:testing"

import "common:game"
import "common:voxel"

@(private)
Blocks :: struct {
	solid:  map[game.Block_Pos]bool,
	floor:  i32, // solid at and below this y everywhere
	region: [2]i32, // loaded for |x|, |z| <= region (else: unloaded)
}

@(private)
query :: proc(b: ^Blocks) -> game.Block_Query {
	return {b, proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
			b := (^Blocks)(data)
			if abs(p.x) > b.region.x || abs(p.z) > b.region.y {return .Air, false}
			if p.y <= b.floor || p in b.solid {return .Stone, true}
			return .Air, true
		}, &registry().blocks, {}}
}

@(private)
wall :: proc(b: ^Blocks, x: i32, z_from, z_to: i32, y_from, y_to: i32) {
	for z in z_from ..= z_to {
		for y in y_from ..= y_to {b.solid[{x, y, z}] = true}
	}
}

// solid_mask: the cells of b that are solid as q has them (game.solid_at), in the temp
// allocator: what a server's world_mask gives.
@(private)
solid_mask :: proc(q: game.Block_Query, b: voxel.Bounds) -> voxel.Mask {
	m := voxel.mask_make(b, context.temp_allocator)
	for y in b.lo.y ..< b.hi.y {
		for z in b.lo.z ..< b.hi.z {
			for x in b.lo.x ..< b.hi.x {if game.solid_at(q, {x, y, z}) {voxel.mask_set(&m, {x, y, z})}}
		}
	}
	return m
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
	p, ok := find(q, {0, 1, 0}, {8, 1, 0}, 500)
	testing.expect(t, ok && p.whole && p.count == 8 && ends_at(p) == {8, 1, 0})

	// A wall two blocks high from z -5 to 5 at x 4: around its end.
	wall(&b, 4, -5, 5, 1, 2)
	p, ok = find(q, {0, 1, 0}, {8, 1, 0}, 2000)
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
	p, ok := find(q, {0, 1, 0}, {6, 2, 0}, 500)
	testing.expect(t, ok && p.whole, "a one-block step is walkable")

	// The other way: a drop of one, fine; a cliff of 5, not.
	clear(&b.solid)
	for x in i32(-40) ..= 2 {wall(&b, x, -40, 40, 1, 5)} 	// high ground (top y 5) up to x 2
	p, ok = find(q, {0, 6, 0}, {6, 1, 0}, 2000)
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
	p, ok := find(q, {0, 1, 0}, {1, 1, 1}, 200)
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
	p, ok := find(q, {0, 1, 0}, {30, 1, 0}, 2000)
	testing.expect(t, ok && !p.whole && p.count > 0)
	testing.expectf(
		t,
		ends_at(p).x == 10,
		"stopped at %v, not at the edge of the loaded ground",
		ends_at(p),
	)
	p, ok = find(q, {0, 1, 0}, {9, 1, 9}, 5)
	testing.expect(t, ok && !p.whole && p.count > 0)
	e := ends_at(p)
	testing.expect(t, e.x + e.z > 0, "a partial path that does not get closer")
	_, ok = find(q, {0, 5, 0}, {3, 1, 0}, 100)
	testing.expect(t, !ok, "a path from midair")
}

// registry: the base registry, built once for the package's tests.
@(private = "file")
shared_registry: ^game.Registry
@(private = "file")
shared_once: sync.Once

registry :: proc() -> ^game.Registry {
	sync.once_do(&shared_once, proc() {
		context.allocator = runtime.default_allocator()
		shared_registry = game.registry_base(runtime.default_allocator())
	})
	return shared_registry
}

// One rule for where a body stands: standable_mask over a box of cells gives the cells
// standable says one at a time, for bodies one wide and one high up to the widest and
// tallest, over a step, a wall, an overhang, a comb in midair and the edge of the loaded ground.
@(test)
test_standable_mask_is_standable :: proc(t: ^testing.T) {
	b := Blocks {
		region = {6, 9},
	}
	defer delete(b.solid)
	wall(&b, 2, -3, 3, 1, 1) // a step
	wall(&b, -2, -9, 9, 1, 4) // a wall
	wall(&b, 4, 0, 5, 3, 3) // an overhang
	for x := i32(-4); x <= 3; x += 2 {b.solid[{x, 2, -6}] = true} 	// a comb in midair
	q := query(&b)
	area := voxel.Bounds{{-8, -1, -11}, {9, 6, 12}} // (past the loaded ground)
	solid := solid_mask(q, {area.lo - {0, 1, 0}, area.hi + MAX_BODY})
	for body in ([]Body{{1, 1, 1}, {1, 2, 0}, {2, 1, 1}, {2, 3, 0}, {3, 2, 1}, {MAX_BODY, MAX_BODY, 1}}) {
		m := voxel.mask_make(area, context.temp_allocator)
		standable_mask(&m, solid, body)
		count := 0
		for y in area.lo.y ..< area.hi.y {
			for z in area.lo.z ..< area.hi.z {
				for x in area.lo.x ..< area.hi.x {
					want := standable(q, {x, y, z}, body)
					if want {count += 1}
					if voxel.mask_get(m, {x, y, z}) != want {
						testing.expectf(
							t,
							false,
							"body %v at %v: the mask says %v",
							body,
							[3]i32{x, y, z},
							!want,
						)
						return
					}
				}
			}
		}
		testing.expectf(t, count > 0, "body %v stands nowhere", body)
	}
}

// A block popped again at the cost it was expanded at is skipped and spends none of the
// budget: around a wall, 100 expansions reach the goal (117 did, when such a pop counted),
// by the same way as an unbounded search.
@(test)
test_path_stale_entries_cost_nothing :: proc(t: ^testing.T) {
	b := Blocks {
		region = {40, 40},
	}
	defer delete(b.solid)
	wall(&b, 4, -6, 6, 1, 3)
	q := query(&b)
	full, _ := find(q, {0, 1, 0}, {12, 1, 0}, 100000)
	p, ok := find(q, {0, 1, 0}, {12, 1, 0}, 100)
	testing.expect(t, ok && p.whole, "the way round the wall not found within 100 expansions")
	testing.expect(t, p == full, "a different way from the unbounded search's")
}
