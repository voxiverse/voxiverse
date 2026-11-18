package voxel

import "core:math/bits"

// Turn: a turn or mirror of the grid about the origin, a matrix with one ±1 in each row
// and column (the 48 symmetries of the cube; the 24 with determinant 1 are the turns).
// Turns compose as matrices do, `b * a` being a then b, and a turn's inverse is its
// transpose (`turn_inverse`). It maps a cell as it maps the cell's centre: the cell c goes to
// (m * (2c + 1) - 1) / 2.
Turn :: matrix[3, 3]i32

IDENTITY :: Turn{1, 0, 0, 0, 1, 0, 0, 0, 1}

// TURN_Y: a quarter turn about the y axis, (x, z) to (-z, x): clockwise seen from above,
// as the engine turns a template or a block (`game.template_cell`, `game.box_rotate`).
TURN_Y :: Turn{0, 0, -1, 0, 1, 0, 1, 0, 0}

// TURN_X: a quarter turn about the x axis, (y, z) to (-z, y).
TURN_X :: Turn{1, 0, 0, 0, 0, -1, 0, 1, 0}

// TURN_Z: a quarter turn about the z axis, (x, y) to (-y, x).
TURN_Z :: Turn{0, -1, 0, 1, 0, 0, 0, 0, 1}

// MIRROR_X, MIRROR_Y, MIRROR_Z: x to -x, y to -y, z to -z.
MIRROR_X :: Turn{-1, 0, 0, 0, 1, 0, 0, 0, 1}
MIRROR_Y :: Turn{1, 0, 0, 0, -1, 0, 0, 0, 1}
MIRROR_Z :: Turn{1, 0, 0, 0, 1, 0, 0, 0, -1}

// turn_inverse: the turn that undoes m (its transpose).
turn_inverse :: proc(m: Turn) -> (inverse: Turn) {
	for i in 0 ..< 3 {
		for j in 0 ..< 3 {inverse[i, j] = m[j, i]}
	}
	return
}

// turn_cell: where m takes the cell c.
turn_cell :: proc(m: Turn, c: Cell) -> Cell {
	v := m * (2 * c + 1)
	return (v - 1) / 2
}

// turn_bounds: the bounds of b's cells turned by m.
turn_bounds :: proc(m: Turn, b: Bounds) -> Bounds {
	if bounds_volume(b) == 0 {return {}}
	p, q := turn_cell(m, b.lo), turn_cell(m, b.hi - 1)
	return {
		{min(p.x, q.x), min(p.y, q.y), min(p.z, q.z)},
		{max(p.x, q.x), max(p.y, q.y), max(p.z, q.z)} + 1,
	}
}

// turn: dst becomes the cells of src turned by m about the origin, within dst's bounds
// (turn_bounds gives the bounds that hold them all; translate moves them after). A cell
// at a time. dst is not src.
turn :: proc(dst: ^Mask, src: Mask, m: Turn) {
	assert(
		raw_data(dst.words) != raw_data(src.words) || len(src.words) == 0,
		"voxel: turn in place",
	)
	mask_clear(dst)
	s := bounds_size(src.bounds)
	for y in 0 ..< s.y {
		for z in 0 ..< s.z {
			for w, i in row_words(src, int(y) * int(s.z) + int(z)) {
				for rest := w; rest != 0; rest &= rest - 1 {
					x := i32(i * 64) + i32(bits.count_trailing_zeros(rest))
					c := turn_cell(m, src.bounds.lo + {x, y, z})
					if bounds_has(dst.bounds, c) {mask_set(dst, c)}
				}
			}
		}
	}
}
