package script

// Values: a tagged union in 16 bytes (docs/script.md). Every constructor writes the
// whole struct, so padding is zero and values hash and snapshot as bytes.

Tag :: enum u8 {
	Nil,
	Bool,
	Int,
	Float,
	Handle,
	String,
	Table,
	Function,
	Thread,
}

// Ref is the byte offset of an object in a VM's heap; 0 is none.
Ref :: distinct u32

Value :: struct {
	bits:  u64, // i64, f64 bits, bool (0/1), handle bits, or a Ref in the low 32
	tag:   Tag,
	_pad0: u8,
	kind:  u16, // a handle's kind; 0 otherwise
	_pad1: u32,
}
#assert(size_of(Value) == 16)

// CANONICAL_NAN: every NaN a script makes has these bits, on x64 and arm64 alike.
CANONICAL_NAN :: 0x7FF8_0000_0000_0000

NIL :: Value{}
TRUE :: Value {
	bits = 1,
	tag  = .Bool,
}
FALSE :: Value {
	tag = .Bool,
}

bool_value :: #force_inline proc "contextless" (b: bool) -> Value {
	return Value{bits = u64(b), tag = .Bool}
}

int_value :: #force_inline proc "contextless" (i: i64) -> Value {
	return Value{bits = cast(u64)i, tag = .Int}
}

float_value :: #force_inline proc "contextless" (f: f64) -> Value {
	if f != f {return Value{bits = CANONICAL_NAN, tag = .Float}}
	return Value{bits = transmute(u64)f, tag = .Float}
}

ref_value :: #force_inline proc "contextless" (tag: Tag, r: Ref) -> Value {
	return Value{bits = u64(r), tag = tag}
}

handle_value :: proc "contextless" (kind: u16, bits: u64) -> Value {
	return Value{bits = bits, tag = .Handle, kind = kind}
}

as_int :: #force_inline proc "contextless" (v: Value) -> i64 {return cast(i64)v.bits}
as_float :: #force_inline proc "contextless" (v: Value) -> f64 {return transmute(f64)v.bits}
as_ref :: #force_inline proc "contextless" (v: Value) -> Ref {return Ref(u32(v.bits))}
as_bool :: #force_inline proc "contextless" (v: Value) -> bool {return v.bits != 0}

is_falsy :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag == .Nil || (v.tag == .Bool && v.bits == 0)
}

is_number :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag == .Int || v.tag == .Float
}

is_collectable :: #force_inline proc "contextless" (v: Value) -> bool {
	return v.tag >= .String
}

// raw_equal: equality without metamethods; 1 == 1.0, strings are interned.
raw_equal :: proc "contextless" (a, b: Value) -> bool {
	if a.tag == b.tag {
		switch a.tag {
		case .Nil:
			return true
		case .Float:
			return as_float(a) == as_float(b)
		case .Handle:
			return a.bits == b.bits && a.kind == b.kind
		case .Bool, .Int, .String, .Table, .Function, .Thread:
			return a.bits == b.bits
		}
	}
	if a.tag == .Int && b.tag == .Float {return int_eq_float(as_int(a), as_float(b))}
	if a.tag == .Float && b.tag == .Int {return int_eq_float(as_int(b), as_float(a))}
	return false
}

type_name_of_tag :: proc "contextless" (t: Tag) -> string {
	switch t {
	case .Nil:
		return "nil"
	case .Bool:
		return "boolean"
	case .Int, .Float:
		return "number"
	case .Handle:
		return "handle"
	case .String:
		return "string"
	case .Table:
		return "table"
	case .Function:
		return "function"
	case .Thread:
		return "thread"
	}
	return "?"
}

type_name :: proc "contextless" (v: Value) -> string {
	return type_name_of_tag(v.tag)
}
