package fuzz

import "common:base"

// Mutations (from base.Rng, never core:math/rand): a bit, a byte, an interesting integer, a
// run inserted, deleted or copied, a splice with another corpus input, a dictionary token.

MUTATION_KINDS :: 9

@(private = "file")
INTERESTING_BYTES := [?]u8{0, 1, 0x7f, 0x80, 0xff}

// interesting_u64: the integers a length, a count or an index goes wrong at.
interesting_u64 :: proc(r: ^base.Rng) -> u64 {
	vals := [?]u64 {
		0,
		1,
		0xffff_ffff_ffff_ffff,
		0x7fff_ffff,
		0x8000_0000,
		0xffff_ffff,
		0x1_0000_0000,
		0x7fff_ffff_ffff_ffff,
		0x8000_0000_0000_0000,
		0xff,
		0x100,
		0xffff,
		0x1_0000,
		4096,
		4097,
	}
	return vals[base.rng_int_max(r, len(vals))]
}

// mutate changes buf in place with one mutation.
mutate :: proc(r: ^base.Rng, buf: ^[dynamic]u8, other: []u8, dictionary: []string) {
	pick :: proc(r: ^base.Rng, n: int) -> int {return base.rng_int_max(r, max(n, 1))}
	kind := pick(r, MUTATION_KINDS)
	if len(buf) == 0 {
		// Nothing to change in place: grow it.
		append(buf, INTERESTING_BYTES[pick(r, len(INTERESTING_BYTES))])
		return
	}
	switch kind {
	case 0:
		buf[pick(r, len(buf))] ~= u8(1 << uint(pick(r, 8)))
	case 1:
		buf[pick(r, len(buf))] = INTERESTING_BYTES[pick(r, len(INTERESTING_BYTES))]
	case 2:
		// 2, 4 or 8 bytes set to an interesting integer, either endian.
		width := 2 << uint(pick(r, 3))
		if len(buf) < width {break}
		at := pick(r, len(buf) - width + 1)
		v := interesting_u64(r)
		big := pick(r, 2) == 1
		for i in 0 ..< width {
			shift := uint(8 * (width - 1 - i)) if big else uint(8 * i)
			buf[at + i] = u8(v >> shift)
		}
	case 3:
		// Insert a run of bytes.
		at, n := pick(r, len(buf) + 1), 1 + pick(r, 32)
		run := make([]u8, n, context.temp_allocator)
		fill := pick(r, 3)
		for &b in run {
			b =
				u8(base.rng_u64(r)) if fill == 0 else INTERESTING_BYTES[pick(r, len(INTERESTING_BYTES))]
		}
		inject_at_elems(buf, at, ..run)
	case 4:
		// Delete a run.
		at := pick(r, len(buf))
		n := min(1 + pick(r, 32), len(buf) - at)
		remove_range(buf, at, at + n)
	case 5:
		// Copy a run within the input to another place.
		from, to := pick(r, len(buf)), pick(r, len(buf) + 1)
		n := min(1 + pick(r, 64), len(buf) - from)
		run := make([]u8, n, context.temp_allocator)
		copy(run, buf[from:from + n])
		inject_at_elems(buf, to, ..run)
	case 6:
		// Splice with another corpus input.
		if len(other) == 0 {break}
		cut := pick(r, len(buf) + 1)
		from := pick(r, len(other))
		resize(buf, cut)
		append(buf, ..other[from:])
	case 7:
		if len(dictionary) == 0 {break}
		tok := dictionary[pick(r, len(dictionary))]
		at := pick(r, len(buf) + 1)
		if pick(r, 2) == 0 && at + len(tok) <= len(buf) {
			copy(buf[at:], tok)
		} else {
			inject_at_elems(buf, at, ..transmute([]u8)tok)
		}
	case 8:
		// Truncate.
		resize(buf, pick(r, len(buf)))
	}
}
