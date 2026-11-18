package voxel

import "core:testing"

import "common:base"

// ref_least_cost: Dijkstra's algorithm as it is written, a cell at a time: the unsettled
// cell of least value settles and offers each move's cell its value plus the cost.
ref_least_cost :: proc(seeds: []i32, domain: Ref, moves: []Move, limit: i32) -> []i32 {
	d := make([]i32, len(domain.cells))
	settled := make([]bool, len(domain.cells), context.temp_allocator)
	cells := ref_cells(domain.bounds)
	for v, i in seeds {
		d[i] = v if v != UNREACHED && v <= limit else UNREACHED
	}
	for {
		at := -1
		for v, i in d {
			if v != UNREACHED && !settled[i] && (at < 0 || v < d[at]) {at = i}
		}
		if at < 0 {break}
		settled[at] = true
		for m in moves {
			if m.from != nil && !mask_get(m.from^, cells[at]) {continue}
			n := cells[at] + m.offset
			if !ref_get(domain, n) {continue}
			w := &d[ref_index(domain, n)]
			c := d[at] + m.cost
			if c <= limit && (w^ == UNREACHED || c < w^) {w^ = c}
		}
	}
	return d
}

// random_moves: a few moves within two cells along x and one along y and z, each with a
// cost of least to least + 9 and, now and then, cells of its own.
random_moves :: proc(rng: ^base.Rng, b: Bounds, least: i32) -> []Move {
	moves := make([dynamic]Move, context.temp_allocator)
	for _ in 0 ..< base.rng_int_range(rng, 1, 9) {
		m := Move {
			offset = {
				i32(base.rng_int_range(rng, -2, 3)),
				i32(base.rng_int_range(rng, -1, 2)),
				i32(base.rng_int_range(rng, -1, 2)),
			},
			cost   = least + i32(base.rng_int_max(rng, 10)),
		}
		if m.offset == {} {continue}
		if base.rng_int_max(rng, 4) == 0 {
			from := new(Mask, context.temp_allocator)
			from^ = random_mask(rng, b, 70)
			m.from = from
		}
		append(&moves, m)
	}
	return moves[:]
}

destroy_moves :: proc(moves: []Move) {
	for m in moves {if m.from != nil {delete(m.from.words, context.allocator)}}
}

// random_seeds: a few cells of b with a value up to 20, every other cell UNREACHED.
random_seeds :: proc(rng: ^base.Rng, b: Bounds) -> Field {
	f := field_make(b)
	for _ in 0 ..< base.rng_int_range(rng, 1, 4) {
		cells := ref_cells(b)
		c := cells[base.rng_int_max(rng, len(cells))]
		f.values[field_index(f, c)] = i32(base.rng_int_max(rng, 21))
	}
	return f
}

@(test)
test_least_cost_is_dijkstra :: proc(t: ^testing.T) {
	rng := base.rng_make(0xc057)
	for round in 0 ..< 150 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng, 80)
		domain := random_mask(&rng, b, base.rng_int_range(&rng, 40, 95))
		defer mask_destroy(&domain)
		drawn := random_moves(&rng, b, 0)
		defer destroy_moves(drawn)
		moves := drawn
		if round % 3 == 0 {
			// An element's moves at one cost: runs along x, taken as spans.
			e := random_element(&rng)
			defer mask_destroy(&e)
			moves = moves_of(e, i32(base.rng_int_range(&rng, 1, 6)), context.temp_allocator)
		}
		seeds := random_seeds(&rng, b)
		defer field_destroy(&seeds)
		limit := i32(base.rng_int_range(&rng, 0, 200))
		if round % 2 == 0 {limit = max(i32)} 	// (no limit at all)
		rd := ref_of(domain)
		defer ref_destroy(&rd)
		want := ref_least_cost(seeds.values, rd, moves, limit)
		defer delete(want)
		f := field_make(b)
		defer field_destroy(&f)
		copy(f.values, seeds.values)
		testing.expect(t, !least_cost(&f, domain, moves, int(limit), no_limit()))
		for v, i in f.values {
			if v != want[i] {
				testing.expectf(
					t,
					false,
					"round %d: %v at %v, want %v",
					round,
					v,
					ref_cells(b)[i],
					want[i],
				)
				break
			}
		}
	}
}

@(test)
test_a_least_cost_field_is_consistent_and_descends_to_a_seed :: proc(t: ^testing.T) {
	rng := base.rng_make(0xde5c)
	for round in 0 ..< 150 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng, 40)
		domain := random_mask(&rng, b, base.rng_int_range(&rng, 50, 95))
		defer mask_destroy(&domain)
		moves := random_moves(&rng, b, 1)
		defer destroy_moves(moves)
		seeds := random_seeds(&rng, b)
		defer field_destroy(&seeds)
		f := field_make(b)
		defer field_destroy(&f)
		copy(f.values, seeds.values)
		least_cost(&f, domain, moves, max(int), no_limit())
		for c in ref_cells(b) {
			v := field_get(f, c)
			if v == UNREACHED {continue}
			// Along every move, value there <= value here + cost.
			for m in moves {
				if m.from != nil && !mask_get(m.from^, c) {continue}
				if !mask_get(domain, c + m.offset) {continue}
				n := field_get(f, c + m.offset)
				testing.expect(t, n != UNREACHED && n <= v + m.cost)
			}
			// A cell is its own seed's value, or one move from a cell explains it.
			own := field_get(seeds, c) == v
			explained := false
			for m in moves {
				p := c - m.offset
				if m.from != nil && !mask_get(m.from^, p) {continue}
				u := field_get(f, p)
				if u != UNREACHED && u + m.cost == v {explained = true}
			}
			testing.expectf(t, own || explained, "round %d: %v at %v unexplained", round, v, c)
			// Descending sums the costs back to a seed of the value it starts from.
			at := c
			spent := i32(0)
			for next in descend(f, at, moves) {
				spent += field_get(f, at) - field_get(f, next)
				at = next
			}
			testing.expect(
				t,
				field_get(seeds, at) == field_get(f, at) && spent + field_get(f, at) == v,
			)
		}
	}
}

@(test)
test_unit_moves_and_zero_seeds_are_breadth_first_distance :: proc(t: ^testing.T) {
	rng := base.rng_make(0x0b1)
	elements := spread_elements()
	defer for &e in elements {mask_destroy(&e)}
	for round in 0 ..< 120 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng)
		domain := random_mask(&rng, b, base.rng_int_range(&rng, 40, 95))
		defer mask_destroy(&domain)
		sources := random_mask(&rng, b, 2)
		defer mask_destroy(&sources)
		e := elements[round % len(elements)]
		f := field_make(b)
		defer field_destroy(&f)
		for c in ref_cells(b) {if mask_get(sources, c) {f.values[field_index(f, c)] = 0}}
		least_cost(&f, domain, moves_of(e, 1, context.temp_allocator), max(int), no_limit())
		rs, rd := ref_of(sources), ref_of(domain)
		defer ref_destroy(&rs)
		defer ref_destroy(&rd)
		want := ref_distance(rs, rd, e)
		defer delete(want)
		d := field_make(b)
		defer field_destroy(&d)
		distance(&d, sources, domain, e, max(int), no_limit())
		for v, i in f.values {
			testing.expect(t, v == want[i] && d.values[i] == v)
		}
	}
}

@(test)
test_a_stopped_or_spent_spread_is_the_whole_cut_short :: proc(t: ^testing.T) {
	rng := base.rng_make(0x5709)
	for round in 0 ..< 150 {
		defer free_all(context.temp_allocator)
		b := random_bounds(&rng, 40)
		domain := random_mask(&rng, b, base.rng_int_range(&rng, 50, 95))
		defer mask_destroy(&domain)
		moves := random_moves(&rng, b, 0)
		defer destroy_moves(moves)
		seeds := random_seeds(&rng, b)
		defer field_destroy(&seeds)
		whole := field_make(b)
		defer field_destroy(&whole)
		copy(whole.values, seeds.values)
		least_cost(&whole, domain, moves, max(int), no_limit())
		// cut_below: part is whole without the cells that cost more than its dearest.
		cut_below :: proc(part, whole: Field) -> bool {
			dearest := i32(-1)
			for v in part.values {dearest = max(dearest, v)}
			for v, i in part.values {
				w := whole.values[i]
				if v != (w if w != UNREACHED && w <= dearest else UNREACHED) {return false}
			}
			return true
		}
		// Stopped at a goal: its value is the whole's, and the rest is the whole cut there.
		cells := ref_cells(b)
		goal := cells[base.rng_int_max(&rng, len(cells))]
		stop := mask_make({goal, goal + 1})
		defer mask_destroy(&stop)
		mask_set(&stop, goal)
		part := field_make(b)
		defer field_destroy(&part)
		copy(part.values, seeds.values)
		testing.expect(t, !least_cost(&part, domain, moves, max(int), no_limit(), stop))
		g := field_get(whole, goal)
		testing.expectf(t, field_get(part, goal) == g, "round %d: goal %v", round, goal)
		if g != UNREACHED {
			for v in part.values {testing.expect(t, v <= g)}
		}
		testing.expect(t, cut_below(part, whole))
		// Spent: the whole cut short, and said so.
		copy(part.values, seeds.values)
		given := base.rng_int_max(&rng, 400)
		budget := given
		spent := least_cost(&part, domain, moves, max(int), &budget)
		testing.expect(t, budget >= 0 && (given - budget) % int(bounds_size(b).x) == 0)
		testing.expect(t, cut_below(part, whole))
		if !spent {
			for v, i in part.values {testing.expect(t, v == whole.values[i])}
		}
	}
}
