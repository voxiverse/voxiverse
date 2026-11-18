// Package voxel is the geometry of sets of cells, as an image library is the geometry of
// pixels: a Mask is a finite set of cells of Z³, a Field gives each cell of a box a small
// integer, and a handful of operations on them answer the geometry questions a block game
// keeps asking.
//
// It knows nothing of worlds, chunks, blocks or entities: a caller turns what it has into
// masks (the world's solid cells in a box, a template's cells), asks, and applies the answer
// back itself. A neighbourhood, a brush or a body's footprint is itself a Mask of offsets,
// so there is one kind of thing to learn:
//
// - set algebra (`unite`, `intersect`, `subtract`, `complement`, `translate`) and the
//   Minkowski sum and difference with a mask of offsets (`dilate`, `erode`), of which
//   shells, margins and "does a body this big fit here" are compositions;
// - shapes as masks (`box`, `ellipsoid`, `diamond`, `line`) and their turns (`turn`);
// - reachability and its partition (`fill`, `components`), and least cost (`least_cost`,
//   `descend`): moves with integer costs, sources with start values, of which
//   breadth-first distance (`distance`, `nearest`) is the case of unit steps;
// - the first cell a moving point or box touches (`sweep`), and counts (`mask_count`).
//
// Everything is integer arithmetic: the same inputs give the same bits on every machine
// (docs/determinism.md), so the server may run it in its tick. An operation whose cost
// depends on the cells (rather than on the sizes it is given) takes a budget of cells,
// takes what it spends from it (so that several share one) and says when it ran out,
// leaving what it promised.
package voxel

// Cell: a cell of the grid (a block's position, an offset).
Cell :: [3]i32

// Bounds: the cells c with lo <= c < hi on every axis (half-open, as slices are).
Bounds :: struct {
	lo, hi: Cell,
}

// MAX_EXTENT: the most cells on each side of a mask's or a field's bounds.
MAX_EXTENT :: 4096

// FIXED_ONE: positions and lengths that fall between cells (a ray's origin, a body's size,
// a sphere's centre) are fixed point, `[3]i64` in units of 1/FIXED_ONE of a cell.
FIXED_ONE :: 256

// UNREACHED: a Field's value for a cell an operation did not reach.
UNREACHED :: -1

// CUBE and SQUARE: the bounds of the offsets one step from a cell, in space and in the
// horizontal plane (`neighbours`).
CUBE :: Bounds{{-1, -1, -1}, {2, 2, 2}}
SQUARE :: Bounds{{-1, 0, -1}, {2, 1, 2}}

// Field: a small integer for each cell of a box (a distance, a label), x fastest, then z,
// then y.
Field :: struct {
	bounds: Bounds,
	values: []i32,
}

bounds_size :: proc(b: Bounds) -> Cell {
	return {max(b.hi.x - b.lo.x, 0), max(b.hi.y - b.lo.y, 0), max(b.hi.z - b.lo.z, 0)}
}

bounds_volume :: proc(b: Bounds) -> int {
	s := bounds_size(b)
	return int(s.x) * int(s.y) * int(s.z)
}

bounds_has :: proc(b: Bounds, c: Cell) -> bool {
	return(
		c.x >= b.lo.x &&
		c.x < b.hi.x &&
		c.y >= b.lo.y &&
		c.y < b.hi.y &&
		c.z >= b.lo.z &&
		c.z < b.hi.z \
	)
}

// bounds_sum: the bounds of the Minkowski sum of two boxes' cells, what `dilate` of a mask
// in a by a mask in b can reach. Empty when either is.
bounds_sum :: proc(a, b: Bounds) -> Bounds {
	if bounds_volume(a) == 0 || bounds_volume(b) == 0 {return {}}
	return {a.lo + b.lo, a.hi + b.hi - 1}
}

// bounds_around: the bounds of the cells within r of c on each axis (a cube of side 2r+1).
bounds_around :: proc(c: Cell, r: i32) -> Bounds {
	return {c - r, c + r + 1}
}

// field_make: a field over b, every value UNREACHED.
field_make :: proc(b: Bounds, allocator := context.allocator, loc := #caller_location) -> Field {
	check_bounds(b, loc)
	f := Field {
		bounds = b,
		values = make([]i32, bounds_volume(b), allocator, loc),
	}
	for &v in f.values {v = UNREACHED}
	return f
}

field_destroy :: proc(f: ^Field, allocator := context.allocator) {
	delete(f.values, allocator)
	f^ = {}
}

// field_get: the value at c, UNREACHED outside the field's bounds.
field_get :: proc(f: Field, c: Cell) -> i32 {
	if !bounds_has(f.bounds, c) {return UNREACHED}
	return f.values[field_index(f, c)]
}

@(private)
field_index :: #force_inline proc(f: Field, c: Cell) -> int {
	s := bounds_size(f.bounds)
	l := c - f.bounds.lo
	return (int(l.y) * int(s.z) + int(l.z)) * int(s.x) + int(l.x)
}

@(private)
check_bounds :: proc(b: Bounds, loc := #caller_location) {
	s := b.hi - b.lo
	for k in 0 ..< 3 {
		assert(s[k] >= 0 && s[k] <= MAX_EXTENT, "voxel: bounds out of range", loc)
	}
}

// floor_div and ceil_div: a / b rounded down and up, for b > 0.
@(private)
floor_div :: #force_inline proc(a, b: i128) -> i128 {
	q := a / b
	return q - 1 if (a % b != 0 && a < 0) else q
}

@(private)
ceil_div :: #force_inline proc(a, b: i128) -> i128 {
	q := a / b
	return q + 1 if (a % b != 0 && a > 0) else q
}
