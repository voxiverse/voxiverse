package game

import "core:math"
import "core:unicode/utf8"

// Byte encoding for messages: little-endian integers, LEB128 varints,
// length-prefixed UTF-8 strings. Writer appends to a buffer; Reader fails
// stickily (every read after a failure returns zero and ok stays false), so
// a decoder reads everything and checks ok once.

Writer :: struct {
	buf: [dynamic]u8,
}

// writer_init: capacity bytes to start with (MAX_MESSAGE_SIZE: it never
// grows, for writers in an arena).
writer_init :: proc(
	w: ^Writer,
	allocator := context.allocator,
	capacity := 256,
	loc := #caller_location,
) {
	w.buf = make([dynamic]u8, 0, capacity, allocator, loc)
}

writer_destroy :: proc(w: ^Writer) {
	delete(w.buf)
}

write_u8 :: proc(w: ^Writer, v: u8) {append(&w.buf, v)}

write_u16 :: proc(w: ^Writer, v: u16) {
	append(&w.buf, u8(v), u8(v >> 8))
}

write_u32 :: proc(w: ^Writer, v: u32) {
	append(&w.buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

write_i32 :: proc(w: ^Writer, v: i32) {write_u32(w, u32(v))}

write_f32 :: proc(w: ^Writer, v: f32) {write_u32(w, transmute(u32)v)}

write_f64 :: proc(w: ^Writer, v: f64) {
	bits := transmute(u64)v
	write_u32(w, u32(bits))
	write_u32(w, u32(bits >> 32))
}

write_varint :: proc(w: ^Writer, v: u32) {
	v := v
	for v >= 0x80 {
		append(&w.buf, u8(v) | 0x80)
		v >>= 7
	}
	append(&w.buf, u8(v))
}

// write_svarint: a signed varint (zigzag: small magnitudes are short).
write_svarint :: proc(w: ^Writer, v: i32) {
	write_varint(w, u32((v << 1) ~ (v >> 31)))
}

write_varint64 :: proc(w: ^Writer, v: u64) {
	v := v
	for v >= 0x80 {
		append(&w.buf, u8(v) | 0x80)
		v >>= 7
	}
	append(&w.buf, u8(v))
}

// write_svarint64: zigzag, as write_svarint.
write_svarint64 :: proc(w: ^Writer, v: i64) {
	write_varint64(w, u64((v << 1) ~ (v >> 63)))
}

write_string :: proc(w: ^Writer, s: string) {
	write_varint(w, u32(len(s)))
	append(&w.buf, s)
}

Reader :: struct {
	data:        []u8,
	pos:         int,
	ok:          bool,
	reg:         ^Registry, // what block and item numbers must be known to (nil: none are)
	block_limit: u32, // else: block numbers below this are valid (a region's own table)
	items:       map[u16]Item, // else: the saved item numbers a region's own table maps (block entities)
}

reader_make :: proc(data: []u8, reg: ^Registry = nil) -> Reader {
	return {data = data, ok = true, reg = reg}
}

// reader_block_valid: id is a block of the reader's registry.
reader_block_valid :: proc(r: ^Reader, id: u16) -> bool {
	if r.block_limit > 0 {return u32(id) < r.block_limit}
	return r.reg != nil && block_valid(&r.reg.blocks, id)
}

// reader_finish is true when everything read was valid and nothing is left.
reader_finish :: proc(r: ^Reader) -> bool {
	return r.ok && r.pos == len(r.data)
}

// reader_fail marks the message invalid (decoders call it for bad values).
reader_fail :: proc(r: ^Reader) {
	r.ok = false
}

@(private = "file")
take :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || len(r.data) - r.pos < n {
		r.ok = false
		return nil
	}
	b := r.data[r.pos:][:n]
	r.pos += n
	return b
}

read_u8 :: proc(r: ^Reader) -> u8 {
	b := take(r, 1)
	return b[0] if b != nil else 0
}

read_u16 :: proc(r: ^Reader) -> u16 {
	b := take(r, 2)
	if b == nil {return 0}
	return u16(b[0]) | u16(b[1]) << 8
}

read_u32 :: proc(r: ^Reader) -> u32 {
	b := take(r, 4)
	if b == nil {return 0}
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

read_i32 :: proc(r: ^Reader) -> i32 {return i32(read_u32(r))}

// read_f32 accepts finite values only.
read_f32 :: proc(r: ^Reader) -> f32 {
	v := transmute(f32)read_u32(r)
	if math.is_nan(v) || math.is_inf(v) {
		r.ok = false
		return 0
	}
	return v
}

// read_f64 accepts finite values only.
read_f64 :: proc(r: ^Reader) -> f64 {
	lo := u64(read_u32(r))
	hi := u64(read_u32(r))
	v := transmute(f64)(lo | hi << 32)
	if math.is_nan(v) || math.is_inf(v) {
		r.ok = false
		return 0
	}
	return v
}

// read_varint rejects values past u32 and overlong encodings (a value must
// have exactly one encoding).
read_varint :: proc(r: ^Reader) -> u32 {
	v: u32
	for i in 0 ..< 5 {
		b := read_u8(r)
		if !r.ok {return 0}
		if i == 4 && b > 0x0f {break} 	// more than 32 bits
		v |= u32(b & 0x7f) << uint(7 * i)
		if b & 0x80 == 0 {
			if b == 0 && i > 0 {break} 	// overlong: a trailing zero group
			return v
		}
	}
	r.ok = false
	return 0
}

// read_varint64: the same one-encoding rule, up to 64 bits.
read_varint64 :: proc(r: ^Reader) -> u64 {
	v: u64
	for i in 0 ..< 10 {
		b := read_u8(r)
		if !r.ok {return 0}
		if i == 9 && b > 0x01 {break} 	// more than 64 bits
		v |= u64(b & 0x7f) << uint(7 * i)
		if b & 0x80 == 0 {
			if b == 0 && i > 0 {break} 	// overlong: a trailing zero group
			return v
		}
	}
	r.ok = false
	return 0
}

read_svarint64 :: proc(r: ^Reader) -> i64 {
	u := read_varint64(r)
	return i64(u >> 1) ~ -i64(u & 1)
}

read_svarint :: proc(r: ^Reader) -> i32 {
	u := read_varint(r)
	return i32(u >> 1) ~ -i32(u & 1)
}

// read_string returns a view into the message (valid while it is), at most
// max_len bytes of valid UTF-8.
read_string :: proc(r: ^Reader, max_len: int) -> string {
	n := read_varint(r)
	if !r.ok {return ""}
	if int(n) > max_len {
		r.ok = false
		return ""
	}
	s := string(take(r, int(n)))
	if !utf8.valid_string(s) {
		r.ok = false
		return ""
	}
	return s
}

// Chunk blocks on the wire: a uniform chunk is its one block; otherwise a
// palette of the distinct blocks, then runs of (length, palette index) in
// local_index order covering exactly CHUNK_VOLUME blocks.

@(private = "file")
Chunk_Encoding :: enum u8 {
	Uniform,
	Palette_Runs,
}

write_chunk_blocks :: proc(w: ^Writer, c: ^Chunk_Blocks) {
	if c.array == nil {
		write_u8(w, u8(Chunk_Encoding.Uniform))
		write_u16(w, u16(c.uniform))
		return
	}
	write_u8(w, u8(Chunk_Encoding.Palette_Runs))
	slot: [MAX_BLOCK_STATES]u16 // palette index + 1, 0 = not in the palette
	palette: [MAX_BLOCK_STATES]Block
	n := 0
	for b in c.array {
		if slot[b] == 0 {
			palette[n] = b
			n += 1
			slot[b] = u16(n)
		}
	}
	write_varint(w, u32(n))
	for b in palette[:n] {write_u16(w, u16(b))}
	i := 0
	for i < CHUNK_VOLUME {
		b := c.array[i]
		run := 1
		for i + run < CHUNK_VOLUME && c.array[i + run] == b {run += 1}
		write_varint(w, u32(run))
		write_varint(w, u32(slot[b] - 1))
		i += run
	}
}

// read_chunk_blocks decodes into dst; is_uniform reports a uniform chunk
// (dst untouched). Anything malformed fails the reader.
read_chunk_blocks :: proc(r: ^Reader, dst: ^Block_Array) -> (uniform: Block, is_uniform: bool) {
	encoding := read_u8(r)
	switch encoding {
	case u8(Chunk_Encoding.Uniform):
		id := read_u16(r)
		if !reader_block_valid(r, id) {
			reader_fail(r)
			return
		}
		return Block(id), r.ok
	case u8(Chunk_Encoding.Palette_Runs):
		n := read_varint(r)
		limit :=
			r.block_limit if r.block_limit > 0 else (u32(r.reg.blocks.count) if r.reg != nil else 0)
		if n == 0 || n > limit {
			reader_fail(r)
			return
		}
		palette: [MAX_BLOCK_STATES]Block
		for &p in palette[:n] {
			id := read_u16(r)
			if !reader_block_valid(r, id) {reader_fail(r)}
			p = Block(id) if r.ok else .Air
		}
		i := 0
		for r.ok && i < CHUNK_VOLUME {
			run := read_varint(r)
			index := read_varint(r)
			if !r.ok || run == 0 || run > u32(CHUNK_VOLUME - i) || index >= n {
				reader_fail(r)
				break
			}
			for &b in dst[i:][:run] {b = palette[index]}
			i += int(run)
		}
		return {}, false
	}
	reader_fail(r)
	return
}
