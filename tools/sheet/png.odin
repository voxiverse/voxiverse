package sheet

import "core:hash"

// png_compressed: a PNG of 8-bit RGBA rows, deflated by runs. A sheet is
// mostly flat colour and texels drawn 4 or 8 pixels wide, so each row is
// filtered "up" when it repeats the row above (all zeros) and "sub"
// otherwise (zeros along a run of one colour), and deflate codes each run of
// equal bytes as a back-reference (fixed Huffman codes). The base pack's
// sheet is 1.3 MB, a thirtieth of base.png_encode's stored size, with no
// compressor library.
png_compressed :: proc(width, height: int, rgba: []u8) -> []u8 {
	assert(len(rgba) == width * height * 4)
	row := width * 4
	raw := make([]u8, height * (row + 1))
	for y in 0 ..< height {
		line := rgba[y * row:][:row]
		out := raw[y * (row + 1):][:row + 1]
		if y > 0 && string(line) == string(rgba[(y - 1) * row:][:row]) {
			out[0] = 2 // up: the row above, so zeros
			continue
		}
		out[0] = 1 // sub: the pixel to the left
		copy(out[1:5], line[:4])
		for i in 4 ..< row {out[1 + i] = line[i] - line[i - 4]}
	}
	zlib := make([dynamic]u8)
	append(&zlib, 0x78, 0x01)
	deflate_runs(&zlib, raw)
	adler: [4]u8
	put_be32(adler[:], hash.adler32(raw))
	append(&zlib, ..adler[:])

	png := make([dynamic]u8)
	append(&png, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n')
	ihdr: [13]u8
	put_be32(ihdr[0:], u32(width))
	put_be32(ihdr[4:], u32(height))
	ihdr[8], ihdr[9] = 8, 6 // 8 bits per channel, RGBA
	write_chunk(&png, "IHDR", ihdr[:])
	write_chunk(&png, "IDAT", zlib[:])
	write_chunk(&png, "IEND", nil)
	return png[:]
}

// Bits: a deflate bit stream, least significant bit first.
@(private = "file")
Bits :: struct {
	out:   ^[dynamic]u8,
	acc:   u32,
	count: uint,
}

@(private = "file")
put_bits :: proc(b: ^Bits, value: u32, n: uint) {
	b.acc |= value << b.count
	b.count += n
	for b.count >= 8 {
		append(b.out, u8(b.acc))
		b.acc >>= 8
		b.count -= 8
	}
}

// put_huffman writes a Huffman code, which deflate stores most significant bit first.
@(private = "file")
put_huffman :: proc(b: ^Bits, code: u32, n: uint) {
	reversed: u32
	for i in 0 ..< n {reversed |= ((code >> i) & 1) << (n - 1 - i)}
	put_bits(b, reversed, n)
}

// put_literal_length writes a literal byte or a length code (257..285) with the fixed codes.
@(private = "file")
put_literal_length :: proc(b: ^Bits, symbol: int) {
	switch {
	case symbol < 144:
		put_huffman(b, u32(0x30 + symbol), 8)
	case symbol < 256:
		put_huffman(b, u32(0x190 + symbol - 144), 9)
	case symbol < 280:
		put_huffman(b, u32(symbol - 256), 7)
	case:
		put_huffman(b, u32(0xc0 + symbol - 280), 8)
	}
}

// Lengths 3..258: each code's first length and its extra bits.
@(private = "file", rodata)
LENGTH_BASE := [29]int {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
@(private = "file", rodata)
LENGTH_EXTRA := [29]uint {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0,
}

// deflate_runs: one fixed-Huffman block of data, each run of a repeated
// byte past the first as a match at distance 1.
@(private = "file")
deflate_runs :: proc(out: ^[dynamic]u8, data: []u8) {
	b := Bits {
		out = out,
	}
	put_bits(&b, 1, 1) // the last block
	put_bits(&b, 1, 2) // fixed codes
	i := 0
	for i < len(data) {
		put_literal_length(&b, int(data[i]))
		run := 0
		for i + 1 + run < len(data) && run < 258 && data[i + 1 + run] == data[i] {run += 1}
		i += 1
		if run < 3 {continue}
		code := 28
		for LENGTH_BASE[code] > run {code -= 1}
		put_literal_length(&b, 257 + code)
		put_bits(&b, u32(run - LENGTH_BASE[code]), LENGTH_EXTRA[code])
		put_huffman(&b, 0, 5) // distance 1
		i += run
	}
	put_literal_length(&b, 256) // the end of the block
	if b.count > 0 {append(out, u8(b.acc))}
}

@(private = "file")
write_chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
	length: [4]u8
	put_be32(length[:], u32(len(data)))
	append(out, ..length[:])
	start := len(out)
	append(out, kind)
	append(out, ..data)
	crc: [4]u8
	put_be32(crc[:], hash.crc32(out[start:]))
	append(out, ..crc[:])
}

@(private = "file")
put_be32 :: proc(b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}
