package script

import "common:base"
import "core:math"

// The math library, on base's deterministic functions and the allowed core:math ones
// (docs/determinism.md rule 2). log(x, 2) and log(x, 10) are ln(x) / ln(base), which may
// differ from Lua's in the last bit. No random: randomness comes from the world API.

MATH_NATIVES := [?]Native_Spec {
	{name = "math.abs", fn = m_abs},
	{name = "math.ceil", fn = m_ceil},
	{name = "math.floor", fn = m_floor},
	{name = "math.fmod", fn = m_fmod},
	{name = "math.modf", fn = m_modf},
	{name = "math.sqrt", fn = m_sqrt},
	{name = "math.exp", fn = m_exp},
	{name = "math.log", fn = m_log},
	{name = "math.sin", fn = m_sin},
	{name = "math.cos", fn = m_cos},
	{name = "math.tan", fn = m_tan},
	{name = "math.asin", fn = m_asin},
	{name = "math.acos", fn = m_acos},
	{name = "math.atan", fn = m_atan},
	{name = "math.max", fn = m_max},
	{name = "math.min", fn = m_min},
	{name = "math.tointeger", fn = m_tointeger},
	{name = "math.type", fn = m_type},
	{name = "math.ult", fn = m_ult},
}

open_math :: proc(vm: ^VM) -> bool {
	t := lib_open(vm, "math", MATH_NATIVES[:]) or_return
	lib_bind(vm, t, "pi", float_value(math.PI)) or_return
	lib_bind(vm, t, "huge", float_value(math.inf_f64(1))) or_return
	lib_bind(vm, t, "maxinteger", int_value(max(i64))) or_return
	lib_bind(vm, t, "mininteger", int_value(min(i64))) or_return
	return true
}

@(private = "file")
num_arg :: proc(c: ^Native_Call, i: int) -> (f: f64, st: Native_Status) {
	v := check_number(c, i) or_return
	return to_float(v), .Ok
}

@(private = "file")
m_abs :: proc(c: ^Native_Call) -> Native_Status {
	v := check_number(c, 1) or_return
	if v.tag == .Int {
		x := as_int(v)
		return push_int(c, x if x >= 0 else -x)
	}
	return push_float(c, abs(as_float(v)))
}

// push_int_or_float: an integral float as an integer when it fits, else the float.
@(private = "file")
push_floored :: proc(c: ^Native_Call, f: f64) -> Native_Status {
	if i, ok := float_to_int_exact(f); ok {return push_int(c, i)}
	return push_float(c, f)
}

@(private = "file")
m_floor :: proc(c: ^Native_Call) -> Native_Status {
	v := check_number(c, 1) or_return
	if v.tag == .Int {return push_value(c, v)}
	return push_floored(c, math.floor(as_float(v)))
}

@(private = "file")
m_ceil :: proc(c: ^Native_Call) -> Native_Status {
	v := check_number(c, 1) or_return
	if v.tag == .Int {return push_value(c, v)}
	return push_floored(c, math.ceil(as_float(v)))
}

@(private = "file")
m_fmod :: proc(c: ^Native_Call) -> Native_Status {
	a := check_number(c, 1) or_return
	b := check_number(c, 2) or_return
	if a.tag == .Int && b.tag == .Int {
		d := as_int(b)
		if d == 0 {return arg_error(c, 2, "zero")}
		if d == -1 {return push_int(c, 0)}
		return push_int(c, as_int(a) % d)
	}
	return push_float(c, math.mod(to_float(a), to_float(b)))
}

@(private = "file")
m_modf :: proc(c: ^Native_Call) -> Native_Status {
	v := check_number(c, 1) or_return
	if v.tag == .Int {
		push_value(c, v) or_return
		return push_float(c, 0)
	}
	x := as_float(v)
	n := math.floor(x) if x >= 0 else math.ceil(x)
	// The integral part is an integer when it fits (as Lua 5.4's pushes it).
	if i, ok := float_to_int_exact(n);
	   ok {push_int(c, i) or_return} else {push_float(c, n) or_return}
	return push_float(c, 0 if n == x else x - n)
}

@(private = "file")
m_sqrt :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	return push_float(c, math.sqrt(x))
}

@(private = "file")
m_exp :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	return push_float(c, base.exp_f64(x))
}

@(private = "file")
m_log :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	if arg(c, 2).tag == .Nil {return push_float(c, math.ln(x))}
	b := num_arg(c, 2) or_return
	return push_float(c, math.ln(x) / math.ln(b))
}

@(private = "file")
m_sin :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	return push_float(c, base.sin_f64(x))
}

@(private = "file")
m_cos :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	return push_float(c, base.cos_f64(x))
}

@(private = "file")
m_tan :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	s, co := base.sincos_f64(x)
	return push_float(c, s / co)
}

@(private = "file")
m_asin :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	return push_float(c, math.asin(x))
}

@(private = "file")
m_acos :: proc(c: ^Native_Call) -> Native_Status {
	x := num_arg(c, 1) or_return
	return push_float(c, math.acos(x))
}

@(private = "file")
m_atan :: proc(c: ^Native_Call) -> Native_Status {
	y := num_arg(c, 1) or_return
	x := 1.0
	if arg(c, 2).tag != .Nil {x = num_arg(c, 2) or_return}
	return push_float(c, math.atan2(y, x))
}

@(private = "file")
m_minmax :: proc(c: ^Native_Call, want_max: bool) -> Native_Status {
	best := check_number(c, 1) or_return
	for i in 2 ..= arg_count(c) {
		v := check_number(c, i) or_return
		if want_max ? num_lt(best, v) : num_lt(v, best) {best = v}
	}
	return push_value(c, best)
}

@(private = "file")
m_max :: proc(c: ^Native_Call) -> Native_Status {return m_minmax(c, true)}
@(private = "file")
m_min :: proc(c: ^Native_Call) -> Native_Status {return m_minmax(c, false)}

@(private = "file")
m_tointeger :: proc(c: ^Native_Call) -> Native_Status {
	v := arg(c, 1)
	if v.tag == .Int {return push_value(c, v)}
	if v.tag == .Float {
		if i, ok := float_to_int_exact(as_float(v)); ok {return push_int(c, i)}
		return push_nil(c)
	}
	check_any(c, 1) or_return
	return push_nil(c)
}

@(private = "file")
m_type :: proc(c: ^Native_Call) -> Native_Status {
	v := check_any(c, 1) or_return
	#partial switch v.tag {
	case .Int:
		return push_string(c, "integer")
	case .Float:
		return push_string(c, "float")
	}
	return push_nil(c)
}

@(private = "file")
m_ult :: proc(c: ^Native_Call) -> Native_Status {
	a := check_int(c, 1) or_return
	b := check_int(c, 2) or_return
	return push_bool(c, u64(a) < u64(b))
}
