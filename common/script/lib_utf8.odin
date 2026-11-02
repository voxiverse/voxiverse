package script

import "core:strings"

// The utf8 library (Lua 5.4's, strict: no surrogates, at most U+10FFFF).

UTF8_NATIVES := [?]Native_Spec {
	{name = "utf8.char", fn = u_char},
	{name = "utf8.codepoint", fn = u_codepoint},
	{name = "utf8.codes", fn = u_codes},
	{name = "utf8.codes/step", fn = u_codes_step},
	{name = "utf8.len", fn = u_len},
	{name = "utf8.offset", fn = u_offset},
}

UTF8_PATTERN :: "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*"

open_utf8 :: proc(vm: ^VM) -> bool {
	t := lib_open(vm, "utf8", UTF8_NATIVES[:]) or_return
	return lib_bind(vm, t, "charpattern", new_string(vm, UTF8_PATTERN))
}

MAX_UNICODE :: 0x10FFFF

// utf8_decode: the code point at s[i:] and its length; ok false when it is not valid
// (strict: overlong forms, surrogates and values past U+10FFFF are refused).
utf8_decode :: proc(s: string, i: int) -> (cp: u32, n: int, ok: bool) {
	c := s[i]
	if c < 0x80 {return u32(c), 1, true}
	count: int
	switch {
	case c >= 0xF0 && c < 0xF8:
		count = 3
		cp = u32(c & 0x07)
	case c >= 0xE0:
		count = 2
		cp = u32(c & 0x0F)
	case c >= 0xC0:
		count = 1
		cp = u32(c & 0x1F)
	case:
		return 0, 0, false
	}
	if c >= 0xF8 {return 0, 0, false}
	for k in 1 ..= count {
		if i + k >= len(s) {return 0, 0, false}
		cc := s[i + k]
		if cc & 0xC0 != 0x80 {return 0, 0, false}
		cp = cp << 6 | u32(cc & 0x3F)
	}
	limits := [4]u32{0, 0x80, 0x800, 0x10000}
	if cp < limits[count] || cp > MAX_UNICODE || (cp >= 0xD800 && cp <= 0xDFFF) {
		return 0, 0, false
	}
	return cp, count + 1, true
}

utf8_encode :: proc(b: ^strings.Builder, cp: u32) {
	switch {
	case cp < 0x80:
		strings.write_byte(b, u8(cp))
	case cp < 0x800:
		strings.write_byte(b, u8(0xC0 | cp >> 6))
		strings.write_byte(b, u8(0x80 | cp & 0x3F))
	case cp < 0x10000:
		strings.write_byte(b, u8(0xE0 | cp >> 12))
		strings.write_byte(b, u8(0x80 | (cp >> 6) & 0x3F))
		strings.write_byte(b, u8(0x80 | cp & 0x3F))
	case:
		strings.write_byte(b, u8(0xF0 | cp >> 18))
		strings.write_byte(b, u8(0x80 | (cp >> 12) & 0x3F))
		strings.write_byte(b, u8(0x80 | (cp >> 6) & 0x3F))
		strings.write_byte(b, u8(0x80 | cp & 0x3F))
	}
}

@(private = "file")
u_char :: proc(c: ^Native_Call) -> Native_Status {
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= arg_count(c) {
		v := check_int(c, i) or_return
		if v < 0 || v > MAX_UNICODE {return arg_error(c, i, "value out of range")}
		utf8_encode(&b, u32(v))
	}
	return push_string(c, strings.to_string(b))
}

@(private = "file")
u_codepoint :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	i := pos_start(opt_int(c, 2, 1) or_return, len(s))
	j := pos_end(opt_int(c, 3, i) or_return, len(s))
	if i < 1 {return arg_error(c, 2, "out of bounds")}
	if j > i64(len(s)) {return arg_error(c, 3, "out of bounds")}
	if i > j {return .Ok}
	p := int(i - 1)
	for p < int(j) {
		cp, n, ok := utf8_decode(s, p)
		if !ok {return raise(c, "invalid UTF-8 code")}
		push_int(c, i64(cp)) or_return
		p += n
	}
	return .Ok
}

@(private = "file")
u_len :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	i := pos_start(opt_int(c, 2, 1) or_return, len(s))
	j := opt_int(c, 3, -1) or_return
	if j < 0 {j = max(i64(len(s)) + j + 1, 0)}
	if !(1 <= i && i <= i64(len(s)) + 1) {return arg_error(c, 2, "initial position out of bounds")}
	if j > i64(len(s)) {return arg_error(c, 3, "final position out of bounds")}
	p := int(i - 1)
	n: i64
	for p < int(j) {
		_, k, ok := utf8_decode(s, p)
		if !ok {
			push_nil(c) or_return
			return push_int(c, i64(p) + 1)
		}
		p += k
		n += 1
	}
	charge(c, i64(len(s)) / 64)
	return push_int(c, n)
}

@(private = "file")
is_cont :: #force_inline proc(s: string, p: int) -> bool {
	return p < len(s) && s[p] & 0xC0 == 0x80
}

@(private = "file")
u_offset :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	n := check_int(c, 2) or_return
	def: i64 = 1 if n >= 0 else i64(len(s)) + 1
	i := opt_int(c, 3, def) or_return
	if i < 0 {i = max(i64(len(s)) + i + 1, 0)}
	if !(1 <= i && i <= i64(len(s)) + 1) {return arg_error(c, 3, "position out of bounds")}
	posi := int(i - 1)
	if n == 0 {
		for posi > 0 && is_cont(s, posi) {posi -= 1}
		return push_int(c, i64(posi) + 1)
	}
	if is_cont(s, posi) {return raise(c, "initial position is a continuation byte")}
	if n < 0 {
		for n < 0 && posi > 0 {
			posi -= 1
			for posi > 0 && is_cont(s, posi) {posi -= 1}
			n += 1
		}
	} else {
		n -= 1
		for n > 0 && posi < len(s) {
			posi += 1
			for is_cont(s, posi) {posi += 1}
			n -= 1
		}
	}
	if n == 0 {return push_int(c, i64(posi) + 1)}
	return push_nil(c)
}

@(private = "file")
u_codes :: proc(c: ^Native_Call) -> Native_Status {
	check_string(c, 1) or_return
	push_value(c, native_value(c.vm, "utf8.codes/step")) or_return
	push_value(c, arg(c, 1)) or_return
	return push_int(c, 0)
}

@(private = "file")
u_codes_step :: proc(c: ^Native_Call) -> Native_Status {
	s := check_string(c, 1) or_return
	i := int(check_int(c, 2) or_return)
	// Skip the current code point's continuation bytes.
	if i > 0 {
		for is_cont(s, i) {i += 1}
	}
	if i >= len(s) {return .Ok}
	cp, n, ok := utf8_decode(s, i)
	if !ok || is_cont(s, i + n) {return raise(c, "invalid UTF-8 code")}
	push_int(c, i64(i) + 1) or_return
	return push_int(c, i64(cp))
}
