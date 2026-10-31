package base

import "core:hash"
import "core:mem"

// png_encode makes a PNG from 8-bit RGBA pixels (rows top to bottom). The
// image data is stored uncompressed (zlib "stored" blocks): files are large,
// but this needs no compressor and is exact. For screenshots and test
// images, not for shipping assets.
png_encode :: proc(
	width, height: int,
	rgba: []u8,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	png: []u8,
	err: mem.Allocator_Error,
) {
	assert(width > 0 && height > 0 && len(rgba) == width * height * 4)
	// Raw scanlines: a filter byte (0: none) before each row.
	row := width * 4
	raw_size := height * (row + 1)
	MAX_BLOCK :: 65535
	blocks := (raw_size + MAX_BLOCK - 1) / MAX_BLOCK
	zlib_size := 2 + raw_size + 5 * blocks + 4
	out := make([dynamic]u8, 0, 8 + 25 + 12 + zlib_size + 12, allocator, loc) or_return

	append(&out, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n')
	ihdr: [13]u8
	put_be32(ihdr[0:], u32(width))
	put_be32(ihdr[4:], u32(height))
	ihdr[8], ihdr[9] = 8, 6 // 8 bits per channel, RGBA
	write_chunk(&out, "IHDR", ihdr[:])

	// IDAT: zlib header, stored blocks over the scanlines, Adler-32.
	zlib := make([dynamic]u8, 0, zlib_size, allocator, loc) or_return
	defer delete(zlib)
	raw := make([]u8, raw_size, allocator, loc) or_return
	defer delete(raw, allocator)
	for y in 0 ..< height {
		raw[y * (row + 1)] = 0
		copy(raw[y * (row + 1) + 1:][:row], rgba[y * row:][:row])
	}
	append(&zlib, 0x78, 0x01)
	for start := 0; start < raw_size; start += MAX_BLOCK {
		n := min(MAX_BLOCK, raw_size - start)
		last: u8 = 1 if start + n == raw_size else 0
		append(&zlib, last, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8))
		append(&zlib, ..raw[start:][:n])
	}
	adler: [4]u8
	put_be32(adler[:], hash.adler32(raw))
	append(&zlib, ..adler[:])
	write_chunk(&out, "IDAT", zlib[:])
	write_chunk(&out, "IEND", nil)
	return out[:], nil
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
