package voxel

import "core:testing"

import "common:base"

// The reference the tests hold the package to: a set of cells as a plain array of booleans
// over a box, and each operation written as its definition, a cell at a time.

Ref :: struct {
	bounds: Bounds,
	cells:  []bool,
}

ref_make :: proc(b: Bounds) -> Ref {
	return {bounds = b, cells = make([]bool, bounds_volume(b))}
}

ref_destroy :: proc(r: ^Ref) {
	delete(r.cells)
}

ref_index :: proc(r: Ref, c: Cell) -> int {
	s := bounds_size(r.bounds)
	l := c - r.bounds.lo
	return (int(l.y) * int(s.z) + int(l.z)) * int(s.x) + int(l.x)
}

ref_get :: proc(r: Ref, c: Cell) -> bool {
	return bounds_has(r.bounds, c) && r.cells[ref_index(r, c)]
}

ref_set :: proc(r: ^Ref, c: Cell, v := true) {
	if bounds_has(r.bounds, c) {r.cells[ref_index(r^, c)] = v}
}

ref_of :: proc(m: Mask) -> Ref {
	r := ref_make(m.bounds)
	for c in ref_cells(m.bounds) {ref_set(&r, c, mask_get(m, c))}
	return r
}

// ref_cells: every cell of b, by y, then z, then x (in the temp allocator).
ref_cells :: proc(b: Bounds) -> []Cell {
	out := make([dynamic]Cell, context.temp_allocator)
	for y in b.lo.y ..< b.hi.y {
		for z in b.lo.z ..< b.hi.z {
			for x in b.lo.x ..< b.hi.x {append(&out, Cell{x, y, z})}
		}
	}
	return out[:]
}

// same: m holds exactly the cells of r within m's bounds.
same :: proc(m: Mask, r: Ref) -> bool {
	for c in ref_cells(m.bounds) {
		if mask_get(m, c) != ref_get(r, c) {return false}
	}
	return true
}

// no_limit: a budget that does not run out (in the temp allocator).
no_limit :: proc() -> ^int {
	return new_clone(max(int), context.temp_allocator)
}

// random_bounds: a box of up to 150 cells along x (rows of up to three words) and a few
// along y and z, near the origin.
random_bounds :: proc(rng: ^base.Rng, wide := 150) -> Bounds {
	lo := Cell {
		i32(base.rng_int_range(rng, -70, 20)),
		i32(base.rng_int_range(rng, -4, 2)),
		i32(base.rng_int_range(rng, -4, 2)),
	}
	size := Cell {
		i32(base.rng_int_range(rng, 1, wide)),
		i32(base.rng_int_range(rng, 1, 6)),
		i32(base.rng_int_range(rng, 1, 6)),
	}
	return {lo, lo + size}
}

// random_mask: each cell of b in the set with the chance percent / 100.
random_mask :: proc(rng: ^base.Rng, b: Bounds, percent: int) -> Mask {
	m := mask_make(b)
	for c in ref_cells(b) {
		if base.rng_int_max(rng, 100) < percent {mask_set(&m, c)}
	}
	return m
}

random_offset :: proc(rng: ^base.Rng) -> Cell {
	return {
		i32(base.rng_int_range(rng, -70, 70)),
		i32(base.rng_int_range(rng, -3, 3)),
		i32(base.rng_int_range(rng, -3, 3)),
	}
}

@(test)
test_set_algebra_is_the_cellwise_definition :: proc(t: ^testing.T) {
	rng := base.rng_make(0x5e7)
	for _ in 0 ..< 200 {
		defer free_all(context.temp_allocator)
		a := random_mask(&rng, random_bounds(&rng), base.rng_int_max(&rng, 100))
		defer mask_destroy(&a)
		b := random_mask(&rng, random_bounds(&rng), base.rng_int_max(&rng, 100))
		defer mask_destroy(&b)
		o := random_offset(&rng)
		ra, rb := ref_of(a), ref_of(b)
		defer ref_destroy(&ra)
		defer ref_destroy(&rb)
		Law :: enum {
			Unite,
			Intersect,
			Subtract,
		}
		for law in Law {
			d := mask_make(a.bounds)
			defer mask_destroy(&d)
			mask_copy(&d, a)
			switch law {
			case .Unite:
				unite(&d, b, o)
			case .Intersect:
				intersect(&d, b, o)
			case .Subtract:
				subtract(&d, b, o)
			}
			want := ref_make(a.bounds)
			defer ref_destroy(&want)
			for c in ref_cells(a.bounds) {
				x, y := ref_get(ra, c), ref_get(rb, c - o)
				switch law {
				case .Unite:
					ref_set(&want, c, x || y)
				case .Intersect:
					ref_set(&want, c, x && y)
				case .Subtract:
					ref_set(&want, c, x && !y)
				}
			}
			testing.expectf(
				t,
				same(d, want),
				"%v of %v and %v moved by %v",
				law,
				a.bounds,
				b.bounds,
				o,
			)
		}
		// De Morgan within a's bounds: the complement of a ∪ b is a's complement less b.
		left := mask_make(a.bounds)
		defer mask_destroy(&left)
		mask_copy(&left, a)
		unite(&left, b)
		complement(&left)
		right := mask_make(a.bounds)
		defer mask_destroy(&right)
		mask_copy(&right, a)
		complement(&right)
		subtract(&right, b)
		testing.expect(t, same(left, ref_of_tmp(right)))
		// Translation moves the set: what was at c is at c + o.
		moved := a
		translate(&moved, o)
		for c in ref_cells(a.bounds) {
			if mask_get(a, c) != mask_get(moved, c + o) {
				testing.expectf(t, false, "translate by %v lost %v", o, c)
				break
			}
		}
		// Counts and bounds.
		n := 0
		for v in ra.cells {if v {n += 1}}
		testing.expect_value(t, mask_count(a), n)
		tight, ok := mask_bounds(a)
		testing.expect_value(t, ok, n > 0)
		if ok {testing.expect_value(t, mask_count(a, tight), n)}
		// Runs cover exactly the set, each a maximal span in order.
		runs := ref_make(a.bounds)
		defer ref_destroy(&runs)
		cursor := 0
		for lo, length in runs_next(a, &cursor) {
			testing.expect(t, !mask_get(a, lo - {1, 0, 0}) && !mask_get(a, lo + {length, 0, 0}))
			for k in 0 ..< length {ref_set(&runs, lo + {k, 0, 0})}
		}
		testing.expect(t, same(a, runs))
		// Within a box: the set's cells in it, each run a maximal span of them, in order.
		sub := random_bounds(&rng)
		inside := ref_make(sub)
		defer ref_destroy(&inside)
		in_sub :: proc(a: Mask, sub: Bounds, c: Cell) -> bool {
			return bounds_has(sub, c) && mask_get(a, c)
		}
		cursor = 0
		last := [3]i32{min(i32), 0, 0} // (y, z, x of the last run)
		for lo, length in runs_next(a, &cursor, sub) {
			testing.expect(
				t,
				!in_sub(a, sub, lo - {1, 0, 0}) && !in_sub(a, sub, lo + {length, 0, 0}),
			)
			at := [3]i32{lo.y, lo.z, lo.x}
			testing.expect(
				t,
				at.x > last.x ||
				(at.x == last.x && (at.y > last.y || (at.y == last.y && at.z > last.z))),
			)
			last = at
			for k in 0 ..< length {
				testing.expect(t, in_sub(a, sub, lo + {k, 0, 0}))
				ref_set(&inside, lo + {k, 0, 0})
			}
		}
		for c in ref_cells(sub) {testing.expect(t, ref_get(inside, c) == mask_get(a, c))}
	}
}

// ref_of_tmp: ref_of, freed with the temp allocator.
ref_of_tmp :: proc(m: Mask) -> Ref {
	r := Ref {
		bounds = m.bounds,
		cells  = make([]bool, bounds_volume(m.bounds), context.temp_allocator),
	}
	for c in ref_cells(m.bounds) {ref_set(&r, c, mask_get(m, c))}
	return r
}
