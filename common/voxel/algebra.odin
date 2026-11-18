package voxel

import "core:slice"

// The set algebra and the Minkowski operations. Each writes its result into dst, within
// dst's bounds (what falls outside them is cut off), so the caller chooses the box and
// owns the memory; a source moved by an offset is the source translated.

// unite: dst becomes dst ∪ (src moved by offset).
unite :: proc(dst: ^Mask, src: Mask, offset := Cell{}) {
	combine(dst, src, offset, .Or)
}

// intersect: dst becomes dst ∩ (src moved by offset).
intersect :: proc(dst: ^Mask, src: Mask, offset := Cell{}) {
	combine(dst, src, offset, .And)
}

// subtract: dst becomes dst ∖ (src moved by offset).
subtract :: proc(dst: ^Mask, src: Mask, offset := Cell{}) {
	combine(dst, src, offset, .And_Not)
}

// complement: dst becomes the cells of its bounds it did not hold.
complement :: proc(dst: ^Mask) {
	if dst.stride == 0 {return}
	tail := tail_bits(dst^)
	for &w, i in dst.words {
		w = ~w
		if (i + 1) % dst.stride == 0 {w &= tail}
	}
}

// translate: the set moved by offset (its bounds move with it: nothing is copied).
translate :: proc(m: ^Mask, offset: Cell) {
	m.bounds.lo += offset
	m.bounds.hi += offset
}

// mask_copy: dst becomes src's cells within dst's bounds.
mask_copy :: proc(dst: ^Mask, src: Mask) {
	mask_clear(dst)
	unite(dst, src)
}

// dilate: dst becomes src ⊕ element, the Minkowski sum {a + b : a in src, b in element}:
// every cell within reach of the set, where element is the reach (a neighbourhood, a
// brush, a body's footprint). `bounds_sum` gives the bounds that hold all of it. dst is
// not src.
dilate :: proc(dst: ^Mask, src: Mask, element: Mask, allocator := context.allocator) {
	assert(
		raw_data(dst.words) != raw_data(src.words) || len(src.words) == 0,
		"voxel: dilate in place",
	)
	mask_clear(dst)
	minkowski(dst, src, element, .Or, allocator)
}

// erode: dst becomes src ⊖ element, the Minkowski difference {c : c + b in src for every b
// in element}: the cells where all of element, put there, lies in the set. With the free
// cells as src and a body's footprint as element, the cells where the body fits. dst is
// not src; an empty element leaves every cell of dst's bounds.
erode :: proc(dst: ^Mask, src: Mask, element: Mask, allocator := context.allocator) {
	assert(
		raw_data(dst.words) != raw_data(src.words) || len(src.words) == 0,
		"voxel: erode in place",
	)
	mask_clear(dst)
	complement(dst)
	minkowski(dst, src, element, .And, allocator)
}

// minkowski: dst folds in (op: .Or for the sum, .And for the difference) src moved by each
// offset of element (by its opposite for the difference). The element is cut into its
// runs along x, a segment each moved to its place, and src summed with a segment of n
// cells is made once for each length (Minkowski sums associate): a pass over dst per run
// and one per cell of the longest run, instead of one per offset: the 26 neighbours take
// 9 and 2 instead of 27, a ball of radius 6 takes 137 and 12 instead of 1189.
@(private)
minkowski :: proc(dst: ^Mask, src: Mask, element: Mask, op: Op, allocator := context.allocator) {
	Run :: struct {
		lo: Cell,
		n:  i32,
	}
	runs := make([dynamic]Run, allocator)
	defer delete(runs)
	cursor := 0
	longest := i32(1)
	for lo, n in runs_next(element, &cursor) {
		append(&runs, Run{lo, n})
		longest = max(longest, n)
	}
	sign := i32(1) if op == .Or else -1
	if longest == 1 {
		for r in runs {combine(dst, src, sign * r.lo, op)}
		return
	}
	// along: src summed with the segment of n cells from the origin (for the sum), or the
	// cells from which all n of it lies in src (for the difference), n growing.
	along_bounds := src.bounds
	if op == .Or {along_bounds.hi.x += longest - 1}
	along := mask_make(along_bounds, allocator)
	defer mask_destroy(&along, allocator)
	unite(&along, src)
	slice.sort_by(runs[:], proc(a, b: Run) -> bool {return a.n < b.n})
	n := i32(1)
	for r in runs {
		for ; n < r.n; n += 1 {combine(&along, src, {sign * n, 0, 0}, op)}
		combine(dst, along, sign * r.lo, op)
	}
}

// neighbours: the offsets within bounds (CUBE or SQUARE) at most reach steps along the axes
// from the origin, the origin among them: reach 1, 2, 3 in CUBE are the 6, 18 and 26
// neighbours of a cell, reach 1 and 2 in SQUARE the 4 and 8 of the horizontal plane.
neighbours :: proc(reach: i32, within := CUBE, allocator := context.allocator) -> Mask {
	m := mask_make(within, allocator)
	diamond(&m, {}, reach)
	return m
}
