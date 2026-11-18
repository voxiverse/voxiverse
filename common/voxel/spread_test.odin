package voxel

import "core:testing"

import "common:base"

// The elements a spread is tried under: the 6, 18 and 26 neighbours, the 4 of the plane, a
// fall with the four sides (not symmetric), and moves of two along x.
spread_elements :: proc() -> [6]Mask {
	fall := mask_make({{-1, -1, -1}, {2, 1, 2}})
	diamond(&fall, {0, 0, 0}, 1)
	mask_set(&fall, {0, 0, 0}, false)
	skip := mask_make({{-2, 0, 0}, {3, 2, 1}})
	mask_set(&skip, {-2, 0, 0})
	mask_set(&skip, {2, 0, 0})
	mask_set(&skip, {0, 1, 0})
	return {neighbours(1), neighbours(2), neighbours(3), neighbours(1, SQUARE), fall, skip}
}

ref_offsets :: proc(e: Mask) -> []Cell {
	out := make([dynamic]Cell, context.temp_allocator)
	for o in ref_cells(e.bounds) {if o != {} && mask_get(e, o) {append(&out, o)}}
	return out[:]
}

// ref_distance: each cell's fewest moves from the sources through the domain, by
// relaxing every cell until nothing changes.
ref_distance :: proc(sources, domain: Ref, e: Mask) -> []i32 {
	d := make([]i32, len(domain.cells))
	for &v in d {v = UNREACHED}
	for c in ref_cells(domain.bounds) {
		if ref_get(domain, c) && ref_get(sources, c) {d[ref_index(domain, c)] = 0}
	}
	offsets := ref_offsets(e)
	for changed := true; changed; {
		changed = false
		for c in ref_cells(domain.bounds) {
			v := d[ref_index(domain, c)]
			if v == UNREACHED {continue}
			for o in offsets {
				n := c + o
				if !ref_get(domain, n) {continue}
				w := &d[ref_index(domain, n)]
				if w^ == UNREACHED || w^ > v + 1 {w^ = v + 1; changed = true}
			}
		}
	}
	return d
}

@(test)
test_a_fill_is_the_least_closed_set_holding_the_seed :: proc(t: ^testing.T) {
	rng := base.rng_make(0xf111)
	elements := spread_elements()
	defer for &e in elements {mask_destroy(&e)}
	for round in 0 ..< 120 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng)
		domain := random_mask(&rng, b, base.rng_int_range(&rng, 30, 90))
		defer mask_destroy(&domain)
		seed := random_mask(&rng, b, 1)
		defer mask_destroy(&seed)
		e := elements[round % len(elements)]
		reached := mask_make(b)
		defer mask_destroy(&reached)
		mask_copy(&reached, seed)
		testing.expect(t, !fill(&reached, domain, e, max(int)))
		// It equals the reference: the cells at a finite distance from the seed.
		rs, rd := ref_of(seed), ref_of(domain)
		defer ref_destroy(&rs)
		defer ref_destroy(&rd)
		d := ref_distance(rs, rd, e)
		defer delete(d)
		for c in ref_cells(b) {
			if mask_get(reached, c) != (d[ref_index(rd, c)] != UNREACHED) {
				testing.expectf(t, false, "round %d: fill differs at %v", round, c)
				break
			}
		}
		// It holds the seed's cells in the domain, lies in the domain and is closed.
		for c in ref_cells(b) {
			if !mask_get(reached, c) {
				testing.expect(t, !(mask_get(seed, c) && mask_get(domain, c)))
				continue
			}
			testing.expect(t, mask_get(domain, c))
			for o in ref_offsets(e) {
				testing.expect(t, !mask_get(domain, c + o) || mask_get(reached, c + o))
			}
		}
		// Spent budgets: a part of it, holding the seed, said so; the domain is untouched.
		before := ref_of(domain)
		defer ref_destroy(&before)
		for budget in ([]int{0, 7, 150, 600}) {
			part := mask_make(b)
			defer mask_destroy(&part)
			mask_copy(&part, seed)
			exhausted := fill(&part, domain, e, budget)
			for c in ref_cells(b) {
				if mask_get(part, c) {testing.expect(t, mask_get(reached, c))}
				if mask_get(seed, c) && mask_get(domain, c) {testing.expect(t, mask_get(part, c))}
			}
			if !exhausted {testing.expect(t, same(part, ref_of_tmp(reached)))}
			if budget == 0 && mask_count(part) > 0 {testing.expect(t, exhausted)}
		}
		testing.expect(t, same(domain, before))
	}
}

@(test)
test_components_partition_the_set :: proc(t: ^testing.T) {
	rng := base.rng_make(0xc0c0)
	elements := spread_elements()
	defer for &e in elements {mask_destroy(&e)}
	for round in 0 ..< 120 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng)
		m := random_mask(&rng, b, base.rng_int_range(&rng, 10, 70))
		defer mask_destroy(&m)
		e := elements[round % 4] // (the symmetric ones)
		labels := field_make(b)
		defer field_destroy(&labels)
		count, exhausted := components(&labels, m, e, max(int))
		testing.expect(t, !exhausted)
		// The reference: label each unlabelled cell's part in order, by relaxation.
		rm := ref_of(m)
		defer ref_destroy(&rm)
		want := make([]i32, len(rm.cells))
		defer delete(want)
		n := i32(0)
		for c in ref_cells(b) {
			if !ref_get(rm, c) || want[ref_index(rm, c)] != 0 {continue}
			n += 1
			one := ref_make(b)
			defer ref_destroy(&one)
			ref_set(&one, c)
			d := ref_distance(one, rm, e)
			defer delete(d)
			for v, i in d {if v != UNREACHED {want[i] = n}}
		}
		testing.expect_value(t, count, int(n))
		for c in ref_cells(b) {
			got := field_get(labels, c)
			testing.expect(t, got == want[ref_index(rm, c)])
			// A partition: each cell of m in exactly one part, every other cell in none.
			testing.expect(t, (got >= 1 && int(got) <= count) == mask_get(m, c))
		}
		// Spent: the parts numbered are whole, every other cell is 0.
		part := field_make(b)
		defer field_destroy(&part)
		done, spent := components(&part, m, e, base.rng_int_max(&rng, 400))
		if spent {
			for c in ref_cells(b) {
				got := field_get(part, c)
				w := want[ref_index(rm, c)]
				testing.expect(t, got == (w if int(w) <= done else 0))
			}
		}
	}
}

@(test)
test_a_distance_field_steps_by_one_and_is_zero_on_the_sources :: proc(t: ^testing.T) {
	rng := base.rng_make(0xd157)
	elements := spread_elements()
	defer for &e in elements {mask_destroy(&e)}
	for round in 0 ..< 120 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng)
		domain := random_mask(&rng, b, base.rng_int_range(&rng, 40, 95))
		defer mask_destroy(&domain)
		sources := random_mask(&rng, random_bounds(&rng), 2)
		defer mask_destroy(&sources)
		e := elements[round % len(elements)]
		limit := base.rng_int_range(&rng, 1, 40)
		f := field_make(b)
		defer field_destroy(&f)
		testing.expect(t, !distance(&f, sources, domain, e, limit, max(int)))
		rs, rd := ref_of(sources), ref_of(domain)
		defer ref_destroy(&rs)
		defer ref_destroy(&rd)
		want := ref_distance(rs, rd, e)
		defer delete(want)
		for c in ref_cells(b) {
			w := want[ref_index(rd, c)]
			if int(w) > limit {w = UNREACHED}
			got := field_get(f, c)
			testing.expect(t, got == w)
			// Zero exactly on the sources in the domain, and one move adds at most one.
			testing.expect(t, (got == 0) == (mask_get(sources, c) && mask_get(domain, c)))
			if got == UNREACHED {continue}
			for o in ref_offsets(e) {
				n := field_get(f, c + o)
				testing.expect(
					t,
					!mask_get(domain, c + o) ||
					int(got) == limit ||
					(n != UNREACHED && n <= got + 1),
				)
			}
			// Descending walks back to a source in as many steps.
			at, steps := c, i32(0)
			for next in descend(f, at, e) {at = next; steps += 1}
			testing.expect(t, steps == got && field_get(f, at) == 0)
		}
		// The nearest source from a cell, through the domain, is the lowest of the nearest.
		from := ref_cells(b)[base.rng_int_max(&rng, bounds_volume(b))]
		if mask_get(domain, from) {
			back := field_make(b)
			defer field_destroy(&back)
			one := mask_make({from, from + 1})
			defer mask_destroy(&one)
			mask_set(&one, from)
			distance(&back, one, domain, e, max(int), max(int))
			targets := mask_make(b)
			defer mask_destroy(&targets)
			unite(&targets, sources)
			best, best_d := Cell{}, i32(-1)
			for c in ref_cells(b) {
				v := field_get(back, c)
				if mask_get(targets, c) &&
				   v != UNREACHED &&
				   (best_d < 0 || v < best_d) {best, best_d = c, v}
			}
			c, steps, found, _ := nearest(targets, from, domain, e, max(int), max(int))
			testing.expect_value(t, found, best_d >= 0)
			if found {
				testing.expect_value(t, c, best)
				testing.expect_value(t, i32(steps), best_d)
			}
		}
		// Spent: the cells within the last whole step have their distances, no other has one.
		part := field_make(b)
		defer field_destroy(&part)
		if distance(&part, sources, domain, e, limit, base.rng_int_max(&rng, 300)) {
			reached := i32(-1)
			for v in part.values {reached = max(reached, v)}
			for c in ref_cells(b) {
				w := want[ref_index(rd, c)]
				testing.expect(
					t,
					field_get(part, c) == (w if w != UNREACHED && w <= reached else UNREACHED),
				)
			}
		}
	}
}
