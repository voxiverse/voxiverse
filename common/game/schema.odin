package game

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"

// The state schema (M39): what the server replicates to clients, described by
// the value types themselves. A state kind is a value type with a key and a
// lane; an event kind is a one-off value. schema_make walks each type's
// runtime.Type_Info once and builds a flat field list per kind, from which the
// one codec (replica.odin) encodes, compares and checks values. A new field in
// a value type is replicated without anyone writing protocol code.
//
// Fields are leaves: nested structs are flattened (`state.position`). Arrays of
// scalars are one field; arrays of anything else are one field whose changes
// are sent element by element. Supported types: bool, integers, f32/f64,
// enums, bit_sets, arrays, structs inside arrays, unions (Maybe) and strings
// with a `net:"max=N"` tag. Everything else is refused as a value (a
// Schema_Error naming the field), never a panic.

MAX_FIELDS :: 62 // a change's mask is 62 bits (the head also holds the op)

Lane :: enum u8 {
	Reliable,
	Snapshot,
}

Key_Type :: enum u8 {
	None,
	Player,
	Entity,
	Block,
}

// Predicted: how a client reconciles a record of the kind with what it
// predicted (the kind has an `acked` field when it is not None).
Predicted :: enum u8 {
	None,
	Inputs,
	Requests,
}

State_Kind_Info :: struct {
	name:          string, // lower case: the wire and tool name
	value:         typeid, // a struct
	key:           Key_Type,
	lane:          Lane,
	write_through: bool, // the server keeps no copy: every record is whole
	priority:      u8, // snapshot lane: lower goes first
	locate:        proc(value: rawptr) -> [3]i32, // snapshot lane: where it is, in whole blocks (nil: at the player)
	max_records:   int, // at most this many records at a time (singletons: 1)
	version:       u8, // bumped when a value keeps its type but changes meaning
	predicted:     Predicted,
	check:         proc(value: rawptr) -> bool, // what the types cannot say; nil if none
}

Event_Kind_Info :: struct {
	name:    string,
	value:   typeid,
	version: u8,
	check:   proc(value: rawptr) -> bool,
}

Field_Type :: enum u8 {
	Bool,
	Uint,
	Int,
	F32,
	F64,
	Enum,
	Bit_Set,
	Array,
	Union,
	String,
}

Field :: struct {
	path:       string,
	type:       Field_Type,
	offset:     int, // in the value
	size:       int, // bytes in memory
	ti:         ^runtime.Type_Info, // the field's type, as Type_Info_Named stripped
	max:        int, // strings: the longest allowed
	acked:      bool, // holds the sequence of the input or request the value reflects
	scalar:     bool, // arrays: of scalars (one field, sent whole); else element by element
	count:      int, // arrays: elements
	elem:       ^runtime.Type_Info, // arrays: the element's type
	elem_size:  int,
	valid_bits: u64, // bit_sets: the bits a value may have
	values:     []i64, // enums: the declared values
}

Schema_Kind :: struct {
	using info:  State_Kind_Info, // (an event's: key None, Reliable, one record)
	id:          int, // state kinds 0 .., then event kinds
	is_event:    bool,
	size:        int, // of a value
	align:       int,
	fields:      []Field,
	has_strings: bool,
	ack_field:   int, // the field with the `acked` tag (-1: none)
}

Schema :: struct {
	kinds:     []Schema_Kind, // state kinds, then event kinds
	n_states:  int,
	hash:      u64,
	allocator: mem.Allocator,
}

Schema_Error :: struct {
	kind:   string,
	path:   string,
	reason: string, // "": none
}

schema_error_text :: proc(e: Schema_Error) -> string {
	return fmt.tprintf("%s: %s: %s", e.kind, e.path, e.reason)
}

// schema_make builds the schema of kinds; the error (if any) names the first
// field that cannot be replicated.
schema_make :: proc(
	states: []State_Kind_Info,
	events: []Event_Kind_Info,
	allocator := context.allocator,
) -> (
	s: Schema,
	err: Schema_Error,
) {
	s.allocator = allocator
	s.n_states = len(states)
	s.kinds = make([]Schema_Kind, len(states) + len(events), allocator)
	for info, i in states {
		k := &s.kinds[i]
		k.info, k.id = info, i
		if err = kind_build(k, allocator); err.reason != "" {
			schema_destroy(&s)
			return {}, err
		}
	}
	for e, i in events {
		k := &s.kinds[len(states) + i]
		k.info = {
			name        = e.name,
			value       = e.value,
			version     = e.version,
			check       = e.check,
			max_records = 1,
		}
		k.id, k.is_event = len(states) + i, true
		if err = kind_build(k, allocator); err.reason != "" {
			schema_destroy(&s)
			return {}, err
		}
	}
	for a, i in s.kinds {
		for b in s.kinds[i + 1:] {
			if a.name == b.name {
				schema_destroy(&s)
				return {}, {a.name, "", "two kinds have this name"}
			}
		}
	}
	text := schema_text(&s)
	h := hasher_make()
	hasher_bytes(&h, transmute([]u8)text)
	s.hash = hasher_finish(h)
	return s, {}
}

schema_destroy :: proc(s: ^Schema) {
	for &k in s.kinds {
		for f in k.fields {
			delete(f.path, s.allocator)
			delete(f.values, s.allocator)
		}
		delete(k.fields, s.allocator)
	}
	delete(s.kinds, s.allocator)
	s^ = {}
}

@(private = "file")
Builder :: struct {
	kind:       ^Schema_Kind,
	fields:     [dynamic]Field,
	err:        Schema_Error,
	allocator:  mem.Allocator,
	strings_ok: bool,
}

@(private = "file")
refuse :: proc(b: ^Builder, path, reason: string) {
	if b.err.reason == "" {
		b.err = {b.kind.name, strings.clone(path, context.temp_allocator), reason}
	}
}

@(private = "file")
kind_build :: proc(k: ^Schema_Kind, allocator: mem.Allocator) -> (err: Schema_Error) {
	ti := type_info_of(k.value)
	if ti == nil {return {k.name, "", "has no value type"}}
	base := runtime.type_info_base(ti)
	if _, is_struct := base.variant.(runtime.Type_Info_Struct); !is_struct {
		return {k.name, "", "its value is not a struct"}
	}
	k.size, k.align = ti.size, ti.align
	if k.max_records == 0 {k.max_records = 1}
	if k.key == .None && k.max_records != 1 {
		return {k.name, "", "a kind without a key holds one record"}
	}
	if k.write_through && (k.lane != .Reliable || k.key == .None) {
		return {k.name, "", "write-through needs the reliable lane and a key"}
	}
	b := Builder {
		kind       = k,
		fields     = make([dynamic]Field, allocator),
		allocator  = allocator,
		strings_ok = k.lane == .Reliable,
	}
	flatten(&b, ti, 0, "", "")
	if b.err.reason == "" && len(b.fields) > MAX_FIELDS {
		refuse(&b, "", fmt.tprintf("has %d fields, at most %d", len(b.fields), MAX_FIELDS))
	}
	if b.err.reason == "" && len(b.fields) == 0 {
		refuse(&b, "", "has no fields")
	}
	if b.err.reason != "" {
		for f in b.fields {
			delete(f.path, allocator)
			delete(f.values, allocator)
		}
		delete(b.fields)
		return b.err
	}
	k.fields = b.fields[:]
	k.ack_field = -1
	for f, i in k.fields {
		if f.type == .String {k.has_strings = true}
		if f.acked {k.ack_field = i}
	}
	return {}
}

// tag_lookup reads one entry of a field's `net:"..."` tag: "max=16", "acked".
@(private = "file")
tag_has :: proc(tag: string, name: string) -> (value: string, found: bool) {
	t, ok := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "net")
	if !ok {return}
	rest := string(t)
	for part in strings.split_iterator(&rest, ",") {
		if part == name {return "", true}
		if strings.has_prefix(part, name) && len(part) > len(name) && part[len(name)] == '=' {
			return part[len(name) + 1:], true
		}
	}
	return
}

@(private = "file")
scalar_type :: proc(base: ^runtime.Type_Info) -> bool {
	#partial switch _ in base.variant {
	case runtime.Type_Info_Integer,
	     runtime.Type_Info_Float,
	     runtime.Type_Info_Boolean,
	     runtime.Type_Info_Enum,
	     runtime.Type_Info_Bit_Set:
		return true
	}
	return false
}

@(private = "file")
join_path :: proc(a, b: string, allocator: mem.Allocator) -> string {
	if a == "" {return strings.clone(b, allocator)}
	return strings.concatenate({a, ".", b}, allocator)
}

// flatten adds the leaves of ti (at offset) to b.fields.
@(private = "file")
flatten :: proc(b: ^Builder, ti: ^runtime.Type_Info, offset: int, path: string, tag: string) {
	if b.err.reason != "" {return}
	base := runtime.type_info_base(ti)
	field := Field {
		path   = path,
		offset = offset,
		size   = ti.size,
		ti     = base,
	}
	_, field.acked = tag_has(tag, "acked")
	#partial switch v in base.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			name := v.names[i]
			if name == "_" {continue}
			flatten(
				b,
				v.types[i],
				offset + int(v.offsets[i]),
				join_path(path, name, context.temp_allocator),
				v.tags[i],
			)
		}
		return
	case runtime.Type_Info_Boolean:
		field.type = .Bool
	case runtime.Type_Info_Integer:
		field.type = .Int if v.signed else .Uint
		if ti.size > 8 {refuse(b, path, "integer wider than 64 bits"); return}
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4:
			field.type = .F32
		case 8:
			field.type = .F64
		case:
			refuse(b, path, "float is neither f32 nor f64")
			return
		}
	case runtime.Type_Info_Enum:
		field.type = .Enum
		field.values = make([]i64, len(v.values), b.allocator)
		for x, i in v.values {field.values[i] = i64(x)}
	case runtime.Type_Info_Bit_Set:
		field.type = .Bit_Set
		if ti.size > 8 {refuse(b, path, "bit_set wider than 64 bits"); return}
		if en, is_enum := runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Enum);
		   is_enum {
			for x in en.values {field.valid_bits |= 1 << uint(i64(x) - i64(v.lower))}
		} else {
			for bit in v.lower ..= v.upper {field.valid_bits |= 1 << uint(bit - v.lower)}
		}
	case runtime.Type_Info_Array:
		field.type = .Array
		field.count, field.elem, field.elem_size = v.count, v.elem, v.elem_size
	case runtime.Type_Info_Enumerated_Array:
		field.type = .Array
		field.count, field.elem, field.elem_size = v.count, v.elem, v.elem_size
	case runtime.Type_Info_Union:
		field.type = .Union
		if len(v.variants) > 250 {refuse(b, path, "union with too many variants"); return}
	case runtime.Type_Info_String:
		field.type = .String
		if v.is_cstring {refuse(b, path, "cstring has no length"); return}
		value, ok := tag_has(tag, "max")
		n, parsed := strconv.parse_int(value)
		if !ok || !parsed || n <= 0 {
			refuse(b, path, `string has no net:"max=N"`)
			return
		}
		if !b.strings_ok {
			refuse(b, path, "string on the snapshot lane")
			return
		}
		field.max = n
	case runtime.Type_Info_Named:
		unreachable()
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer:
		refuse(b, path, "pointer")
		return
	case runtime.Type_Info_Slice:
		refuse(b, path, "slice")
		return
	case runtime.Type_Info_Dynamic_Array:
		refuse(b, path, "dynamic array")
		return
	case runtime.Type_Info_Map:
		refuse(b, path, "map")
		return
	case runtime.Type_Info_Procedure:
		refuse(b, path, "procedure")
		return
	case runtime.Type_Info_Any:
		refuse(b, path, "any")
		return
	case:
		refuse(b, path, "a type that cannot be replicated")
		return
	}
	if field.type == .Array {
		elem := runtime.type_info_base(field.elem)
		field.scalar = scalar_type(elem)
		if !field.scalar && !whole_supported(b, elem, fmt.tprintf("%s[]", path)) {return}
		if field.count == 0 {refuse(b, path, "empty array"); return}
	}
	if field.type == .Union {
		for variant in base.variant.(runtime.Type_Info_Union).variants {
			if !whole_supported(b, runtime.type_info_base(variant), path) {return}
		}
	}
	field.path = strings.clone(path, b.allocator)
	append(&b.fields, field)
}

// whole_supported: ti may be inside an array or a union (no strings there).
@(private = "file")
whole_supported :: proc(b: ^Builder, ti: ^runtime.Type_Info, path: string) -> bool {
	if scalar_type(ti) {
		if i, is_int := ti.variant.(runtime.Type_Info_Integer); is_int && ti.size > 8 {
			refuse(b, path, "integer wider than 64 bits")
			_ = i
			return false
		}
		return true
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			if v.names[i] == "_" {continue}
			child := fmt.tprintf("%s.%s", path, v.names[i])
			if !whole_supported(b, runtime.type_info_base(v.types[i]), child) {return false}
		}
		return true
	case runtime.Type_Info_Array:
		return whole_supported(b, runtime.type_info_base(v.elem), path)
	case runtime.Type_Info_Enumerated_Array:
		return whole_supported(b, runtime.type_info_base(v.elem), path)
	case runtime.Type_Info_Union:
		for variant in v.variants {
			if !whole_supported(b, runtime.type_info_base(variant), path) {return false}
		}
		return true
	case runtime.Type_Info_String:
		refuse(b, path, "string inside an array or union")
		return false
	}
	refuse(b, path, "a type that cannot be replicated")
	return false
}

// type_text writes a type in a canonical form, so the schema's text (and hash)
// change with a field's type, an enum's values or a bit_set's bits.
@(private = "file")
type_text :: proc(sb: ^strings.Builder, ti: ^runtime.Type_Info) {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		fmt.sbprint(sb, "bool")
	case runtime.Type_Info_Integer:
		fmt.sbprintf(sb, "%s%d", "i" if v.signed else "u", base.size * 8)
	case runtime.Type_Info_Float:
		fmt.sbprintf(sb, "f%d", base.size * 8)
	case runtime.Type_Info_Enum:
		fmt.sbprintf(sb, "enum<%d>{{", base.size * 8)
		for name, i in v.names {
			if i > 0 {fmt.sbprint(sb, ",")}
			fmt.sbprintf(sb, "%s=%d", name, i64(v.values[i]))
		}
		fmt.sbprint(sb, "}")
	case runtime.Type_Info_Bit_Set:
		fmt.sbprintf(sb, "bits<%d>", base.size * 8)
		if en, ok := runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Enum); ok {
			fmt.sbprint(sb, "{")
			for name, i in en.names {
				if i > 0 {fmt.sbprint(sb, ",")}
				fmt.sbprintf(sb, "%s=%d", name, i64(en.values[i]) - i64(v.lower))
			}
			fmt.sbprint(sb, "}")
		} else {
			fmt.sbprintf(sb, "{{%d..%d}}", v.lower, v.upper)
		}
	case runtime.Type_Info_Array:
		fmt.sbprintf(sb, "[%d]", v.count)
		type_text(sb, v.elem)
	case runtime.Type_Info_Enumerated_Array:
		fmt.sbprintf(sb, "[%d]", v.count)
		type_text(sb, v.elem)
	case runtime.Type_Info_Struct:
		fmt.sbprint(sb, "{")
		first := true
		for i in 0 ..< int(v.field_count) {
			if v.names[i] == "_" {continue}
			if !first {fmt.sbprint(sb, ",")}
			first = false
			fmt.sbprintf(sb, "%s:", v.names[i])
			type_text(sb, v.types[i])
		}
		fmt.sbprint(sb, "}")
	case runtime.Type_Info_Union:
		fmt.sbprint(sb, "union{")
		for variant, i in v.variants {
			if i > 0 {fmt.sbprint(sb, ",")}
			type_text(sb, variant)
		}
		fmt.sbprint(sb, "}")
	case runtime.Type_Info_String:
		fmt.sbprint(sb, "string")
	case:
		fmt.sbprint(sb, "?")
	}
}

// schema_text writes the schema, one line per kind and per field, in kind
// order: the text its hash is taken over, and what a person reads to see how
// two versions differ.
schema_text :: proc(s: ^Schema, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for k in s.kinds {
		if k.is_event {
			fmt.sbprintfln(&sb, "event %s %d", k.name, k.version)
		} else {
			fmt.sbprintfln(
				&sb,
				"state %s %d key=%v lane=%v max=%d write_through=%v priority=%d",
				k.name,
				k.version,
				k.key,
				k.lane,
				k.max_records,
				k.write_through,
				k.priority,
			)
		}
		for f in k.fields {
			fmt.sbprintf(&sb, "  field %s ", f.path)
			type_text(&sb, f.ti)
			if f.type == .String {fmt.sbprintf(&sb, "(max=%d)", f.max)}
			if f.acked {fmt.sbprint(&sb, " acked")}
			fmt.sbprintln(&sb)
		}
	}
	return strings.to_string(sb)
}

schema_hash :: proc(s: ^Schema) -> u64 {return s.hash}

// schema_lua writes the schema as a Lua table (tools/wireshark/voxiverse.lua
// decodes State and Snapshot messages from it).
schema_lua :: proc(s: ^Schema, sb: ^strings.Builder) {
	fmt.sbprintln(sb, "local SCHEMA = {")
	for k in s.kinds {
		key := "none" if k.is_event else fmt.tprintf("%v", k.key)
		lane := "event" if k.is_event else fmt.tprintf("%v", k.lane)
		fmt.sbprintfln(
			sb,
			"  {{ id = %d, name = %q, key = %q, lane = %q, fields = {{",
			k.id,
			k.name,
			strings.to_lower(key, context.temp_allocator),
			strings.to_lower(lane, context.temp_allocator),
		)
		for f in k.fields {
			fmt.sbprintf(sb, "    {{ name = %q, ", f.path)
			lua_type(sb, f.ti, f.max)
			fmt.sbprintln(sb, " },")
		}
		fmt.sbprintln(sb, "  } },")
	}
	fmt.sbprintln(sb, "}")
}

@(private = "file")
lua_type :: proc(sb: ^strings.Builder, ti: ^runtime.Type_Info, max: int) {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		fmt.sbprint(sb, `t = "bool"`)
	case runtime.Type_Info_Integer:
		fmt.sbprintf(sb, `t = "%s%d"`, "i" if v.signed else "u", base.size * 8)
	case runtime.Type_Info_Float:
		fmt.sbprintf(sb, `t = "f%d"`, base.size * 8)
	case runtime.Type_Info_Enum:
		fmt.sbprintf(sb, `t = "enum", signed = %v`, int_signed(base))
	case runtime.Type_Info_Bit_Set:
		fmt.sbprint(sb, `t = "bits"`)
	case runtime.Type_Info_Array:
		fmt.sbprintf(
			sb,
			`t = "array", scalar = %v, count = %d, elem = {{ `,
			scalar_type(runtime.type_info_base(v.elem)),
			v.count,
		)
		lua_type(sb, v.elem, 0)
		fmt.sbprint(sb, " }")
	case runtime.Type_Info_Enumerated_Array:
		fmt.sbprintf(
			sb,
			`t = "array", scalar = %v, count = %d, elem = {{ `,
			scalar_type(runtime.type_info_base(v.elem)),
			v.count,
		)
		lua_type(sb, v.elem, 0)
		fmt.sbprint(sb, " }")
	case runtime.Type_Info_Struct:
		fmt.sbprint(sb, `t = "struct", fields = { `)
		for i in 0 ..< int(v.field_count) {
			if v.names[i] == "_" {continue}
			fmt.sbprintf(sb, "{{ name = %q, ", v.names[i])
			lua_type(sb, v.types[i], 0)
			fmt.sbprint(sb, " }, ")
		}
		fmt.sbprint(sb, "}")
	case runtime.Type_Info_Union:
		fmt.sbprint(sb, `t = "union", variants = { `)
		for variant in v.variants {
			fmt.sbprint(sb, "{ ")
			lua_type(sb, variant, 0)
			fmt.sbprint(sb, " }, ")
		}
		fmt.sbprint(sb, "}")
	case runtime.Type_Info_String:
		fmt.sbprintf(sb, `t = "string", max = %d`, max)
	case:
		fmt.sbprint(sb, `t = "?"`)
	}
}

SCHEMA_LUA_BEGIN :: "-- schema begin (generated: ./build.sh schema)\n"
SCHEMA_LUA_END :: "-- schema end\n"

// schema_lua_splice puts block (schema_lua's output) between the markers of a
// Lua source; false if the markers are missing.
schema_lua_splice :: proc(
	source, block: string,
	allocator := context.temp_allocator,
) -> (
	result: string,
	ok: bool,
) {
	begin := strings.index(source, "-- schema begin")
	if begin < 0 {return}
	after_begin := strings.index_byte(source[begin:], '\n')
	end := strings.index(source, SCHEMA_LUA_END)
	if after_begin < 0 || end < 0 || end < begin {return}
	return strings.concatenate({source[:begin], SCHEMA_LUA_BEGIN, block, source[end:]}, allocator),
		true
}
