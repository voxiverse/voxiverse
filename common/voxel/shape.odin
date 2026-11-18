package voxel

// Shapes as masks. Each sets the cells of the shape within dst's bounds to value (true adds
// them, false carves them out), a row at a time: the shape gives each row of dst the span
// of x it covers, and the span is set a word at a time. A hollow box is a box with a
// smaller box carved out, a ring a disc with a smaller disc carved out.

// box: the cells of b.
box :: proc(dst: ^Mask, b: Bounds, value := true) {
	lo := Cell {
		max(b.lo.x, dst.bounds.lo.x),
		max(b.lo.y, dst.bounds.lo.y),
		max(b.lo.z, dst.bounds.lo.z),
	}
	hi := Cell {
		min(b.hi.x, dst.bounds.hi.x),
		min(b.hi.y, dst.bounds.hi.y),
		min(b.hi.z, dst.bounds.hi.z),
	}
	for y in lo.y ..< hi.y {
		for z in lo.z ..< hi.z {set_span(dst, row_of(dst^, y, z), lo.x, hi.x, value)}
	}
}

// ellipsoid: the cells whose centres lie in the solid with that centre and those radii
// (fixed point, FIXED_ONE a cell), round along the axes of `round` and flat along the
// others: Σ (q_k / r_k)² <= 1 over the round axes and |q_k| <= r_k along the flat ones, q
// the offset of a cell's centre from the shape's. All three round is an ellipsoid or a
// sphere, {0, 2} an upright cylinder (a disc when one cell high), none a box. A round
// radius is more than 0, every radius at most MAX_EXTENT cells.
ellipsoid :: proc(
	dst: ^Mask,
	centre, radius: [3]i64,
	round: bit_set[0 ..< 3] = {0, 1, 2},
	value := true,
) {
	for k in 0 ..< 3 {
		assert(radius[k] >= 0 && radius[k] <= MAX_EXTENT * FIXED_ONE, "voxel: radius out of range")
		assert(k not_in round || radius[k] > 0, "voxel: a round radius of 0")
	}
	// In i128: q² is below 2^42 and r² below 2^40, so a term of the sum below 2^122.
	whole := i128(1) // the product of the round radii squared
	for k in round {whole *= i128(radius[k]) * i128(radius[k])}
	weight :: proc(radius: [3]i64, round: bit_set[0 ..< 3], k: int) -> i128 {
		w := i128(1)
		for j in round {if j != k {w *= i128(radius[j]) * i128(radius[j])}}
		return w
	}
	row := 0
	for y in dst.bounds.lo.y ..< dst.bounds.hi.y {
		for z in dst.bounds.lo.z ..< dst.bounds.hi.z {
			defer row += 1
			used := i128(0)
			inside := true
			for k in 1 ..< 3 {
				q := centre_offset(y if k == 1 else z, centre[k])
				if abs(q) > i128(radius[k]) {inside = false; break}
				if k in round {used += q * q * weight(radius, round, k)}
			}
			if !inside || used > whole {continue}
			reach := i128(radius.x) // the most |q.x| in this row
			if 0 in round {reach = isqrt((whole - used) / weight(radius, round, 0))}
			// (2x + 1) * HALF within centre.x ± reach.
			HALF :: FIXED_ONE / 2
			x0 := ceil_div(i128(centre.x) - reach - HALF, 2 * HALF)
			x1 := floor_div(i128(centre.x) + reach - HALF, 2 * HALF)
			x0 = max(x0, i128(dst.bounds.lo.x))
			x1 = min(x1, i128(dst.bounds.hi.x) - 1)
			if x0 <= x1 {set_span(dst, row, i32(x0), i32(x1) + 1, value)}
		}
	}
}

// diamond: the cells within radius steps along the axes of c (|d.x| + |d.y| + |d.z| <=
// radius): the cells a flood of radius steps reaches in the open, the light of a lamp,
// a spruce's layer in the plane.
diamond :: proc(dst: ^Mask, c: Cell, radius: i32, value := true) {
	row := 0
	for y in dst.bounds.lo.y ..< dst.bounds.hi.y {
		for z in dst.bounds.lo.z ..< dst.bounds.hi.z {
			defer row += 1
			r := radius - abs(y - c.y) - abs(z - c.z)
			if r >= 0 {set_span(dst, row, c.x - r, c.x + r + 1, value)}
		}
	}
}

// centre_offset: the offset of cell v's centre from a fixed-point coordinate.
@(private)
centre_offset :: #force_inline proc(v: i32, centre: i64) -> i128 {
	return i128(v) * FIXED_ONE + FIXED_ONE / 2 - i128(centre)
}

// isqrt: the largest r with r * r <= n (n >= 0), bit by bit.
@(private)
isqrt :: proc(n: i128) -> i128 {
	if n <= 0 {return 0}
	v := u128(n)
	r := u128(0)
	bit := u128(1) << 126
	for bit > v {bit >>= 2}
	for bit != 0 {
		if v >= r + bit {
			v -= r + bit
			r = r >> 1 + bit
		} else {
			r >>= 1
		}
		bit >>= 2
	}
	return i128(r)
}
