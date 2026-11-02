package script

import "core:fmt"
import "core:strings"

// The base library. What must call script code (tostring, print) is in the prelude;
// pcall and xpcall are intrinsics the dispatch loop runs.

BASE_NATIVES := [?]Native_Spec {
	{name = "assert", fn = base_assert},
	{name = "error", fn = base_error},
	{name = "getmetatable", fn = base_getmetatable},
	{name = "ipairs", fn = base_ipairs},
	{name = "ipairs_step", fn = base_ipairs_step},
	{name = "next", fn = base_next},
	{name = "pairs", fn = base_pairs},
	{name = "pcall", fn = base_intrinsic},
	{name = "xpcall", fn = base_intrinsic},
	{name = "rawequal", fn = base_rawequal},
	{name = "rawget", fn = base_rawget},
	{name = "rawlen", fn = base_rawlen},
	{name = "rawset", fn = base_rawset},
	{name = "select", fn = base_select},
	{name = "setmetatable", fn = base_setmetatable},
	{name = "tonumber", fn = base_tonumber},
	{name = "type", fn = base_type},
	{name = "collectgarbage", fn = base_collectgarbage},
	{name = "debug.traceback", fn = base_traceback},
	// The prelude's private natives.
	{name = "rawtostring", fn = base_rawtostring},
	{name = "write", fn = base_write},
	{name = "metafield", fn = base_metafield},
}

@(private = "file")
PUBLIC := [?]string {
	"assert",
	"error",
	"getmetatable",
	"ipairs",
	"next",
	"pairs",
	"rawequal",
	"rawget",
	"rawlen",
	"rawset",
	"select",
	"setmetatable",
	"tonumber",
	"type",
	"collectgarbage",
}

@(private = "file")
PRIVATE := [?]string{"rawtostring", "write", "metafield"}

// open_base binds the base library into the globals and the prelude's private table.
open_base :: proc(vm: ^VM) -> bool {
	g := ref_value(.Table, vm.globals)
	for name in PUBLIC {
		f := native_value(vm, name)
		if f.tag == .Nil || !table_set_raw(vm, g, new_string(vm, name), f) {return false}
	}
	for name, intr in ([2]string{"pcall", "xpcall"}) {
		f := native_closure(vm, find_native(vm, name), .Pcall if intr == 0 else .Xpcall)
		if f.tag == .Nil || !table_set_raw(vm, g, new_string(vm, name), f) {return false}
	}
	debug := new_table(vm)
	if debug.tag == .Nil || !table_set_raw(vm, g, new_string(vm, "debug"), debug) {return false}
	tb := native_value(vm, "debug.traceback")
	if tb.tag == .Nil || !table_set_raw(vm, debug, new_string(vm, "traceback"), tb) {return false}
	pt := ref_value(.Table, vm.prelude_table)
	for name in PRIVATE {
		f := native_value(vm, name)
		if f.tag == .Nil || !table_set_raw(vm, pt, new_string(vm, name), f) {return false}
	}
	return true
}

@(private = "file")
base_intrinsic :: proc(c: ^Native_Call) -> Native_Status {
	return raise(c, "'%s' cannot be called from here", c.name)
}

@(private = "file")
base_assert :: proc(c: ^Native_Call) -> Native_Status {
	v := check_any(c, 1) or_return
	if !is_falsy(v) {
		// Return all the arguments.
		for i in 1 ..= arg_count(c) {push_value(c, arg(c, i)) or_return}
		return .Ok
	}
	if arg_count(c) >= 2 {
		return raise_value(c, arg(c, 2), 0)
	}
	return raise(c, "assertion failed!")
}

// raise_value: error(v, level). A string gets the position of its level prepended.
@(private = "file")
raise_value :: proc(c: ^Native_Call, v: Value, level: int) -> Native_Status {
	vm := c.vm
	strings.builder_reset(&vm.err.msg)
	strings.builder_reset(&vm.err.hint)
	value := v
	if v.tag == .String {
		s := value_string(vm, v)
		strings.write_string(&vm.err.msg, s)
		if level > 0 {
			prefix := position_prefix(vm, c.th, level)
			if prefix != "" {
				value = new_string(vm, strings.concatenate({prefix, s}, context.temp_allocator))
				if value.tag == .Nil {return .Error}
			}
		}
	} else {
		fmt.sbprintf(&vm.err.msg, "(error object is a %s value)", type_name(v))
	}
	vm.err.value = value
	vm.err.has_value = true
	vm.err.level = max(level, 1)
	return .Error
}

@(private = "file")
base_error :: proc(c: ^Native_Call) -> Native_Status {
	level := opt_int(c, 2, 1) or_return
	return raise_value(c, arg(c, 1), int(clamp(level, 0, 1 << 20)))
}

@(private = "file")
base_getmetatable :: proc(c: ^Native_Call) -> Native_Status {
	v := check_any(c, 1) or_return
	mt := metatable_of(c.vm, v)
	if mt == 0 {return push_nil(c)}
	protected := mt_field(c.vm, mt, .Metatable)
	if protected.tag != .Nil {return push_value(c, protected)}
	return push_value(c, ref_value(.Table, mt))
}

@(private = "file")
base_setmetatable :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	m := arg(c, 2)
	if m.tag != .Nil && m.tag != .Table {
		return arg_error(c, 2, fmt.tprintf("nil or table expected, got %s", type_name(m)))
	}
	vm := c.vm
	tab := obj(vm, t, Table)
	if tab.meta != 0 && mt_field(vm, tab.meta, .Metatable).tag != .Nil {
		return raise(c, "cannot change a protected metatable")
	}
	tab = obj(vm, t, Table)
	tab.meta = as_ref(m) if m.tag == .Table else 0
	barrier_forward(vm, t, m)
	return push_value(c, arg(c, 1))
}

@(private = "file")
base_ipairs :: proc(c: ^Native_Call) -> Native_Status {
	check_any(c, 1) or_return
	step := find_native(c.vm, "ipairs_step")
	f := native_closure(c.vm, step)
	if f.tag == .Nil {return .Error}
	push_value(c, f) or_return
	push_value(c, arg(c, 1)) or_return
	return push_int(c, 0)
}

// ipairs is raw: it ignores __index.
@(private = "file")
base_ipairs_step :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	i := check_int(c, 2) or_return
	i += 1
	v := table_get_int(c.vm, t, i)
	if v.tag == .Nil {return push_nil(c)}
	push_int(c, i) or_return
	return push_value(c, v)
}

@(private = "file")
base_next :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	k, v, found := table_next(c.vm, t, arg(c, 2))
	if !found {return raise(c, "invalid key to 'next'")}
	if k.tag == .Nil {return push_nil(c)}
	push_value(c, k) or_return
	return push_value(c, v)
}

@(private = "file")
base_pairs :: proc(c: ^Native_Call) -> Native_Status {
	check_table(c, 1) or_return
	f := native_value(c.vm, "next")
	if f.tag == .Nil {return .Error}
	push_value(c, f) or_return
	push_value(c, arg(c, 1)) or_return
	return push_nil(c)
}

@(private = "file")
base_rawequal :: proc(c: ^Native_Call) -> Native_Status {
	a := check_any(c, 1) or_return
	b := check_any(c, 2) or_return
	return push_bool(c, raw_equal(a, b))
}

@(private = "file")
base_rawget :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	k := check_any(c, 2) or_return
	return push_value(c, table_get(c.vm, t, k))
}

@(private = "file")
base_rawlen :: proc(c: ^Native_Call) -> Native_Status {
	v := arg(c, 1)
	#partial switch v.tag {
	case .Table:
		return push_int(c, table_len(c.vm, as_ref(v)))
	case .String:
		return push_int(c, i64(obj(c.vm, as_ref(v), String).len))
	}
	return arg_error(c, 1, "table or string expected")
}

@(private = "file")
base_rawset :: proc(c: ^Native_Call) -> Native_Status {
	t := check_table(c, 1) or_return
	k := check_any(c, 2) or_return
	v := check_any(c, 3) or_return
	switch table_set(c.vm, t, k, v) {
	case .Ok:
	case .Memory:
		return .Error
	case .Nil_Key:
		return raise(c, "index is nil")
	case .Nan_Key:
		return raise(c, "index is NaN")
	}
	return push_value(c, arg(c, 1))
}

@(private = "file")
base_select :: proc(c: ^Native_Call) -> Native_Status {
	n := i64(arg_count(c)) - 1
	if a := arg(c, 1); a.tag == .String && value_string(c.vm, a) == "#" {
		return push_int(c, n)
	}
	i := check_int(c, 1) or_return
	if i < 0 {
		i = n + i
		if i < 0 {return arg_error(c, 1, "index out of range")}
	} else if i == 0 {
		return arg_error(c, 1, "index out of range")
	} else {
		i -= 1
	}
	// The results are the arguments from 2 + i on: move them down to ret.
	if i >= n {return .Ok}
	stack := thread_stack(c.vm, c.th)
	from := c.func + 2 + u32(i)
	count := u32(n - i)
	for j in 0 ..< count {stack[c.ret + j] = stack[from + j]}
	c.th.top = c.ret + count
	return .Ok
}

@(private = "file")
base_tonumber :: proc(c: ^Native_Call) -> Native_Status {
	if arg(c, 2).tag == .Nil {
		v := check_any(c, 1) or_return
		if is_number(v) {return push_value(c, v)}
		if v.tag == .String {
			if n, ok := parse_number(value_string(c.vm, v)); ok {return push_value(c, n)}
		}
		return push_nil(c)
	}
	base := check_int(c, 2) or_return
	s := check_string(c, 1) or_return
	if base < 2 || base > 36 {return arg_error(c, 2, "base out of range")}
	if n, ok := parse_int_base(s, int(base)); ok {return push_value(c, n)}
	return push_nil(c)
}

@(private = "file")
base_type :: proc(c: ^Native_Call) -> Native_Status {
	v := check_any(c, 1) or_return
	return push_string(c, type_name(v))
}

@(private = "file")
base_collectgarbage :: proc(c: ^Native_Call) -> Native_Status {
	opt := "collect"
	if arg(c, 1).tag != .Nil {opt = check_string(c, 1) or_return}
	if opt != "count" {
		return raise_hint(
			c,
			"memory is managed by the VM; collectgarbage(\"count\") reports what is in use",
			"collectgarbage('%s') is not available in scripts",
			opt,
		)
	}
	return push_float(c, f64(c.vm.in_use) / 1024)
}

@(private = "file")
base_traceback :: proc(c: ^Native_Call) -> Native_Status {
	msg := arg(c, 1)
	if msg.tag != .Nil && msg.tag != .String && !is_number(msg) {return push_value(c, msg)}
	b := strings.builder_make(context.temp_allocator)
	if msg.tag != .Nil {
		value_text(c.vm, msg, &b)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "stack traceback:")
	for f in traceback(c.vm, c.th, context.temp_allocator) {
		strings.write_byte(&b, '\n')
		write_trace_frame(&b, f)
		pop(&b.buf)
	}
	return push_string(c, strings.to_string(b))
}

@(private = "file")
base_rawtostring :: proc(c: ^Native_Call) -> Native_Status {
	v := check_any(c, 1) or_return
	if v.tag == .String {return push_value(c, v)}
	b := strings.builder_make(context.temp_allocator)
	value_text(c.vm, v, &b)
	return push_string(c, strings.to_string(b))
}

// write appends its string arguments to the VM's output, up to output_max between
// drains; the rest is counted.
@(private = "file")
base_write :: proc(c: ^Native_Call) -> Native_Status {
	vm := c.vm
	for i in 1 ..= arg_count(c) {
		s := check_string(c, i) or_return
		room := int(vm.limits.output_max) - len(vm.output)
		if room <= 0 {
			vm.output_dropped += len(s)
			continue
		}
		take := min(room, len(s))
		append(&vm.output, s[:take])
		vm.output_dropped += len(s) - take
		charge(c, i64(len(s) + 63) / 64)
	}
	return .Ok
}

// metafield(v, name): the raw metatable field of v, or nil.
@(private = "file")
base_metafield :: proc(c: ^Native_Call) -> Native_Status {
	v := arg(c, 1)
	name := check_string(c, 2) or_return
	mt := metatable_of(c.vm, v)
	if mt == 0 {return push_nil(c)}
	return push_value(c, table_get(c.vm, mt, new_string(c.vm, name)))
}
