package voxel

import "core:testing"

import "common:base"

// random_element: a small mask of offsets around the origin.
random_element :: proc(rng: ^base.Rng) -> Mask {
	b := Bounds{{-2, -1, -1}, {3, 2, 2}}
	e := random_mask(rng, b, 25)
	if base.rng_int_max(rng, 2) == 0 {mask_set(&e, {})}
	return e
}

ref_dilate :: proc(a: Ref, e: Mask, b: Bounds) -> Ref {
	r := ref_make(b)
	for c in ref_cells(b) {
		for o in ref_cells(e.bounds) {
			if mask_get(e, o) && ref_get(a, c - o) {ref_set(&r, c); break}
		}
	}
	return r
}

ref_erode :: proc(a: Ref, e: Mask, b: Bounds) -> Ref {
	r := ref_make(b)
	for c in ref_cells(b) {
		all := true
		for o in ref_cells(e.bounds) {
			if mask_get(e, o) && !ref_get(a, c + o) {all = false; break}
		}
		ref_set(&r, c, all)
	}
	return r
}

@(test)
test_dilation_and_erosion_are_adjoint :: proc(t: ^testing.T) {
	rng := base.rng_make(0xad7)
	for round in 0 ..< 150 {
		defer free_all(context.temp_allocator)
		a := random_mask(&rng, random_bounds(&rng, 100), base.rng_int_range(&rng, 5, 60))
		defer mask_destroy(&a)
		e := random_element(&rng)
		defer mask_destroy(&e)
		ra := ref_of(a)
		defer ref_destroy(&ra)
		// Both are their definitions.
		sum := mask_make(bounds_sum(a.bounds, e.bounds))
		defer mask_destroy(&sum)
		dilate(&sum, a, e)
		want := ref_dilate(ra, e, sum.bounds)
		testing.expect(t, same(sum, want))
		ref_destroy(&want)
		eroded := mask_make(a.bounds)
		defer mask_destroy(&eroded)
		erode(&eroded, a, e)
		want = ref_erode(ra, e, a.bounds)
		testing.expect(t, same(eroded, want))
		ref_destroy(&want)
		// With every cell past a's bounds in the set: still the definitions (on bounds a
		// cell wider, so that some of what lies past a's is looked at), and the outsides
		// are the sum's and the difference's far from a.
		{
			full := a
			full.outside = true
			rf := ref_of_tmp(full)
			wide := Bounds{sum.bounds.lo - 1, sum.bounds.hi + 1}
			fsum := mask_make(wide)
			defer mask_destroy(&fsum)
			dilate(&fsum, full, e)
			testing.expect(t, fsum.outside == (mask_count(e) > 0))
			fwant := ref_dilate(rf, e, wide)
			testing.expect(t, same(fsum, fwant))
			ref_destroy(&fwant)
			fdiff := mask_make(wide)
			defer mask_destroy(&fdiff)
			erode(&fdiff, full, e)
			testing.expect(t, fdiff.outside)
			fwant = ref_erode(rf, e, wide)
			testing.expect(t, same(fdiff, fwant))
			ref_destroy(&fwant)
		}
		// Repeating along y or z: still the definitions, on bounds wider than a period.
		{
			periodic := a
			periodic.wrap = {1 + base.rng_int_max(&rng, 2)}
			rp := ref_of_tmp(periodic)
			wide := Bounds{sum.bounds.lo - 3, sum.bounds.hi + 3}
			psum := mask_make(wide)
			defer mask_destroy(&psum)
			dilate(&psum, periodic, e)
			pwant := ref_dilate(rp, e, wide)
			testing.expect(t, same(psum, pwant))
			ref_destroy(&pwant)
			pdiff := mask_make(wide)
			defer mask_destroy(&pdiff)
			erode(&pdiff, periodic, e)
			pwant = ref_erode(rp, e, wide)
			testing.expect(t, same(pdiff, pwant))
			ref_destroy(&pwant)
		}
		// A ⊕ E ⊆ C if and only if A ⊆ C ⊖ E: C is the sum, sometimes less a cell or two
		// and sometimes with noise added.
		c := mask_make(sum.bounds)
		defer mask_destroy(&c)
		mask_copy(&c, sum)
		for _ in 0 ..< base.rng_int_max(&rng, 3) {
			cells := ref_cells(c.bounds)
			mask_set(&c, cells[base.rng_int_max(&rng, len(cells))], base.rng_int_max(&rng, 2) == 0)
		}
		inside := mask_make(sum.bounds)
		defer mask_destroy(&inside)
		mask_copy(&inside, sum)
		subtract(&inside, c)
		sum_within := mask_count(inside) == 0
		back := mask_make(a.bounds)
		defer mask_destroy(&back)
		erode(&back, c, e)
		left := mask_make(a.bounds)
		defer mask_destroy(&left)
		mask_copy(&left, a)
		subtract(&left, back)
		a_within := mask_count(left) == 0
		testing.expectf(
			t,
			sum_within == a_within,
			"round %d: A⊕E ⊆ C is %v, A ⊆ C⊖E is %v",
			round,
			sum_within,
			a_within,
		)
	}
}
