package voxel

import "core:testing"

import "common:base"

// Frac: num / den, den > 0.
Frac :: struct {
	num, den: i128,
}

frac_less :: proc(a, b: Frac) -> bool {return a.num * b.den < b.num * a.den}

// ref_touch: when the closed box from + [0, size] moving by delta first touches the
// cell c, and across which axis (-1: from the start), from the definition: the instants
// at which the two closed boxes meet on every axis, an interval for each, intersected.
ref_touch :: proc(c: Cell, from, size, delta: [3]i64) -> (at: Frac, axis: int, touched: bool) {
	lo, hi := Frac{0, 1}, Frac{1, 1}
	lows: [3]Frac
	for k in 0 ..< 3 {
		p, s, d := i128(from[k]), i128(size[k]), i128(delta[k])
		a, b := i128(c[k]) * FIXED_ONE, (i128(c[k]) + 1) * FIXED_ONE // the cell is [a, b]
		// a <= p + s + d t and p + d t <= b.
		l, h: Frac
		switch {
		case d == 0:
			if a > p + s || p > b {return}
			lows[k] = {-1, 1}
			continue
		case d > 0:
			l, h = {a - p - s, d}, {b - p, d}
		case:
			l, h = {p - b, -d}, {p + s - a, -d}
		}
		lows[k] = l
		if frac_less(lo, l) {lo = l}
		if frac_less(h, hi) {hi = h}
	}
	if frac_less(hi, lo) {return}
	axis = -1
	if lo.num > 0 {
		for k in 0 ..< 3 {
			if delta[k] != 0 &&
			   !frac_less(lows[k], lo) &&
			   !frac_less(lo, lows[k]) {axis = k; break}
		}
	}
	return lo, axis, true
}

random_box :: proc(rng: ^base.Rng) -> (from, size, delta: [3]i64) {
	// Coordinates on whole and half cells half the time, so that faces, edges and corners
	// meet exactly.
	pick :: proc(rng: ^base.Rng, lo, hi: int) -> i64 {
		v := i64(base.rng_int_range(rng, lo * FIXED_ONE, hi * FIXED_ONE))
		switch base.rng_int_max(rng, 4) {
		case 0:
			v &~= FIXED_ONE - 1
		case 1:
			v &~= FIXED_ONE / 2 - 1
		}
		return v
	}
	for k in 0 ..< 3 {
		from[k] = pick(rng, -6, 6)
		size[k] = pick(rng, 0, 3) if base.rng_int_max(rng, 2) == 0 else 0
		delta[k] = pick(rng, -9, 9) if base.rng_int_max(rng, 5) != 0 else 0
	}
	return
}

@(test)
test_a_sweep_touches_what_the_definition_touches :: proc(t: ^testing.T) {
	rng := base.rng_make(0x5ee9)
	for round in 0 ..< 400 {
		defer free_all(context.temp_allocator)
		from, size, delta := random_box(&rng)
		b := Bounds{{-10, -10, -10}, {11, 11, 11}}
		m := random_mask(&rng, b, base.rng_int_range(&rng, 0, 8))
		defer mask_destroy(&m)
		// The cells it touches are the line's.
		touched := mask_make(b)
		defer mask_destroy(&touched)
		line(&touched, from, size, delta)
		first: Hit
		first_at, first_axis := Frac{2, 1}, 3
		for c in ref_cells(b) {
			at, axis, ok := ref_touch(c, from, size, delta)
			testing.expectf(t, mask_get(touched, c) == ok, "round %d: line at %v", round, c)
			if !ok || !mask_get(m, c) {continue}
			// The first: earliest, then by axis, then by y, z, x (the order of ref_cells).
			if !frac_less(at, first_at) &&
			   (frac_less(first_at, at) || axis >= first_axis) {continue}
			first, first_at, first_axis = {
					cell = c,
					t    = i64(at.num * FIXED_ONE / at.den),
				}, at, axis
			if axis >= 0 {first.normal[axis] = -1 if delta[axis] > 0 else 1}
		}
		any := first_axis < 3
		hit, found, exhausted := sweep(m, from, size, delta, no_limit())
		testing.expect(t, !exhausted)
		testing.expect_value(t, found, any)
		if found &&
		   any {testing.expectf(t, hit == first, "round %d: %v, want %v", round, hit, first)}
		// The same cells from the other end, and mirrored.
		back := mask_make(b)
		defer mask_destroy(&back)
		line(&back, from + delta, size, -delta)
		testing.expect(t, same(back, ref_of_tmp(touched)))
		mirrored := mask_make(turn_bounds(MIRROR_X, b))
		defer mask_destroy(&mirrored)
		line(&mirrored, {-from.x - size.x, from.y, from.z}, size, {-delta.x, delta.y, delta.z})
		turned := mask_make(turn_bounds(MIRROR_X, b))
		defer mask_destroy(&turned)
		turn(&turned, touched, MIRROR_X)
		testing.expect(t, same(mirrored, ref_of_tmp(turned)))
		// Spent: nothing found, and said so.
		if found {
			none := 0
			_, found_spent, spent := sweep(m, from, size, delta, &none)
			testing.expect(t, spent && !found_spent)
		}
		// With every cell past the mask's bounds in it, or with it repeating along y or z: the
		// first cell touched among them all.
		if round % 4 < 2 {
			if round % 4 == 0 {m.outside = true} else {m.wrap = {1 + base.rng_int_max(&rng, 2)}}
			wide := Bounds{b.lo - 12, b.hi + 12} // (every cell the move can touch)
			want: Hit
			want_at, want_axis := Frac{2, 1}, 3
			for c in ref_cells(wide) {
				at, axis, ok := ref_touch(c, from, size, delta)
				if !ok || !mask_get(m, c) {continue}
				if !frac_less(at, want_at) &&
				   (frac_less(want_at, at) || axis >= want_axis) {continue}
				want, want_at, want_axis = {
						cell = c,
						t    = i64(at.num * FIXED_ONE / at.den),
					}, at, axis
				if axis >= 0 {want.normal[axis] = -1 if delta[axis] > 0 else 1}
			}
			got, hit, _ := sweep(m, from, size, delta, no_limit())
			testing.expect_value(t, hit, want_axis < 3)
			if hit {testing.expectf(t, got == want, "round %d: %v, want %v", round, got, want)}
		}
	}
}
