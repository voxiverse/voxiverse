package ogg

import "base:runtime"

import "common:base/fuzz"

// The fuzz target. The suite (`test_fuzz_pack_ogg_smoke`) and `build fuzz` run the same
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
