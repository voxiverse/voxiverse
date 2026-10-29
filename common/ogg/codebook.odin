package ogg

// Vorbis codebooks: the Huffman tree built from codeword lengths, the vector
// tables of lookup types 1 and 2.

MAX_CODEBOOKS :: 256
MAX_BOOK_ENTRIES :: 1 << 16
MAX_BOOK_DIM :: 16
MAX_LOOKUP_BYTES :: 4 << 20 // every codebook's vector table together
FAST_BITS :: 10

Codebook :: struct {
	dim:        int,
	entries:    int,
	has_vq:     bool, // lookup type 1 or 2: vectors can be decoded
	fast_bits:  u32,
	fast:       []u32, // (entry << 8) | length, 0 when the code is longer
	long_codes: []u32, // codes longer than fast_bits, left-aligned, ascending
	long_entry: []u32,
	long_len:   []u8,
	vecs:       []f32, // entries * dim
}

// reverse32 flips the bits of a word: codes are assigned most significant
// bit first, the stream delivers the first bit as the least significant.
reverse32 :: proc "contextless" (x_in: u32) -> u32 {
	x := x_in
	x = ((x >> 1) & 0x55555555) | ((x & 0x55555555) << 1)
	x = ((x >> 2) & 0x33333333) | ((x & 0x33333333) << 2)
	x = ((x >> 4) & 0x0f0f0f0f) | ((x & 0x0f0f0f0f) << 4)
	x = ((x >> 8) & 0x00ff00ff) | ((x & 0x00ff00ff) << 8)
	return (x >> 16) | (x << 16)
}

// float32_unpack is the spec's: a 21-bit mantissa and a 10-bit exponent. The
// powers of two are built by exact doubling, no libm.
float32_unpack :: proc "contextless" (x: u32) -> f32 {
	mant := f64(x & 0x1fffff)
	sign := x & 0x80000000 != 0
	e := int((x & 0x7fe00000) >> 21) - 788
	p: f64 = 1
	if e > 0 {
		for _ in 0 ..< e {p *= 2}
	} else {
		for _ in 0 ..< -e {p *= 0.5}
	}
	v := mant * p
	return f32(-v if sign else v)
}

// lookup1_values: the greatest integer v with v^dim <= entries.
lookup1_values :: proc "contextless" (entries, dim: int) -> int {
	v := 1
	for {
		p := 1
		over := false
		for _ in 0 ..< dim {
			p *= v + 1
			if p > entries {over = true; break}
		}
		if over {break}
		v += 1
	}
	return v
}

// codebook_parse reads one codebook; lookup_left is the budget of vector
// table bytes still unspent (decremented).
codebook_parse :: proc "contextless" (
	r: ^Bits,
	a: ^Arena,
	cb: ^Codebook,
	lookup_left: ^int,
) -> (
	err: Error,
) {
	if bits_read(r, 24) != 0x564342 {return .Bad_Setup}
	dim := int(bits_read(r, 16))
	entries := int(bits_read(r, 24))
	if dim < 1 || dim > MAX_BOOK_DIM {return .Over_Limit if dim > 0 else .Bad_Setup}
	if entries < 1 ||
	   entries > MAX_BOOK_ENTRIES {return .Over_Limit if entries > 0 else .Bad_Setup}
	cb.dim, cb.entries = dim, entries
	lens, ok := arena_make(a, u8, entries)
	if !ok {return .Over_Limit}
	ordered := bits_read(r, 1) != 0
	if ordered {
		cur := int(bits_read(r, 5)) + 1
		i := 0
		for i < entries {
			count := int(bits_read(r, u32(ilog(entries - i))))
			if r.eop || i + count > entries || cur > 32 {return .Bad_Setup}
			for k in 0 ..< count {lens[i + k] = u8(cur)}
			i += count
			cur += 1
		}
	} else {
		sparse := bits_read(r, 1) != 0
		for i in 0 ..< entries {
			if sparse && bits_read(r, 1) == 0 {continue}
			lens[i] = u8(bits_read(r, 5) + 1)
		}
	}
	if r.eop {return .Bad_Setup}
	// The tree must be full, or have exactly one used entry.
	used, kraft: u64
	last_used := 0
	max_len: u8
	for l, i in lens {
		if l == 0 {continue}
		used += 1
		kraft += u64(1) << (32 - u64(l))
		last_used = i
		max_len = max(max_len, l)
	}
	if used == 0 {return .Bad_Setup}
	if used > 1 && kraft != u64(1) << 32 {return .Bad_Setup}
	// Codewords: each used entry in order takes the lowest free node at its depth.
	codes, ok2 := arena_make(a, u32, entries)
	if !ok2 {return .Over_Limit}
	if used == 1 {
		codes[last_used] = 0
	} else {
		avail: [33]u32
		first := true
		for l, i in lens {
			if l == 0 {continue}
			if first {
				first = false
				codes[i] = 0
				for y in 1 ..= int(l) {avail[y] = u32(u64(1) << (32 - u64(y)))}
				continue
			}
			z := int(l)
			for z > 0 && avail[z] == 0 {z -= 1}
			if z == 0 {return .Bad_Setup}
			res := avail[z]
			avail[z] = 0
			codes[i] = res
			for y := int(l); y > z; y -= 1 {
				avail[y] = res + u32(u64(1) << (32 - u64(y)))
			}
		}
	}
	// (codes are left-aligned 32-bit words)
	cb.fast_bits = min(FAST_BITS, u32(max_len))
	fast, ok3 := arena_make(a, u32, 1 << cb.fast_bits)
	if !ok3 {return .Over_Limit}
	cb.fast = fast
	nlong := 0
	for l in lens {
		if l > u8(cb.fast_bits) {nlong += 1}
	}
	cb.long_codes, ok = arena_make(a, u32, nlong)
	if !ok {return .Over_Limit}
	cb.long_entry, ok = arena_make(a, u32, nlong)
	if !ok {return .Over_Limit}
	cb.long_len, ok = arena_make(a, u8, nlong)
	if !ok {return .Over_Limit}
	nl := 0
	for l, i in lens {
		if l == 0 {continue}
		code := codes[i]
		if u32(l) <= cb.fast_bits {
			// Index: the code reversed, the first bit lowest; every value of the unused high bits.
			rev := reverse32(code) // the code's bits sit at the top; reversed they sit at the bottom
			for hi in 0 ..< (1 << (cb.fast_bits - u32(l))) {
				fast[int(rev) | (hi << u32(l))] = u32(i) << 8 | u32(l)
			}
		} else {
			// Insertion into the ascending list.
			at := nl
			for at > 0 && cb.long_codes[at - 1] > code {
				cb.long_codes[at] = cb.long_codes[at - 1]
				cb.long_entry[at] = cb.long_entry[at - 1]
				cb.long_len[at] = cb.long_len[at - 1]
				at -= 1
			}
			cb.long_codes[at], cb.long_entry[at], cb.long_len[at] = code, u32(i), l
			nl += 1
		}
	}
	// Vector lookup.
	lookup := int(bits_read(r, 4))
	switch lookup {
	case 0:
	case 1, 2:
		minv := float32_unpack(bits_read(r, 32))
		delta := float32_unpack(bits_read(r, 32))
		vbits := u32(bits_read(r, 4)) + 1
		seq := bits_read(r, 1) != 0
		nvals := entries * dim
		if lookup == 1 {nvals = lookup1_values(entries, dim)}
		if r.eop {return .Bad_Setup}
		need := entries * dim * size_of(f32)
		if lookup_left^ < need {return .Over_Limit}
		lookup_left^ -= need
		mult, ok4 := arena_make(a, u16, nvals)
		if !ok4 {return .Over_Limit}
		for i in 0 ..< nvals {mult[i] = u16(bits_read(r, vbits))}
		if r.eop {return .Bad_Setup}
		cb.vecs, ok4 = arena_make(a, f32, entries * dim)
		if !ok4 {return .Over_Limit}
		for e in 0 ..< entries {
			last: f32
			idx := e
			for d in 0 ..< dim {
				m: u16
				if lookup == 1 {
					m = mult[idx % nvals]
					idx /= nvals
				} else {
					m = mult[e * dim + d]
				}
				v := f32(m) * delta + minv + last
				cb.vecs[e * dim + d] = v
				if seq {last = v}
			}
		}
		cb.has_vq = true
	case:
		return .Bad_Setup
	}
	return .None
}

// codebook_scalar decodes one entry number; -1 at the end of the packet or
// for a code the book does not have.
codebook_scalar :: #force_inline proc "contextless" (cb: ^Codebook, r: ^Bits) -> int {
	if r.n < 32 {bits_refill(r)}
	mask := u64(1) << cb.fast_bits - 1
	e := cb.fast[r.acc & mask]
	if e != 0 {
		l := e & 0xff
		if l > r.n {
			r.eop = true
			return -1
		}
		r.acc >>= l
		r.n -= l
		return int(e >> 8)
	}
	return codebook_long(cb, r)
}

@(private)
codebook_long :: proc "contextless" (cb: ^Codebook, r: ^Bits) -> int {
	if len(cb.long_codes) == 0 {
		// Not a code of this book (a single-entry book, or a bad stream).
		if r.n == 0 {r.eop = true}
		return -1
	}
	v := reverse32(u32(r.acc))
	// The greatest long code <= v.
	lo, hi := 0, len(cb.long_codes)
	for lo < hi {
		mid := (lo + hi) / 2
		if cb.long_codes[mid] <= v {lo = mid + 1} else {hi = mid}
	}
	if lo == 0 {return -1}
	i := lo - 1
	l := u32(cb.long_len[i])
	if (v ~ cb.long_codes[i]) >> (32 - l) != 0 {return -1}
	if l > r.n {
		r.eop = true
		return -1
	}
	r.acc >>= l
	r.n -= l
	return int(cb.long_entry[i])
}
