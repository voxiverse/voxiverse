package voxel

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
dilate :: proc(dst: ^Mask, src: Mask, element: Mask) {
	assert(
		raw_data(dst.words) != raw_data(src.words) || len(src.words) == 0,
		"voxel: dilate in place",
	)
	mask_clear(dst)
	cursor := 0
	for lo, n in runs_next(element, &cursor) {
		for k in 0 ..< n {unite(dst, src, lo + {k, 0, 0})}
	}
}

// erode: dst becomes src ⊖ element, the Minkowski difference {c : c + b in src for every b
// in element}: the cells where all of element, put there, lies in the set. With the free
// cells as src and a body's footprint as element, the cells where the body fits. dst is
// not src; an empty element leaves every cell of dst's bounds.
erode :: proc(dst: ^Mask, src: Mask, element: Mask) {
	assert(
		raw_data(dst.words) != raw_data(src.words) || len(src.words) == 0,
		"voxel: erode in place",
	)
	mask_clear(dst)
	complement(dst)
	cursor := 0
	for lo, n in runs_next(element, &cursor) {
		for k in 0 ..< n {intersect(dst, src, -(lo + {k, 0, 0}))}
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
