// Package planet is the home world as a planet: Earth's real relief, read from the
// committed `assets/planet/earth_relief.bin` (imported by `tools/planet`).
package planet

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"

// The relief grid: 2048 x 1024 cells, 360 / 2048 degrees each. Cell centres sit at
// longitude `-180 + (i + 0.5) * 360 / 2048` and latitude `90 - (j + 0.5) * 180 / 1024`.
RELIEF_WIDTH :: 2048
RELIEF_HEIGHT :: 1024

RELIEF_MAGIC :: "VXPL"
RELIEF_VERSION :: 1
RELIEF_HEADER_SIZE :: 16

// Relief is a grid of elevations in metres, row 0 the northernmost.
Relief :: struct {
	width, height: int,
	elevation:     []i16,
}

relief_make :: proc(width, height: int, allocator := context.allocator) -> Relief {
	return Relief{width, height, make([]i16, width * height, allocator)}
}

relief_destroy :: proc(r: ^Relief) {
	delete(r.elevation)
	r^ = {}
}

relief_at :: proc(r: Relief, i, j: int) -> i16 {
	return r.elevation[j * r.width + i]
}

// relief_cell_lat and relief_cell_lon are a cell's centre, in degrees.
relief_cell_lat :: proc(r: Relief, j: int) -> f64 {
	return 90 - (f64(j) + 0.5) * 180 / f64(r.height)
}

relief_cell_lon :: proc(r: Relief, i: int) -> f64 {
	return -180 + (f64(i) + 0.5) * 360 / f64(r.width)
}

// relief_cell_of is the cell holding a place (longitude wraps, latitude clamps).
relief_cell_of :: proc(r: Relief, lat, lon: f64) -> (i, j: int) {
	x := (lon + 180) * f64(r.width) / 360
	x -= f64(r.width) * f64(int(x / f64(r.width)))
	if x < 0 {x += f64(r.width)}
	i = min(int(x), r.width - 1)
	j = int((90 - lat) * f64(r.height) / 180)
	j = clamp(j, 0, r.height - 1)
	return
}

// relief_encode writes the file: magic, version, width, height (each u32 little-endian),
// then the elevations (i16 little-endian, row 0 first) as a zlib stream. The stream
// is made of stored blocks: valid zlib that any inflater reads, with no compressor in the
// tool (the sea's long runs are not worth one).
relief_encode :: proc(r: Relief, allocator := context.allocator) -> []u8 {
	raw := make([]u8, len(r.elevation) * 2, context.temp_allocator)
	for v, k in r.elevation {
		raw[2 * k] = u8(u16(v))
		raw[2 * k + 1] = u8(u16(v) >> 8)
	}
	out: [dynamic]u8
	out.allocator = allocator
	append(&out, RELIEF_MAGIC)
	for v in ([3]u32{RELIEF_VERSION, u32(r.width), u32(r.height)}) {
		append(&out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	append(&out, 0x78, 0x01) // zlib header: deflate, 32 KiB window, no dictionary, fastest
	at := 0
	for {
		n := min(len(raw) - at, 0xFFFF)
		last := at + n == len(raw)
		append(&out, 1 if last else 0, u8(n), u8(n >> 8), u8(~u16(n)), u8(~u16(n) >> 8))
		append(&out, ..raw[at:at + n])
		at += n
		if last {break}
	}
	a, b := u32(1), u32(0)
	for c in raw {
		a = (a + u32(c)) % 65521
		b = (b + a) % 65521
	}
	sum := b << 16 | a
	append(&out, u8(sum >> 24), u8(sum >> 16), u8(sum >> 8), u8(sum))
	return out[:]
}

// relief_decode reads the file; ok is false for anything it does not recognise.
relief_decode :: proc(data: []u8, allocator := context.allocator) -> (r: Relief, ok: bool) {
	if len(data) < RELIEF_HEADER_SIZE || string(data[:4]) != RELIEF_MAGIC {return}
	version, _ := endian.get_u32(data[4:8], .Little)
	w32, _ := endian.get_u32(data[8:12], .Little)
	h32, _ := endian.get_u32(data[12:16], .Little)
	if version != RELIEF_VERSION || w32 == 0 || h32 == 0 || w32 > 8192 || h32 > 8192 {return}
	width, height := int(w32), int(h32)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if zlib.inflate(data[RELIEF_HEADER_SIZE:], &buf, expected_output_size = width * height * 2) !=
	   nil {return}
	raw := bytes.buffer_to_bytes(&buf)
	if len(raw) != width * height * 2 {return}

	r = relief_make(width, height, allocator)
	for k in 0 ..< width * height {
		r.elevation[k] = i16(u16(raw[2 * k]) | u16(raw[2 * k + 1]) << 8)
	}
	return r, true
}

// relief_hash is FNV-1a over the elevations' little-endian bytes.
relief_hash :: proc(r: Relief) -> u64 {
	h := u64(0xcbf29ce484222325)
	for v in r.elevation {
		h = (h ~ u64(u8(u16(v)))) * 0x100000001b3
		h = (h ~ u64(u8(u16(v) >> 8))) * 0x100000001b3
	}
	return h
}
