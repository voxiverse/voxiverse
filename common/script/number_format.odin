package script

import "core:strconv"
import "core:strconv/decimal"
import "core:strings"

// Numbers to text and back, our own (C's printf and strtod differ between OSes).
// Integers print with %d; floats with %.14g, then ".0" when the result is only digits
// and a sign.

@(private = "file")
float_decimal :: proc(f: f64, d: ^decimal.Decimal) {
	b := transmute(u64)f
	exp := int(b >> 52) & 0x7ff
	mant := b & (1 << 52 - 1)
	if exp == 0 {exp = 1} else {mant |= 1 << 52}
	exp -= 1023
	decimal.assign(d, mant)
	decimal.shift(d, exp - 52)
}

@(private = "file")
digit_at :: #force_inline proc(d: ^decimal.Decimal, i: int) -> u8 {
	return d.digits[i] if i >= 0 && i < d.count else '0'
}

@(private = "file")
write_special :: proc(b: ^strings.Builder, f: f64, upper: bool) -> bool {
	if f != f {
		strings.write_string(b, "NAN" if upper else "nan")
		return true
	}
	if f > 1.7976931348623157e308 || f < -1.7976931348623157e308 {
		if f < 0 {strings.write_byte(b, '-')}
		strings.write_string(b, "INF" if upper else "inf")
		return true
	}
	return false
}

@(private = "file")
write_exponent :: proc(b: ^strings.Builder, x: int, upper: bool) {
	strings.write_byte(b, 'E' if upper else 'e')
	strings.write_byte(b, '-' if x < 0 else '+')
	ax := abs(x)
	if ax < 10 {strings.write_byte(b, '0')}
	strings.write_int(b, ax)
}

// write_float_e: C's %.<prec>e.
write_float_e :: proc(b: ^strings.Builder, f: f64, prec: int, upper := false, alt := false) {
	if write_special(b, f, upper) {return}
	if transmute(u64)f >> 63 != 0 {strings.write_byte(b, '-')}
	d: decimal.Decimal
	x := 0
	if f != 0 {
		float_decimal(abs(f), &d)
		decimal.round(&d, prec + 1)
		x = d.decimal_point - 1
	}
	strings.write_byte(b, digit_at(&d, 0))
	if prec > 0 || alt {strings.write_byte(b, '.')}
	for i in 1 ..= prec {strings.write_byte(b, digit_at(&d, i))}
	write_exponent(b, x, upper)
}

// write_float_f: C's %.<prec>f.
write_float_f :: proc(b: ^strings.Builder, f: f64, prec: int, alt := false) {
	if write_special(b, f, false) {return}
	if transmute(u64)f >> 63 != 0 {strings.write_byte(b, '-')}
	d: decimal.Decimal
	if f != 0 {
		float_decimal(abs(f), &d)
		decimal.round(&d, d.decimal_point + prec)
	}
	if d.decimal_point <= 0 || d.count == 0 {
		strings.write_byte(b, '0')
	} else {
		for i in 0 ..< d.decimal_point {strings.write_byte(b, digit_at(&d, i))}
	}
	if prec > 0 || alt {strings.write_byte(b, '.')}
	for i in 0 ..< prec {strings.write_byte(b, digit_at(&d, d.decimal_point + i))}
}

// write_float_g: C's %.<prec>g: %e or %f by the exponent, trailing zeros removed
// unless alt.
write_float_g :: proc(b: ^strings.Builder, f: f64, prec_in: int, upper := false, alt := false) {
	if write_special(b, f, upper) {return}
	prec := max(prec_in, 1)
	x := 0
	if f != 0 {
		d: decimal.Decimal
		float_decimal(abs(f), &d)
		decimal.round(&d, prec)
		x = d.decimal_point - 1
	}
	start := strings.builder_len(b^)
	if x >= -4 && x < prec {
		write_float_f(b, f, prec - 1 - x, alt)
	} else {
		write_float_e(b, f, prec - 1, upper, alt)
	}
	if alt {return}
	// Strip the fraction's trailing zeros (and the point), before any exponent.
	s := string(b.buf[start:])
	if strings.index_byte(s, '.') < 0 {return}
	e := strings.index_any(s, "eE")
	mantissa := s if e < 0 else s[:e]
	exponent := "" if e < 0 else s[e:]
	end := len(mantissa)
	for end > 0 && mantissa[end - 1] == '0' {end -= 1}
	if end > 0 && mantissa[end - 1] == '.' {end -= 1}
	tail := strings.clone(exponent, context.temp_allocator)
	resize(&b.buf, start + end)
	strings.write_string(b, tail)
}

// write_number: a number as tostring gives it.
write_number :: proc(b: ^strings.Builder, v: Value) {
	if v.tag == .Int {
		strings.write_i64(b, as_int(v))
		return
	}
	f := as_float(v)
	start := strings.builder_len(b^)
	write_float_g(b, f, 14)
	s := string(b.buf[start:])
	for c in transmute([]u8)s {
		if !(c == '-' || (c >= '0' && c <= '9')) {return}
	}
	strings.write_string(b, ".0")
}

@(private = "file")
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

@(private = "file")
hex_value :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'z':
		return int(c - 'a') + 10
	case 'A' ..= 'Z':
		return int(c - 'A') + 10
	}
	return 99
}

// parse_number: Lua's rules for a numeral (surrounding space allowed when trim is set):
// decimal and hex integers (hex wraps, decimal overflow becomes a float), decimal floats.
// No hex floats, no inf or nan, no underscores.
parse_number :: proc(text: string, trim := true) -> (Value, bool) {
	s := text
	if trim {
		for len(s) > 0 && is_space(s[0]) {s = s[1:]}
		for len(s) > 0 && is_space(s[len(s) - 1]) {s = s[:len(s) - 1]}
	}
	neg := false
	body := s
	if len(body) > 0 && (body[0] == '-' || body[0] == '+') {
		neg = body[0] == '-'
		body = body[1:]
	}
	if len(body) == 0 {return NIL, false}
	if len(body) > 2 && body[0] == '0' && (body[1] == 'x' || body[1] == 'X') {
		u: u64
		for c in transmute([]u8)body[2:] {
			h := hex_value(c)
			if h >= 16 {return NIL, false}
			u = u * 16 + u64(h)
		}
		i := cast(i64)u
		return int_value(0 - i if neg else i), true
	}
	all_digits := true
	for c in transmute([]u8)body {if c < '0' || c > '9' {all_digits = false; break}}
	if all_digits {
		u: u64
		overflow := false
		for c in transmute([]u8)body {
			d := u64(c - '0')
			if u > (max(u64) - d) / 10 {overflow = true; break}
			u = u * 10 + d
		}
		limit := u64(1) << 63
		if !overflow && (u < limit || (neg && u == limit)) {
			i := cast(i64)u
			return int_value(0 - i if neg else i), true
		}
	}
	// A decimal float: digits [. digits] [e [+-] digits], at least one digit.
	i := 0
	digits := 0
	for i < len(body) && body[i] >= '0' && body[i] <= '9' {i += 1; digits += 1}
	if i < len(body) && body[i] == '.' {
		i += 1
		for i < len(body) && body[i] >= '0' && body[i] <= '9' {i += 1; digits += 1}
	}
	if digits == 0 {return NIL, false}
	if i < len(body) && (body[i] == 'e' || body[i] == 'E') {
		i += 1
		if i < len(body) && (body[i] == '+' || body[i] == '-') {i += 1}
		exp_digits := 0
		for i < len(body) && body[i] >= '0' && body[i] <= '9' {i += 1; exp_digits += 1}
		if exp_digits == 0 {return NIL, false}
	}
	if i != len(body) {return NIL, false}
	f, _ := strconv.parse_f64(body)
	return float_value(-f if neg else f), true
}

// parse_int_base: tonumber(s, base) for bases 2..36: an integer, wrapping.
parse_int_base :: proc(text: string, base: int) -> (Value, bool) {
	s := text
	for len(s) > 0 && is_space(s[0]) {s = s[1:]}
	for len(s) > 0 && is_space(s[len(s) - 1]) {s = s[:len(s) - 1]}
	neg := false
	if len(s) > 0 && s[0] == '-' {
		neg = true
		s = s[1:]
	}
	if len(s) == 0 {return NIL, false}
	u: u64
	for c in transmute([]u8)s {
		d := hex_value(c)
		if d >= base {return NIL, false}
		u = u * u64(base) + u64(d)
	}
	i := cast(i64)u
	return int_value(0 - i if neg else i), true
}
