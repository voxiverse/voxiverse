package voxel

// Moving a point or a box in a straight line through the grid. A box is from + [0, size]
// on each axis, closed, in fixed point (FIXED_ONE a cell; a size of 0 is a point), and it
// moves by delta: it touches a cell when the two closed boxes meet, a face, an edge or a
// corner being enough. So the cells a line touches are the same whichever end it starts
// from, and a line through a corner touches the cells around the corner (a supercover).
// A body that may rest flush against cells and slide along them is given a size one unit
// smaller than its own, so that touching is overlapping.
//
// The walk goes from one instant to the next at which the box's leading face reaches a
// cell boundary on some axis (Amanatides and Woo's, for a box), comparing the instants as
// exact fractions, and at each one takes the slab of cells it now touches.

// Hit: the first cell of a mask a moving box touches.
Hit :: struct {
	cell:   Cell,
	normal: Cell, // the face of cell the box met (pointing back at it); zero when it touched from the start
	t:      i64, // when, as a part of the move in FIXED_ONE units (0 ..= FIXED_ONE), rounded down
}

// sweep: the first cell of m the box from + [0, size] touches moving by delta, at the
// earliest instant; among cells touched first at the same instant, the one met across the
// lowest axis (x, y, z; cells touched from the start before all), then the lowest by y,
// z and x. The budget counts the instants and cells looked at, taken from what the caller
// gives. Each of size and delta is at most MAX_EXTENT cells on each axis.
sweep :: proc(
	m: Mask,
	from, size, delta: [3]i64,
	budget: ^int,
) -> (
	hit: Hit,
	found: bool,
	exhausted: bool,
) {
	w := walk_make(from, size, delta)
	if c, touched, spent := look(m, {w.lo, w.hi + 1}, budget); touched || spent {
		return {cell = c}, touched, spent
	}
	for !walk_past(w, m.bounds) && walk_next(&w) {
		if budget^ <= 0 {return {}, false, true}
		budget^ -= 1
		slabs, axes, n := walk_slabs(w)
		for slab, i in slabs[:n] {
			c, touched, spent := look(m, slab, budget)
			if spent {return {}, false, true}
			if !touched {continue}
			hit = {
				cell = c,
				t    = i64(w.num * FIXED_ONE / w.den),
			}
			hit.normal[axes[i]] = -1 if w.d[axes[i]] > 0 else 1
			return hit, true, false
		}
	}
	return
}

// line: the cells the box from + [0, size] touches moving by delta become value (within
// dst's bounds): a segment of cells for a point, a thick one or a stair for a box.
line :: proc(dst: ^Mask, from, size, delta: [3]i64, value := true) {
	w := walk_make(from, size, delta)
	box(dst, {w.lo, w.hi + 1}, value)
	for !walk_past(w, dst.bounds) && walk_next(&w) {
		slabs, _, n := walk_slabs(w)
		for slab in slabs[:n] {box(dst, slab, value)}
	}
}

// look: the first cell of m within b, by y, then z, then x; spent when the budget ran out.
@(private)
look :: proc(m: Mask, b: Bounds, left: ^int) -> (c: Cell, touched: bool, spent: bool) {
	lo := Cell{max(b.lo.x, m.bounds.lo.x), max(b.lo.y, m.bounds.lo.y), max(b.lo.z, m.bounds.lo.z)}
	hi := Cell{min(b.hi.x, m.bounds.hi.x), min(b.hi.y, m.bounds.hi.y), min(b.hi.z, m.bounds.hi.z)}
	for y in lo.y ..< hi.y {
		for z in lo.z ..< hi.z {
			for x in lo.x ..< hi.x {
				if left^ <= 0 {return {}, false, true}
				left^ -= 1
				if mask_get(m, {x, y, z}) {return {x, y, z}, true, false}
			}
		}
	}
	return
}

// Walk: a box on its way: the cells it touches at the instant num/den of the move (the
// last instant its leading face reached a boundary), lo ..= hi on each axis, and the axes
// whose leading face reached one then.
@(private)
Walk :: struct {
	p, s, d:  [3]i128,
	lo, hi:   Cell,
	num, den: i128,
	tied:     [3]bool,
}

@(private)
walk_make :: proc(from, size, delta: [3]i64) -> Walk {
	w := Walk {
		den = 1,
	}
	for k in 0 ..< 3 {
		assert(size[k] >= 0 && size[k] <= MAX_EXTENT * FIXED_ONE, "voxel: box size out of range")
		assert(abs(delta[k]) <= MAX_EXTENT * FIXED_ONE, "voxel: move out of range")
		w.p[k], w.s[k], w.d[k] = i128(from[k]), i128(size[k]), i128(delta[k])
		w.lo[k] = i32(ceil_div(w.p[k], FIXED_ONE) - 1)
		w.hi[k] = i32(floor_div(w.p[k] + w.s[k], FIXED_ONE))
	}
	return w
}

// walk_next: on to the next instant a leading face reaches a boundary, within the move;
// false when there is none.
@(private)
walk_next :: proc(w: ^Walk) -> bool {
	num, den := i128(0), i128(0)
	w.tied = {}
	for k in 0 ..< 3 {
		n, dk: i128
		switch {
		case w.d[k] > 0:
			n, dk = (i128(w.hi[k]) + 1) * FIXED_ONE - w.p[k] - w.s[k], w.d[k]
		case w.d[k] < 0:
			n, dk = w.p[k] - i128(w.lo[k]) * FIXED_ONE, -w.d[k]
		case:
			continue
		}
		if n > dk {continue} 	// (after the move ends)
		switch {
		case den == 0 || n * den < num * dk:
			num, den = n, dk
			w.tied = {}
			w.tied[k] = true
		case n * den == num * dk:
			w.tied[k] = true
		}
	}
	if den == 0 {return false}
	w.num, w.den = num, den
	for k in 0 ..< 3 {
		at := w.p[k] * den + w.d[k] * num // (the box's low corner, times den)
		switch {
		case w.d[k] > 0:
			if w.tied[k] {w.hi[k] += 1}
			w.lo[k] = i32(ceil_div(at, den * FIXED_ONE) - 1)
		case w.d[k] < 0:
			if w.tied[k] {w.lo[k] -= 1}
			w.hi[k] = i32(floor_div(at + w.s[k] * den, den * FIXED_ONE))
		}
	}
	return true
}

// walk_slabs: the cells the box touches now and did not just before: for each axis that
// reached a boundary, the slab of cells across it, less those of a lower such axis (n of
// them, each with its axis).
@(private)
walk_slabs :: proc(w: Walk) -> (slabs: [3]Bounds, axes: [3]int, n: int) {
	for k in 0 ..< 3 {
		if !w.tied[k] {continue}
		b := Bounds{w.lo, w.hi + 1}
		for j in 0 ..< k {
			if !w.tied[j] {continue}
			if w.d[j] > 0 {b.hi[j] -= 1} else {b.lo[j] += 1}
		}
		if w.d[k] > 0 {b.lo[k] = w.hi[k]} else {b.hi[k] = w.lo[k] + 1}
		slabs[n], axes[n] = b, k
		n += 1
	}
	return
}

// walk_past: the box has left b behind on some axis (or never meets it on an axis it does
// not move along), so it touches no cell of b from now on.
@(private)
walk_past :: proc(w: Walk, b: Bounds) -> bool {
	for k in 0 ..< 3 {
		switch {
		case w.d[k] > 0 && w.lo[k] >= b.hi[k]:
			return true
		case w.d[k] < 0 && w.hi[k] < b.lo[k]:
			return true
		case w.d[k] == 0 && (w.hi[k] < b.lo[k] || w.lo[k] >= b.hi[k]):
			return true
		}
	}
	return false
}
