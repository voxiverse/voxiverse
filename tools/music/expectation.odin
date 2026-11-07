package music_tool

import "core:math"
import "core:slice"

// The expectation: how surprising a melody's intervals are to a listener who
// has heard a corpus. A variable-order (0 to 3) model of the melody's
// intervals with Witten-Bell interpolation, as IDyOM does. The measure is the
// mean information content, in bits a note. All maths is f64 and every
// iteration is over arrays or sorted keys, so the result is the same on
// every OS.

EXPECT_MAX_ORDER :: 3
EXPECT_CLAMP :: 12 // intervals are clamped to +-12 semitones
EXPECT_SYMBOLS :: 2 * EXPECT_CLAMP + 1
EXPECT_VERSION :: 1
EXPECT_MAGIC :: "VXEX"

Expect_Counts :: [EXPECT_SYMBOLS]u32

// ctx maps a context (its order in the high bits, its symbols in base 25 below)
// to the counts of the interval that followed it.
Expectation :: struct {
	names: [dynamic]string, // the pieces trained on, sorted
	ctx:   map[u32]Expect_Counts,
}

// expect_symbols is the melody's intervals, clamped, as symbols 0 to 24.
expect_symbols :: proc(mel: []Mel) -> []u8 {
	if len(mel) < 2 {return nil}
	out := make([]u8, len(mel) - 1)
	for i in 0 ..< len(out) {
		out[i] = u8(clamp(interval(mel, i), -EXPECT_CLAMP, EXPECT_CLAMP) + EXPECT_CLAMP)
	}
	return out
}

// expect_key is the key of the context of the `order` symbols before index i.
expect_key :: proc(syms: []u8, i, order: int) -> u32 {
	code := u32(0)
	for k in i - order ..< i {code = code * EXPECT_SYMBOLS + u32(syms[k])}
	return u32(order) << 16 | code
}

// expect_count adds the piece's counts to m (sign +1) or takes them away (-1).
expect_count :: proc(m: ^Expectation, syms: []u8, sign: int) {
	for i in 0 ..< len(syms) {
		for order in 0 ..= min(EXPECT_MAX_ORDER, i) {
			c := m.ctx[expect_key(syms, i, order)]
			c[syms[i]] = u32(int(c[syms[i]]) + sign)
			m.ctx[expect_key(syms, i, order)] = c
		}
	}
}

// expectation_train counts every piece's melody intervals per context.
expectation_train :: proc(pieces: []Piece) -> Expectation {
	m: Expectation
	for p in pieces {
		p := p
		mp := melody_part(&p)
		if mp < 0 {continue}
		expect_count(&m, expect_symbols(melody_line(&p, mp)), 1)
	}
	return m
}

// expectation_bits is the mean information content of the melody's intervals,
// in bits. With leave_out the piece's own counts are subtracted first, so no
// piece is scored by a model that saw it.
expectation_bits :: proc(m: ^Expectation, mel: []Mel, leave_out: bool) -> f64 {
	syms := expect_symbols(mel)
	if len(syms) == 0 {return 0}
	own: Expectation
	if leave_out {expect_count(&own, syms, 1)}
	total := 0.0
	for i in 0 ..< len(syms) {
		p := 1.0 / f64(EXPECT_SYMBOLS)
		for order in 0 ..= min(EXPECT_MAX_ORDER, i) {
			key := expect_key(syms, i, order)
			c := m.ctx[key]
			if leave_out {
				o := own.ctx[key]
				for s in 0 ..< EXPECT_SYMBOLS {c[s] -= o[s]}
			}
			n, types := 0.0, 0.0
			for s in 0 ..< EXPECT_SYMBOLS {
				if c[s] > 0 {n += f64(c[s]); types += 1}
			}
			if n > 0 {p = (f64(c[syms[i]]) + types * p) / (n + types)}
		}
		total -= math.log2(p)
	}
	return total / f64(len(syms))
}

// expectation_has says whether the model was trained on the piece called name.
expectation_has :: proc(m: ^Expectation, name: string) -> bool {
	for n in m.names {
		if n == name {return true}
	}
	return false
}

// ---- the file ---------------------------------------------------------------
//
// "VXEX", u32 version, u32 name count, per name u16 length and bytes, u32
// context count, then per context (key ascending) u32 key, u8 symbols used and
// per symbol (ascending) u8 symbol, u32 count. Little-endian.

expectation_write :: proc(m: ^Expectation) -> []byte {
	out: [dynamic]byte
	put :: proc(out: ^[dynamic]byte, v: u32, n: int) {
		for i in 0 ..< n {append(out, u8(v >> u32(8 * i)))}
	}
	append(&out, EXPECT_MAGIC)
	put(&out, EXPECT_VERSION, 4)
	names := slice.clone(m.names[:])
	slice.sort(names)
	put(&out, u32(len(names)), 4)
	for n in names {
		put(&out, u32(len(n)), 2)
		append(&out, n)
	}
	keys := make([dynamic]u32)
	for k, c in m.ctx {
		used := false
		for v in c {used ||= v > 0}
		if used {append(&keys, k)}
	}
	slice.sort(keys[:])
	put(&out, u32(len(keys)), 4)
	for k in keys {
		c := m.ctx[k]
		used := 0
		for v in c {
			if v > 0 {used += 1}
		}
		put(&out, k, 4)
		put(&out, u32(used), 1)
		for v, s in c {
			if v > 0 {put(&out, u32(s), 1); put(&out, v, 4)}
		}
	}
	return out[:]
}

expectation_read :: proc(data: []byte) -> (m: Expectation, ok: bool) {
	pos := 0
	get :: proc(data: []byte, pos: ^int, n: int) -> (v: u32, ok: bool) {
		if pos^ + n > len(data) {return 0, false}
		for i in 0 ..< n {v |= u32(data[pos^ + i]) << u32(8 * i)}
		pos^ += n
		return v, true
	}
	if len(data) < 4 || string(data[:4]) != EXPECT_MAGIC {return}
	pos = 4
	version := get(data, &pos, 4) or_return
	if version != EXPECT_VERSION {return}
	count := get(data, &pos, 4) or_return
	for _ in 0 ..< count {
		l := int(get(data, &pos, 2) or_return)
		if pos + l > len(data) {return}
		append(&m.names, string(data[pos:pos + l]))
		pos += l
	}
	n_ctx := get(data, &pos, 4) or_return
	for _ in 0 ..< n_ctx {
		key := get(data, &pos, 4) or_return
		used := get(data, &pos, 1) or_return
		c: Expect_Counts
		for _ in 0 ..< used {
			s := get(data, &pos, 1) or_return
			if s >= EXPECT_SYMBOLS {return}
			c[s] = get(data, &pos, 4) or_return
		}
		m.ctx[key] = c
	}
	return m, pos == len(data)
}
