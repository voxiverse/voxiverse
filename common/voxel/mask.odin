package voxel

import "core:math/bits"

// Mask: a set of cells: those of its bounds whose bit is set, and every cell outside the
// bounds when `outside` is true (the solid ground past what is loaded, the open air past
// a template) or none when it is false. The bounds are storage, not part of the set's
// meaning: two masks with different bounds holding the same cells are the same set.
//
// Each operation that writes a mask gives it the outside its result has far from every
// bounds (a union's is either's, a complement's the other), so that the set algebra holds
// of the whole sets; within the written mask's bounds the result is exact, and a cell
// just past them that the result would hold otherwise is cut off, as always. The
// spreads (fill, components, least_cost) work within the bounds they are given and do
// not look outside them.
//
// A mask may wrap along y or z (`wrap`, never x): the set then repeats along that axis
// with the period of its bounds, cell c being in it when the cell c moved into the bounds
// by a multiple of the size along the axis is, and nothing is outside the bounds along
// it: a planet's surface that wraps in longitude, a ring. Wrapping is the row's index
// taken modulo the size, so every operation reading a mask honours it (a source moved
// past the seam comes in at the other side, a spread steps across it); the cells an
// operation writes are those of dst's bounds, as always, and dst's own wrap says what
// they mean.
//
// The cells are bits in rows along x, 64 to a word: the row of (y, z) is the `stride`
// words from `row * stride`, row = (y - lo.y) * size.z + (z - lo.z), and its bit i is the
// cell x = lo.x + i. The bits past size.x in a row's last word are always clear.
Mask :: struct {
	bounds:  Bounds,
	stride:  int,
	words:   []u64,
	outside: bool, // every cell outside the bounds is in the set
	wrap:    Wrap, // the axes along which the set repeats
}

// Wrap: the axes along which a mask or a field repeats with the period of its bounds: y
// and z (1 and 2), never x (the axis of the rows' bits).
Wrap :: bit_set[1 ..= 2]

// MAX_STRIDE: the most words in a row (MAX_EXTENT cells).
@(private)
MAX_STRIDE :: MAX_EXTENT / 64

// mask_make: an empty mask over b.
mask_make :: proc(b: Bounds, allocator := context.allocator, loc := #caller_location) -> Mask {
	check_bounds(b, loc)
	return mask_over(b, make([]u64, mask_words(b), allocator, loc), loc)
}

// mask_full: a mask holding every cell of b.
mask_full :: proc(b: Bounds, allocator := context.allocator, loc := #caller_location) -> Mask {
	m := mask_make(b, allocator, loc)
	box(&m, b)
	return m
}

// mask_over: an empty mask over b whose words are the caller's (a fixed array, a buffer on
// the stack), at least as many as it needs: (size.x + 63) / 64 for each of its size.y *
// size.z rows, so 9 for a box of 3 by 3 by 3. It allocates nothing, has nothing to
// destroy, and lives as long as the words do.
mask_over :: proc(b: Bounds, words: []u64, loc := #caller_location) -> Mask {
	check_bounds(b, loc)
	n := mask_words(b)
	assert(len(words) >= n, "voxel: too few words for a mask's bounds", loc)
	m := Mask {
		bounds = b,
		stride = (int(bounds_size(b).x) + 63) / 64,
		words  = words[:n],
	}
	mask_clear(&m)
	return m
}

// mask_words: how many words a mask over b keeps.
@(private)
mask_words :: proc(b: Bounds) -> int {
	s := bounds_size(b)
	return (int(s.x) + 63) / 64 * int(s.y) * int(s.z)
}

mask_destroy :: proc(m: ^Mask, allocator := context.allocator) {
	delete(m.words, allocator)
	m^ = {}
}

// mask_clear: no cell (outside the bounds either).
mask_clear :: proc(m: ^Mask) {
	for &w in m.words {w = 0}
	m.outside = false
}

// mask_get: c is in the set.
mask_get :: proc(m: Mask, c: Cell) -> bool {
	at := wrapped(m.bounds, m.wrap, c)
	if !bounds_has(m.bounds, at) {return m.outside}
	i := cell_bit(m, at)
	return m.words[i >> 6] & (1 << uint(i & 63)) != 0
}

// mask_set: c joins the set (value true) or leaves it; c is within the bounds.
mask_set :: proc(m: ^Mask, c: Cell, value := true, loc := #caller_location) {
	assert(bounds_has(m.bounds, c), "voxel: mask_set outside the mask's bounds", loc)
	i := cell_bit(m^, c)
	bit := u64(1) << uint(i & 63)
	if value {m.words[i >> 6] |= bit} else {m.words[i >> 6] &~= bit}
}

// mask_count: how many cells of its bounds the set has, within b when it is given: any cell
// of a box within the bounds is `mask_count(m, b) > 0`.
mask_count :: proc(m: Mask, b: Maybe(Bounds) = nil) -> int {
	within := b.? or_else m.bounds
	lo := Cell {
		max(within.lo.x, m.bounds.lo.x),
		max(within.lo.y, m.bounds.lo.y),
		max(within.lo.z, m.bounds.lo.z),
	}
	hi := Cell {
		min(within.hi.x, m.bounds.hi.x),
		min(within.hi.y, m.bounds.hi.y),
		min(within.hi.z, m.bounds.hi.z),
	}
	if lo.x >= hi.x || lo.y >= hi.y || lo.z >= hi.z {return 0}
	x0, x1 := int(lo.x - m.bounds.lo.x), int(hi.x - m.bounds.lo.x)
	n := 0
	for y in lo.y ..< hi.y {
		for z in lo.z ..< hi.z {
			row := row_words(m, row_of(m, y, z))
			for i in x0 >> 6 ..= (x1 - 1) >> 6 {
				n += int(bits.count_ones(row[i] & span_bits(i, x0, x1)))
			}
		}
	}
	return n
}

// mask_bounds: the smallest bounds holding every cell of the set within its bounds; ok
// false when there is none.
mask_bounds :: proc(m: Mask) -> (b: Bounds, ok: bool) {
	s := bounds_size(m.bounds)
	for y in 0 ..< s.y {
		for z in 0 ..< s.z {
			row := row_words(m, int(y) * int(s.z) + int(z))
			for w, i in row {
				if w == 0 {continue}
				c := m.bounds.lo + {i32(i * 64) + i32(bits.count_trailing_zeros(w)), y, z}
				if !ok {b, ok = {c, c + 1}, true}
				b.lo = {min(b.lo.x, c.x), b.lo.y, min(b.lo.z, c.z)}
				b.hi.y, b.hi.z = c.y + 1, max(b.hi.z, c.z + 1)
				b.hi.x = max(
					b.hi.x,
					m.bounds.lo.x + i32(i * 64 + 64) - i32(bits.count_leading_zeros(w)),
				)
			}
		}
	}
	return
}

// runs_next: the next run of cells of the set within b (all of them by default) along x,
// in order of y, then z, then x: the cells lo, lo + {1, 0, 0} ... lo + {length - 1, 0, 0},
// a run that crosses b's sides cut at them. cursor starts at 0 (and is the mask's, not
// b's: give the same b until it is done); ok false when there is none left. A run is a
// span of a world edit (b one chunk's cells), or one box of a mask cut into boxes.
runs_next :: proc(
	m: Mask,
	cursor: ^int,
	b: Maybe(Bounds) = nil,
) -> (
	lo: Cell,
	length: i32,
	ok: bool,
) {
	within := b.? or_else m.bounds
	s := bounds_size(m.bounds)
	l := within.lo - m.bounds.lo
	h := within.hi - m.bounds.lo
	x0, y0, z0 := max(int(l.x), 0), max(int(l.y), 0), max(int(l.z), 0)
	x1, y1, z1 := min(int(h.x), int(s.x)), min(int(h.y), int(s.y)), min(int(h.z), int(s.z))
	if x0 >= x1 || z0 >= z1 {return}
	row_bits := m.stride * 64
	for {
		row, i := cursor^ / row_bits, cursor^ % row_bits
		y, z := row / int(s.z), row % int(s.z)
		switch {
		case y < y0 || (y < y1 && z < z0):
			cursor^ = (max(y, y0) * int(s.z) + z0) * row_bits + x0
			continue
		case y >= y1:
			return
		case z >= z1:
			cursor^ = ((y + 1) * int(s.z) + z0) * row_bits + x0
			continue
		case i < x0:
			cursor^ = row * row_bits + x0
			continue
		case i >= x1:
			cursor^ = (row + 1) * row_bits
			continue
		}
		w := m.words[row * m.stride + i >> 6] >> uint(i & 63)
		if w == 0 {
			cursor^ += 64 - i & 63
			continue
		}
		start := i + int(bits.count_trailing_zeros(w))
		if start >= x1 {
			cursor^ = (row + 1) * row_bits
			continue
		}
		end := start
		for end < x1 {
			rest := 64 - end & 63 // (the bits of this word from end on)
			ones := int(
				bits.count_trailing_zeros(~(m.words[row * m.stride + end >> 6] >> uint(end & 63))),
			)
			end += min(ones, rest)
			if ones < rest {break}
		}
		end = min(end, x1)
		cursor^ = row * row_bits + end
		return m.bounds.lo + {i32(start), i32(y), i32(z)}, i32(end - start), true
	}
}

@(private)
cell_bit :: #force_inline proc(m: Mask, c: Cell) -> int {
	l := c - m.bounds.lo
	return row_of(m, c.y, c.z) * m.stride * 64 + int(l.x)
}

// row_of: the index of the row (y, z), which is within the bounds.
@(private)
row_of :: #force_inline proc(m: Mask, y, z: i32) -> int {
	return int(y - m.bounds.lo.y) * int(m.bounds.hi.z - m.bounds.lo.z) + int(z - m.bounds.lo.z)
}

// row_at: the index of the row (y, z) (brought into the bounds along the axes the mask
// wraps on), ok false when it is outside the bounds.
@(private)
row_at :: #force_inline proc(m: Mask, y, z: i32) -> (row: int, ok: bool) {
	c := Cell{m.bounds.lo.x, y, z}
	if m.wrap != {} {c = wrapped(m.bounds, m.wrap, c)}
	if c.y < m.bounds.lo.y || c.y >= m.bounds.hi.y || c.z < m.bounds.lo.z || c.z >= m.bounds.hi.z {
		return
	}
	return row_of(m, c.y, c.z), true
}

// wrapped: c moved into b by a multiple of b's size along each axis of wrap.
@(private)
wrapped :: #force_inline proc(b: Bounds, wrap: Wrap, c: Cell) -> Cell {
	c := c
	for k in wrap {
		n := b.hi[k] - b.lo[k]
		if n > 0 {c[k] = b.lo[k] + ((c[k] - b.lo[k]) % n + n) % n}
	}
	return c
}

@(private)
row_words :: #force_inline proc(m: Mask, row: int) -> []u64 {
	return m.words[row * m.stride:][:m.stride]
}

// span_bits: the bits of word i that are cells x0 <= x < x1 of a row (x from the row's start).
@(private)
span_bits :: #force_inline proc(i, x0, x1: int) -> u64 {
	lo, hi := max(x0 - i * 64, 0), min(x1 - i * 64, 64)
	if lo >= hi {return 0}
	w := ~u64(0) >> uint(64 - (hi - lo))
	return w << uint(lo)
}

// tail_bits: the bits of a row's last word that are cells.
@(private)
tail_bits :: #force_inline proc(m: Mask) -> u64 {
	r := int(m.bounds.hi.x - m.bounds.lo.x) & 63
	return ~u64(0) if r == 0 else (u64(1) << uint(r)) - 1
}

// bits_at: out's bit i is row's bit start + i (start may be negative), clear past either end
// (or set, past the n cells of the row, when outside is true).
@(private)
bits_at :: proc(row: []u64, start: int, out: []u64, outside := false, n := 0) {
	shift := uint(start & 63)
	first := start >> 6 // (rounds down)
	word :: #force_inline proc(row: []u64, j: int) -> u64 {
		return row[j] if j >= 0 && j < len(row) else 0
	}
	for i in 0 ..< len(out) {
		j := first + i
		if shift == 0 {
			out[i] = word(row, j)
		} else {
			out[i] = word(row, j) >> shift | word(row, j + 1) << (64 - shift)
		}
		if outside {out[i] |= ~span_bits(i, -start, n - start)}
	}
}

// set_span: the cells x0 <= x < x1 of row (y, z) become value; the span is clipped to the
// bounds, the row is within them.
@(private)
set_span :: proc(m: ^Mask, row: int, x0, x1: i32, value: bool) {
	a := int(max(x0, m.bounds.lo.x) - m.bounds.lo.x)
	b := int(min(x1, m.bounds.hi.x) - m.bounds.lo.x)
	if a >= b {return}
	words := row_words(m^, row)
	for i in a >> 6 ..= (b - 1) >> 6 {
		if value {words[i] |= span_bits(i, a, b)} else {words[i] &~= span_bits(i, a, b)}
	}
}

// Op: how `combine` folds a source row into a destination row.
@(private)
Op :: enum u8 {
	Or,
	And,
	And_Not,
}

// combine: dst becomes dst op (src moved by offset), cell by cell within dst's bounds and
// as its outside. The one loop under the set algebra and the Minkowski operations: a row
// at a time, a word at a time.
@(private)
combine :: proc(dst: ^Mask, src: Mask, offset: Cell, op: Op) {
	ds := bounds_size(dst.bounds)
	buf: [MAX_STRIDE]u64
	moved := buf[:dst.stride]
	start := int(dst.bounds.lo.x - offset.x - src.bounds.lo.x)
	n := int(src.bounds.hi.x - src.bounds.lo.x)
	tail := tail_bits(dst^)
	row := 0
	for y in dst.bounds.lo.y ..< dst.bounds.lo.y + ds.y {
		for z in dst.bounds.lo.z ..< dst.bounds.lo.z + ds.z {
			defer row += 1
			words := row_words(dst^, row)
			if src_row, found := row_at(src, y - offset.y, z - offset.z); found {
				bits_at(row_words(src, src_row), start, moved, src.outside, n)
			} else {
				for &w in moved {w = ~u64(0) if src.outside else 0}
			}
			switch op {
			case .Or:
				for &w, i in words {w |= moved[i]}
			case .And:
				for &w, i in words {w &= moved[i]}
			case .And_Not:
				for &w, i in words {w &~= moved[i]}
			}
			if len(words) > 0 {words[len(words) - 1] &= tail}
		}
	}
	switch op {
	case .Or:
		dst.outside ||= src.outside
	case .And:
		dst.outside &&= src.outside
	case .And_Not:
		dst.outside &&= !src.outside
	}
}
