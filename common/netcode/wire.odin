package netcode

// Little-endian packet writing and reading for the netcode's own headers
// (the game's messages are opaque bytes here). A Reader fails once and
// stays failed; callers check ok at the end.

@(private)
Writer :: struct {
	buf: []u8,
	n:   int,
	ok:  bool,
}

@(private)
writer :: proc(buf: []u8) -> Writer {
	return {buf = buf, ok = true}
}

@(private)
put_u8 :: proc(w: ^Writer, v: u8) {
	if w.n + 1 > len(w.buf) {
		w.ok = false
		return
	}
	w.buf[w.n] = v
	w.n += 1
}

@(private)
put_u16 :: proc(w: ^Writer, v: u16) {
	put_u8(w, u8(v))
	put_u8(w, u8(v >> 8))
}

@(private)
put_u32 :: proc(w: ^Writer, v: u32) {
	put_u16(w, u16(v))
	put_u16(w, u16(v >> 16))
}

@(private)
put_u64 :: proc(w: ^Writer, v: u64) {
	put_u32(w, u32(v))
	put_u32(w, u32(v >> 32))
}

@(private)
put_bytes :: proc(w: ^Writer, b: []u8) {
	if w.n + len(b) > len(w.buf) {
		w.ok = false
		return
	}
	copy(w.buf[w.n:], b)
	w.n += len(b)
}

// put_blob: a u16 length, then the bytes.
@(private)
put_blob :: proc(w: ^Writer, b: []u8) {
	if len(b) > int(max(u16)) {
		w.ok = false
		return
	}
	put_u16(w, u16(len(b)))
	put_bytes(w, b)
}

@(private)
Reader :: struct {
	buf: []u8,
	n:   int,
	ok:  bool,
}

@(private)
reader :: proc(buf: []u8) -> Reader {
	return {buf = buf, ok = true}
}

@(private)
get_u8 :: proc(r: ^Reader) -> u8 {
	if !r.ok || r.n + 1 > len(r.buf) {
		r.ok = false
		return 0
	}
	r.n += 1
	return r.buf[r.n - 1]
}

@(private)
get_u16 :: proc(r: ^Reader) -> u16 {
	lo := u16(get_u8(r))
	return lo | u16(get_u8(r)) << 8
}

@(private)
get_u32 :: proc(r: ^Reader) -> u32 {
	lo := u32(get_u16(r))
	return lo | u32(get_u16(r)) << 16
}

@(private)
get_u64 :: proc(r: ^Reader) -> u64 {
	lo := u64(get_u32(r))
	return lo | u64(get_u32(r)) << 32
}

// get_bytes: a view of the next n bytes.
@(private)
get_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	if !r.ok || n < 0 || r.n + n > len(r.buf) {
		r.ok = false
		return nil
	}
	r.n += n
	return r.buf[r.n - n:r.n]
}

@(private)
get_blob :: proc(r: ^Reader, max_len: int) -> []u8 {
	n := int(get_u16(r))
	if n > max_len {
		r.ok = false
		return nil
	}
	return get_bytes(r, n)
}

// Sequence numbers wrap: a is newer than b if it is less than half the
// range ahead.
@(private)
seq_newer :: proc(a, b: u16) -> bool {
	return a != b && i16(a - b) > 0
}
