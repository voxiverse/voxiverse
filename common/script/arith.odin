package script

import "common:base"
import "core:math"

// Integer and float semantics (Lua 5.4's rules, docs/script.md): integers wrap, `/` and
// `^` are float, `//` and `%` floor, comparisons between integers and floats are exact.

TWO_63 :: 9223372036854775808.0

Arith_Op :: enum u8 {
	Add,
	Sub,
	Mul,
	Mod,
	Pow,
	Div,
	Idiv,
	Band,
	Bor,
	Bxor,
	Shl,
	Shr,
	Unm,
	Bnot,
}

Arith_Status :: enum u8 {
	Ok,
	Not_Number, // an operand is not a number: try the metamethod
	Div_Zero, // integer `//` or `%` by zero
	Mod_Zero,
	No_Int, // a bitwise operand without an integer representation
}

// float_to_int_exact: f as an integer when it has an exact one in range.
float_to_int_exact :: #force_inline proc "contextless" (f: f64) -> (i64, bool) {
	if f >= -TWO_63 && f < TWO_63 {
		i := i64(f)
		if f64(i) == f {return i, true}
	}
	return 0, false
}

// float_floor_int / float_ceil_int: the range is checked before converting.
float_floor_int :: proc "contextless" (f: f64) -> (i64, bool) {
	g := math.floor(f)
	if g >= -TWO_63 && g < TWO_63 {return i64(g), true}
	return 0, false
}

float_ceil_int :: proc "contextless" (f: f64) -> (i64, bool) {
	g := math.ceil(f)
	if g >= -TWO_63 && g < TWO_63 {return i64(g), true}
	return 0, false
}

int_eq_float :: proc "contextless" (i: i64, f: f64) -> bool {
	j, ok := float_to_int_exact(f)
	return ok && i == j
}

@(private = "file")
int_fits_float :: #force_inline proc "contextless" (i: i64) -> bool {
	return i >= -(1 << 53) && i <= 1 << 53
}

lt_int_float :: proc "contextless" (i: i64, f: f64) -> bool {
	if int_fits_float(i) {return f64(i) < f}
	if fi, ok := float_ceil_int(f); ok {return i < fi}
	return f > 0
}

le_int_float :: proc "contextless" (i: i64, f: f64) -> bool {
	if int_fits_float(i) {return f64(i) <= f}
	if fi, ok := float_floor_int(f); ok {return i <= fi}
	return f > 0
}

lt_float_int :: proc "contextless" (f: f64, i: i64) -> bool {
	if int_fits_float(i) {return f < f64(i)}
	if fi, ok := float_floor_int(f); ok {return fi < i}
	return f < 0
}

le_float_int :: proc "contextless" (f: f64, i: i64) -> bool {
	if int_fits_float(i) {return f <= f64(i)}
	if fi, ok := float_ceil_int(f); ok {return fi <= i}
	return f < 0
}

// num_lt / num_le: both values numbers.
num_lt :: proc "contextless" (a, b: Value) -> bool {
	if a.tag == .Int {
		if b.tag == .Int {return as_int(a) < as_int(b)}
		return lt_int_float(as_int(a), as_float(b))
	}
	if b.tag == .Float {return as_float(a) < as_float(b)}
	return lt_float_int(as_float(a), as_int(b))
}

num_le :: proc "contextless" (a, b: Value) -> bool {
	if a.tag == .Int {
		if b.tag == .Int {return as_int(a) <= as_int(b)}
		return le_int_float(as_int(a), as_float(b))
	}
	if b.tag == .Float {return as_float(a) <= as_float(b)}
	return le_float_int(as_float(a), as_int(b))
}

to_float :: #force_inline proc "contextless" (v: Value) -> f64 {
	return as_float(v) if v.tag == .Float else f64(as_int(v))
}

// to_integer_strict: a number with an exact integer value (bitwise operands, keys).
to_integer_strict :: proc "contextless" (v: Value) -> (i64, bool) {
	if v.tag == .Int {return as_int(v), true}
	if v.tag == .Float {return float_to_int_exact(as_float(v))}
	return 0, false
}

int_idiv :: proc "contextless" (a, b: i64) -> i64 {
	if b == -1 {return 0 - a}
	q := a / b
	if a % b != 0 && (a ~ b) < 0 {q -= 1}
	return q
}

int_mod :: proc "contextless" (a, b: i64) -> i64 {
	if b == -1 {return 0}
	r := a % b
	if r != 0 && (r ~ b) < 0 {r += b}
	return r
}

float_mod :: proc "contextless" (a, b: f64) -> f64 {
	m := base.fmod(a, b)
	if m != 0 && (m < 0) != (b < 0) {m += b}
	return m
}

shift_left :: proc "contextless" (x, n: i64) -> i64 {
	if n <= -64 || n >= 64 {return 0}
	if n >= 0 {return cast(i64)(cast(u64)x << u64(n))}
	return cast(i64)(cast(u64)x >> u64(-n))
}

// arith: a op b on numbers (b ignored for the unary ops).
arith :: proc "contextless" (op: Arith_Op, a, b: Value) -> (Value, Arith_Status) {
	switch op {
	case .Band, .Bor, .Bxor, .Shl, .Shr, .Bnot:
		if !is_number(a) || (op != .Bnot && !is_number(b)) {return NIL, .Not_Number}
		x, okx := to_integer_strict(a)
		y: i64
		oky := true
		if op != .Bnot {y, oky = to_integer_strict(b)}
		if !okx || !oky {return NIL, .No_Int}
		#partial switch op {
		case .Band:
			return int_value(x & y), .Ok
		case .Bor:
			return int_value(x | y), .Ok
		case .Bxor:
			return int_value(x ~ y), .Ok
		case .Shl:
			return int_value(shift_left(x, y)), .Ok
		case .Shr:
			return int_value(shift_left(x, 0 - y)), .Ok
		case .Bnot:
			return int_value(~x), .Ok
		}
	case .Unm:
		if a.tag == .Int {return int_value(0 - as_int(a)), .Ok}
		if a.tag == .Float {return float_value(-as_float(a)), .Ok}
		return NIL, .Not_Number
	case .Add, .Sub, .Mul, .Mod, .Idiv:
		if a.tag == .Int && b.tag == .Int {
			x, y := as_int(a), as_int(b)
			#partial switch op {
			case .Add:
				return int_value(x + y), .Ok
			case .Sub:
				return int_value(x - y), .Ok
			case .Mul:
				return int_value(x * y), .Ok
			case .Mod:
				if y == 0 {return NIL, .Mod_Zero}
				return int_value(int_mod(x, y)), .Ok
			case .Idiv:
				if y == 0 {return NIL, .Div_Zero}
				return int_value(int_idiv(x, y)), .Ok
			}
		}
		fallthrough
	case .Pow, .Div:
		if !is_number(a) || !is_number(b) {return NIL, .Not_Number}
		x, y := to_float(a), to_float(b)
		#partial switch op {
		case .Add:
			return float_value(x + y), .Ok
		case .Sub:
			return float_value(x - y), .Ok
		case .Mul:
			return float_value(x * y), .Ok
		case .Div:
			return float_value(x / y), .Ok
		case .Mod:
			if math.is_inf(y) && !math.is_nan(x) && !math.is_inf(x) {
				// Lua: a finite x mod an infinite y is x when they agree in sign, else y.
				if (x >= 0) == (y > 0) {return float_value(x), .Ok}
				return float_value(y), .Ok
			}
			return float_value(float_mod(x, y)), .Ok
		case .Idiv:
			return float_value(math.floor(x / y)), .Ok
		case .Pow:
			if y == 2 {return float_value(x * x), .Ok}
			return float_value(base.pow(x, y)), .Ok
		}
	}
	return NIL, .Not_Number
}
