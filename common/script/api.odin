package script

import "core:fmt"
import "core:strings"

// The host API: natives and what they use, and host-side values outside a run. Natives
// never call script code; everything a native makes is pushed on the stack.

Native_Status :: enum u8 {
	Ok,
	Error,
	Yield,
}

Native :: #type proc(c: ^Native_Call) -> Native_Status

Native_Spec :: struct {
	name: string,
	fn:   Native,
	cost: i32,
}

// Native_Call: one call of a native. Its arguments are stack[func+1 ..][:nargs]; its
// results are what it pushes from ret on.
Native_Call :: struct {
	vm:      ^VM,
	th:      ^Thread,
	func:    u32,
	nargs:   u32,
	ret:     u32,
	closure: Ref,
	name:    string,
}

arg_count :: #force_inline proc(c: ^Native_Call) -> int {
	return int(c.nargs)
}

// arg: argument i (1-based); nil past the last.
arg :: proc(c: ^Native_Call, i: int) -> Value {
	if i < 1 || i > int(c.nargs) {return NIL}
	return thread_stack(c.vm, c.th)[c.func + u32(i)]
}

// raise ends the native with a runtime error.
raise :: proc(c: ^Native_Call, format: string, args: ..any) -> Native_Status {
	rt_errorf(c.vm, "", format, ..args)
	return .Error
}

raise_hint :: proc(c: ^Native_Call, hint: string, format: string, args: ..any) -> Native_Status {
	rt_errorf(c.vm, hint, format, ..args)
	return .Error
}

// arg_error: "bad argument #i to 'name' (what)".
arg_error :: proc(c: ^Native_Call, i: int, what: string) -> Native_Status {
	return raise(c, "bad argument #%d to '%s' (%s)", i, c.name, what)
}

@(private = "file")
type_error :: proc(c: ^Native_Call, i: int, expected: string) -> Native_Status {
	v := arg(c, i)
	got := "no value" if i > int(c.nargs) else type_name(v)
	return arg_error(c, i, fmt.tprintf("%s expected, got %s", expected, got))
}

charge :: #force_inline proc(c: ^Native_Call, units: i64) {
	c.vm.meter -= units
}

check_any :: proc(c: ^Native_Call, i: int) -> (Value, Native_Status) {
	if i > int(c.nargs) {return NIL, arg_error(c, i, "value expected")}
	return arg(c, i), .Ok
}

check_int :: proc(c: ^Native_Call, i: int) -> (i64, Native_Status) {
	v := arg(c, i)
	#partial switch v.tag {
	case .Int:
		return as_int(v), .Ok
	case .Float:
		if n, ok := float_to_int_exact(as_float(v)); ok {return n, .Ok}
		return 0, arg_error(c, i, "number has no integer representation")
	}
	return 0, type_error(c, i, "number")
}

opt_int :: proc(c: ^Native_Call, i: int, default: i64) -> (i64, Native_Status) {
	if arg(c, i).tag == .Nil {return default, .Ok}
	return check_int(c, i)
}

check_number :: proc(c: ^Native_Call, i: int) -> (Value, Native_Status) {
	v := arg(c, i)
	if is_number(v) {return v, .Ok}
	return NIL, type_error(c, i, "number")
}

check_string :: proc(c: ^Native_Call, i: int) -> (string, Native_Status) {
	v := arg(c, i)
	if v.tag == .String {return value_string(c.vm, v), .Ok}
	return "", type_error(c, i, "string")
}

check_table :: proc(c: ^Native_Call, i: int) -> (Ref, Native_Status) {
	v := arg(c, i)
	if v.tag == .Table {return as_ref(v), .Ok}
	return 0, type_error(c, i, "table")
}

check_function :: proc(c: ^Native_Call, i: int) -> (Value, Native_Status) {
	v := arg(c, i)
	if v.tag == .Function {return v, .Ok}
	return NIL, type_error(c, i, "function")
}

// Pushing results.

push_value :: proc(c: ^Native_Call, v: Value) -> Native_Status {
	if c.th.top + 1 + EXTRA_STACK > c.th.stack_cap {
		if !ensure_stack(c.vm, c.th, c.th.top + 1 + EXTRA_STACK) {return .Error}
	}
	thread_stack(c.vm, c.th)[c.th.top] = v
	c.th.top += 1
	return .Ok
}

push_nil :: proc(c: ^Native_Call) -> Native_Status {return push_value(c, NIL)}
push_bool :: proc(c: ^Native_Call, b: bool) -> Native_Status {return push_value(c, bool_value(b))}
push_int :: proc(c: ^Native_Call, i: i64) -> Native_Status {return push_value(c, int_value(i))}
push_float :: proc(c: ^Native_Call, f: f64) -> Native_Status {return push_value(c, float_value(f))}

push_string :: proc(c: ^Native_Call, s: string) -> Native_Status {
	if len(s) > int(c.vm.limits.string_max) {
		return raise_hint(
			c,
			"a string may hold at most the VM's string limit (1 MiB by default)",
			"string too large",
		)
	}
	v := new_string(c.vm, s)
	if v.tag == .Nil {return .Error}
	return push_value(c, v)
}

// push_table pushes a new table and returns it.
push_table :: proc(c: ^Native_Call, narr: u32 = 0, nhash: u32 = 0) -> (Value, Native_Status) {
	t := table_new(c.vm, narr, nhash)
	if t == 0 {return NIL, .Error}
	v := ref_value(.Table, t)
	return v, push_value(c, v)
}

// Native closures.

// find_native: a native's id by name, or -1.
find_native :: proc(vm: ^VM, name: string) -> int {
	for n, i in vm.natives {
		if n.name == name {return i}
	}
	return -1
}

native_closure :: proc(vm: ^VM, id: int, intrinsic: Intrinsic = .None) -> Value {
	r := heap_alloc(vm, .Native_Closure, NATIVE_UPVALS)
	if r == 0 {return NIL}
	nc := obj(vm, r, Native_Closure)
	nc.native = u32(id)
	nc.intrinsic = intrinsic
	return ref_value(.Function, r)
}

// native_value: a closure of the named native, for binding; nil when there is none.
native_value :: proc(vm: ^VM, name: string) -> Value {
	id := find_native(vm, name)
	if id < 0 {return NIL}
	return native_closure(vm, id)
}

// Host-side values (outside a run nothing is collected, so they stay alive until the
// host passes them to call).

new_table :: proc(vm: ^VM) -> Value {
	t := table_new(vm)
	if t == 0 {
		vm.fault = .None
		return NIL
	}
	return ref_value(.Table, t)
}

table_get_raw :: proc(vm: ^VM, t: Value, key: Value) -> Value {
	if t.tag != .Table {return NIL}
	return table_get(vm, as_ref(t), key)
}

table_set_raw :: proc(vm: ^VM, t: Value, key, val: Value) -> bool {
	if t.tag != .Table {return false}
	r := table_set(vm, as_ref(t), key, val)
	vm.fault = .None
	return r == .Ok
}

set_global :: proc(vm: ^VM, name: string, v: Value) -> bool {
	k := new_string(vm, name)
	if k.tag == .Nil {
		vm.fault = .None
		return false
	}
	return table_set_raw(vm, ref_value(.Table, vm.globals), k, v)
}

get_global :: proc(vm: ^VM, name: string) -> Value {
	k := new_string(vm, name)
	if k.tag == .Nil {
		vm.fault = .None
		return NIL
	}
	return table_get(vm, vm.globals, k)
}

// value_text: a value as tostring prints it without metamethods (rawtostring).
value_text :: proc(vm: ^VM, v: Value, b: ^strings.Builder) {
	switch v.tag {
	case .Nil:
		strings.write_string(b, "nil")
	case .Bool:
		strings.write_string(b, "true" if as_bool(v) else "false")
	case .Int, .Float:
		write_number(b, v)
	case .String:
		strings.write_string(b, value_string(vm, v))
	case .Handle:
		fmt.sbprintf(b, "%s: 0x%016x", handle_kind_name(vm, v.kind), v.bits)
	case .Table:
		t := obj(vm, as_ref(v), Table)
		if t.id == 0 {t.id = next_object_id(vm)}
		fmt.sbprintf(b, "table: 0x%08x", t.id)
	case .Function:
		r := as_ref(v)
		id: ^u32
		if obj_kind(vm, r) == .Closure {
			id = &obj(vm, r, Closure).id
		} else {
			id = &obj(vm, r, Native_Closure).id
		}
		if id^ == 0 {id^ = next_object_id(vm)}
		fmt.sbprintf(b, "function: 0x%08x", id^)
	case .Thread:
		t := obj(vm, as_ref(v), Thread)
		if t.id == 0 {t.id = next_object_id(vm)}
		fmt.sbprintf(b, "thread: 0x%08x", t.id)
	}
}

next_object_id :: proc(vm: ^VM) -> u32 {
	vm.next_id += 1
	return vm.next_id
}

// host_yield ends the native and the run with .Yielded: the values the native pushed
// go to the host; resume's values become the native's results.
host_yield :: proc(c: ^Native_Call) -> Native_Status {
	return .Yield
}

// Pins: values the host keeps across runs, rooted (the registry table) and snapshotted.
// Freed slots are reused lowest first.

Pin :: distinct u32

pin :: proc(vm: ^VM, v: Value) -> Pin {
	reg := ref_value(.Table, vm.registry)
	slot: i64 = 1
	for table_get_int(vm, vm.registry, slot).tag != .Nil {slot += 1}
	if v.tag == .Nil {return 0}
	if !table_set_raw(vm, reg, int_value(slot), v) {return 0}
	return Pin(slot)
}

pinned :: proc(vm: ^VM, p: Pin) -> Value {
	if p == 0 {return NIL}
	return table_get_int(vm, vm.registry, i64(p))
}

unpin :: proc(vm: ^VM, p: Pin) {
	if p == 0 {return}
	table_set_raw(vm, ref_value(.Table, vm.registry), int_value(i64(p)), NIL)
}

// Handles: opaque 64-bit ids with a host-defined kind (the game's entities, players,
// positions). Kinds are numbered from 1 in registration order and recorded by name.

register_handle_kind :: proc(vm: ^VM, name: string) -> u16 {
	for k, i in vm.handle_kinds {
		if k == name {return u16(i + 1)}
	}
	append(&vm.handle_kinds, strings.clone(name, vm.allocator))
	return u16(len(vm.handle_kinds))
}

handle_kind_name :: proc(vm: ^VM, kind: u16) -> string {
	if kind == 0 || int(kind) > len(vm.handle_kinds) {return "handle"}
	return vm.handle_kinds[kind - 1]
}

set_handle_metatable :: proc(vm: ^VM, kind: u16, mt: Value) -> bool {
	return table_set_raw(vm, ref_value(.Table, vm.handle_metas), int_value(i64(kind)), mt)
}

check_handle :: proc(c: ^Native_Call, i: int, kind: u16) -> (u64, Native_Status) {
	v := arg(c, i)
	if v.tag == .Handle && v.kind == kind {return v.bits, .Ok}
	got := "no value" if i > int(c.nargs) else type_name(v)
	if v.tag == .Handle {got = handle_kind_name(c.vm, v.kind)}
	return 0, arg_error(
		c,
		i,
		fmt.tprintf("%s expected, got %s", handle_kind_name(c.vm, kind), got),
	)
}

// Library tables.

lib_name :: proc(lib, name: string) -> string {
	return concat_temp(lib, ".", name)
}

concat_temp :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// lib_table: a new table bound as a global.
lib_table :: proc(vm: ^VM, name: string) -> (Value, bool) {
	t := new_table(vm)
	if t.tag == .Nil {return NIL, false}
	if !set_global(vm, name, t) {return NIL, false}
	return t, true
}

lib_bind :: proc(vm: ^VM, t: Value, name: string, v: Value) -> bool {
	if v.tag == .Nil {return false}
	k := new_string(vm, name)
	if k.tag == .Nil {return false}
	return table_set_raw(vm, t, k, v)
}

// lib_open binds every native of a library whose name begins "lib." into the table lib.
lib_open :: proc(vm: ^VM, lib: string, specs: []Native_Spec) -> (t: Value, ok: bool) {
	t = lib_table(vm, lib) or_return
	prefix := concat_temp(lib, ".")
	for s in specs {
		if !strings.has_prefix(s.name, prefix) {continue}
		lib_bind(vm, t, s.name[len(prefix):], native_value(vm, s.name)) or_return
	}
	return t, true
}
