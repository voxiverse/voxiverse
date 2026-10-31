package ogg

import "base:runtime"

import "common:base"

import "common:base/fuzz"

// The fuzz target and the Ogg-specific mutations (`mutate`, used by `test_ogg_fuzz`). The suite
// (`test_ogg_fuzz`, `test_fuzz_pack_ogg_smoke`) and `build fuzz` run the same
// code; M51c's fuzzers call `fuzz_one`.

FUZZ_MAX_FRAMES :: 10_000_000

// fuzz_one: open, read to the end (metered), seek to three places derived
// from the data's hash, scan. The only contract is no crash, no out-of-bounds
// access and no allocation beyond open's one block; an Error or a clean end
// are both fine.
fuzz_one :: proc(data: []byte, allocator := context.allocator, max_frames := FUZZ_MAX_FRAMES) {
	_, _, _ = scan(data)
	d, err := open(data, allocator)
	if err != .None {return}
	defer close(d)
	block: [2048]f32
	total := 0
	for {
		n, e := read(d, block[:])
		if e != .None || n == 0 {break}
		total += n
		if total > max_frames {break}
	}
	h := digest_bytes(data)
	for _ in 0 ..< 3 {
		frame := h % (d.total + 1)
		h = h * 6364136223846793005 + 1442695040888963407
		if seek(d, frame) != .None {continue}
		for _ in 0 ..< 4 {
			n, e := read(d, block[:])
			if e != .None || n == 0 {break}
		}
	}
}

digest_bytes :: proc(data: []byte) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in data {h = (h ~ u64(b)) * 0x100000001b3}
	return h
}

// digest_samples: FNV-1a over the little-endian bytes of the samples, the
// golden digests' hash.
digest_samples :: proc(pcm: []f32) -> u64 {
	h := u64(0xcbf29ce484222325)
	for v in pcm {
		x := transmute(u32)v
		for i in 0 ..< u32(4) {h = (h ~ u64(u8(x >> (8 * i)))) * 0x100000001b3}
	}
	return h
}

// repair_crc rewrites the CRC of every page of data that is whole, so a
// mutated page reaches the decoder instead of being refused at once.
repair_crc :: proc(data: []byte) {
	off := 0
	for {
		p, e := page_parse(data, off, false)
		if e != .None {return}
		c := page_crc(data[off:off + p.len])
		data[off + 22] = u8(c)
		data[off + 23] = u8(c >> 8)
		data[off + 24] = u8(c >> 16)
		data[off + 25] = u8(c >> 24)
		off += p.len
	}
}

// page_offsets lists where "OggS" occurs (page starts of a well-formed file).
page_offsets :: proc(data: []byte, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for i in 0 ..< max(len(data) - 4, 0) {
		if string(data[i:i + 4]) == "OggS" {append(&out, i)}
	}
	return out[:]
}

// mutate makes a changed copy of data, from the seeded generator; `other` is
// a second file to splice with. The changes are those a damaged or hostile
// file shows: flipped bits, replaced, cut, doubled and removed chunks,
// extreme header fields, shuffled setup bytes, two files joined at a page.
mutate :: proc(r: ^base.Rng, data, other: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, len(data) + 64, allocator)
	append(&out, ..data)
	if len(out) == 0 {return out[:]}
	pick :: proc(r: ^base.Rng, n: int) -> int {
		return int(base.rng_u64(r) % u64(max(n, 1)))
	}
	switch pick(r, 9) {
	case 0:
		for _ in 0 ..< 1 + pick(r, 4) {out[pick(r, len(out))] ~= u8(1 << uint(pick(r, 8)))}
	case 1:
		for _ in 0 ..< 1 + pick(r, 8) {out[pick(r, len(out))] = u8(base.rng_u64(r))}
	case 2:
		resize(&out, pick(r, len(out)))
	case 3:
		at, n := pick(r, len(out)), 1 + pick(r, 64)
		n = min(n, len(out) - at)
		chunk := make([]byte, n, context.temp_allocator)
		copy(chunk, out[at:at + n])
		inject_at_elems(&out, at, ..chunk)
	case 4:
		at, n := pick(r, len(out)), 1 + pick(r, 64)
		n = min(n, len(out) - at)
		remove_range(&out, at, at + n)
	case 5:
		// A page header field at an extreme.
		offs := page_offsets(out[:])
		if len(offs) == 0 {break}
		o := offs[pick(r, len(offs))]
		extremes := [?]u8{0, 1, 0x7f, 0x80, 0xff}
		field := pick(r, 5)
		v := extremes[pick(r, len(extremes))]
		switch field {
		case 0:
			if o + 26 < len(out) {out[o + 26] = v} 	// segment count
		case 1:
			for i in 6 ..< 14 {if o + i < len(out) {out[o + i] = v}} 	// granule
		case 2:
			if o + 5 < len(out) {out[o + 5] = v} 	// flags
		case 3:
			for i in 14 ..< 18 {if o + i < len(out) {out[o + i] = v}} 	// serial
		case 4:
			for i in 18 ..< 22 {if o + i < len(out) {out[o + i] = v}} 	// sequence
		}
	case 6:
		// An extreme value in the headers: a blocksize, a count, a length.
		limit := min(len(out), 1 << 12)
		for _ in 0 ..< 1 + pick(r, 3) {
			ext := [?]u8{0, 1, 0x7f, 0x80, 0xff}
			out[pick(r, limit)] = ext[pick(r, 5)]
		}
	case 7:
		// The setup header's bytes shuffled.
		lo := min(len(out) - 1, 60 + pick(r, 200))
		for _ in 0 ..< 1 + pick(r, 12) {
			a, b := min(len(out) - 1, lo + pick(r, 64)), min(len(out) - 1, lo + pick(r, 64))
			out[a], out[b] = out[b], out[a]
		}
	case 8:
		// Two files joined at a page boundary.
		a := page_offsets(out[:])
		b := page_offsets(other)
		if len(a) == 0 || len(b) == 0 {break}
		cut := a[pick(r, len(a))]
		from := b[pick(r, len(b))]
		resize(&out, cut)
		append(&out, ..other[from:])
	}
	return out[:]
}

// fuzz_targets: the Ogg decoder as a harness target (base/fuzz): the edge-case files are its
// seeds, repair_crc keeps a mutated page from being refused at once.
ogg_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "pack.ogg",
			run = fuzz_pack_ogg,
			seeds = "common/ogg/testdata/edge",
			dictionary = {"OggS", "vorbis", "\x01vorbis", "\x03vorbis", "\x05vorbis"},
			max_len = 64 << 10,
			fixup = fuzz_fixup_ogg,
			alloc_cap = 64 << 20,
		},
	}
	return targets[:]
}

fuzz_pack_ogg :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	info, _, serr := scan(data)
	fuzz_one(data, allocator, 200_000)
	return fuzz.sig_mix(u64(serr), u64(info.channels), fuzz.sig_bucket(int(info.frames)))
}

fuzz_fixup_ogg :: proc(data: ^[dynamic]u8) {
	repair_crc(data[:])
}

// to_s16 rounds a sample to 16 bits: nearest, ties to even, clipped.
to_s16 :: proc "contextless" (x: f32) -> i16 {
	v := x * 32768
	if v >= 32767 {return 32767}
	if v <= -32768 {return -32768}
	i := int(v) // toward zero
	frac := v - f32(i)
	switch {
	case frac > 0.5 || (frac == 0.5 && i & 1 != 0):
		i += 1
	case frac < -0.5 || (frac == -0.5 && i & 1 != 0):
		i -= 1
	}
	return i16(i)
}
