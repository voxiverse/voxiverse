package game

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"

// A game's data on an entity: a small record of the game's own type (core.Game.entity_data)
// that every entity of the game's kinds carries (server/core: entity_data). The server
// keeps it as bytes and saves it with the world as text, a `name=value` per field (the
// fields of nested structs and arrays by dotted paths: `data.home`, `data.pos.x`,
// `data.slots.2`), so a game may add, drop or reorder fields and still read its saves: a
// field the line lacks is zero, a name the type lacks is reported.

//
// A game's data on a character (core.Game.character_data) is a record of the same kind,
// bigger (MAX_CHARACTER_DATA), kept with the character and saved in its file the same way,
// a field by its path (data_fields, data_fields_read).

MAX_ENTITY_DATA :: 64 // bytes
MAX_CHARACTER_DATA :: 4096 // bytes

Entity_Data :: struct #align (8) {
	bytes: [MAX_ENTITY_DATA]u8,
}

Character_Data :: struct #align (8) {
	bytes: [MAX_CHARACTER_DATA]u8,
}

// entity_data_plain: why a type cannot be a game's entity data ("" when it can): it fits
// MAX_ENTITY_DATA and holds numbers, booleans, enums, bit sets and fixed arrays and
// structs of them; no pointer, slice, string or map, which a save could not hold.
entity_data_plain :: proc(T: typeid) -> string {return data_plain(T, MAX_ENTITY_DATA)}

// character_data_plain: as entity_data_plain, for a game's data on a character (at most
// MAX_CHARACTER_DATA bytes).
character_data_plain :: proc(T: typeid) -> string {return data_plain(T, MAX_CHARACTER_DATA)}

// machine_data_plain, machine_shown_plain: as entity_data_plain, for a game's record on its
// machines and what they show (block_entity.odin).
machine_data_plain :: proc(T: typeid) -> string {return data_plain(T, MAX_MACHINE_DATA)}
machine_shown_plain :: proc(T: typeid) -> string {return data_plain(T, MAX_MACHINE_SHOWN)}

@(private = "file")
data_plain :: proc(T: typeid, most: int) -> string {
	ti := type_info_of(T)
	if ti.size > most {
		return fmt.tprintf("%v is %d bytes; at most %d", T, ti.size, most)
	}
	if ti.align > 8 {return fmt.tprintf("%v is aligned to %d; at most 8", T, ti.align)}
	if !plain(
		ti,
	) {return fmt.tprintf("%v holds what a save cannot (a pointer, slice, string, map or union)", T)}
	return ""
}

@(private = "file")
plain :: proc(ti: ^reflect.Type_Info) -> bool {
	#partial switch v in reflect.type_info_base(ti).variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Float, reflect.Type_Info_Boolean:
		return true
	case reflect.Type_Info_Enum:
		return true
	case reflect.Type_Info_Bit_Set:
		return true
	case reflect.Type_Info_Array:
		return plain(v.elem)
	case reflect.Type_Info_Struct:
		for i in 0 ..< v.field_count {if !plain(v.types[i]) {return false}}
		return true
	}
	return false
}

// Data_Leaf: one number of a record: its dotted path, where it is and what it is.
@(private = "file")
Data_Leaf :: struct {
	path:   string,
	offset: uintptr,
	type:   ^reflect.Type_Info,
}

@(private = "file")
leaves :: proc(ti: ^reflect.Type_Info, path: string, offset: uintptr, out: ^[dynamic]Data_Leaf) {
	#partial switch v in reflect.type_info_base(ti).variant {
	case reflect.Type_Info_Array:
		for i in 0 ..< v.count {
			leaves(v.elem, fmt.tprintf("%s.%d", path, i), offset + uintptr(i * v.elem_size), out)
		}
	case reflect.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			name := v.names[i]
			if name == "_" {continue}
			leaves(v.types[i], fmt.tprintf("%s.%s", path, name), offset + v.offsets[i], out)
		}
	case:
		append(out, Data_Leaf{path, offset, ti})
	}
}

// entity_data_write writes each field of the record at data (of type T) as
// ` <prefix>.<path>=<value>`, leaving out those at zero (a line stays short).
entity_data_write :: proc(b: ^strings.Builder, T: typeid, data: rawptr, prefix: string) {
	for f in data_fields(T, data) {fmt.sbprintf(b, " %s.%s=%s", prefix, f.path, f.text)}
}

// Data_Field: one field of a record as text: its dotted path (`cash`, `seen.3.price`) and
// its value (a number, `true` or `false`, an enum by its name, a bit set as its bits).
Data_Field :: struct {
	path, text: string,
}

// data_fields: the fields of the record at data (of type T) that are not zero, in the
// type's order (temporary memory).
data_fields :: proc(T: typeid, data: rawptr) -> []Data_Field {
	list := make([dynamic]Data_Leaf, context.temp_allocator)
	leaves(type_info_of(T), "", 0, &list)
	out := make([dynamic]Data_Field, 0, len(list), context.temp_allocator)
	for l in list {
		p := rawptr(uintptr(data) + l.offset)
		zero := true
		for b in ([^]u8)(p)[:l.type.size] {if b != 0 {zero = false}}
		if zero {continue}
		text: string
		if _, is_set := reflect.type_info_base(l.type).variant.(reflect.Type_Info_Bit_Set);
		   is_set {
			text = fmt.tprintf("%d", bits_of(p, l.type.size))
		} else {
			text = fmt.tprintf("%v", any{p, l.type.id})
		}
		append(&out, Data_Field{l.path[1:], text})
	}
	return out[:]
}

// data_fields_read sets the fields of the record at data (of type T) from their text, each
// found by its path once (a record of thousands of fields reads in one pass). A path the
// type lacks or a text that is not one of its field's values is skipped; bad names the
// first such path ("": none).
data_fields_read :: proc(T: typeid, data: rawptr, fields: []Data_Field) -> (bad: string) {
	list := make([dynamic]Data_Leaf, context.temp_allocator)
	leaves(type_info_of(T), "", 0, &list)
	by_path := make(map[string]Data_Leaf, len(list), context.temp_allocator)
	for l in list {by_path[l.path[1:]] = l}
	for f in fields {
		l, known := by_path[f.path]
		if !(known && leaf_read(l, rawptr(uintptr(data) + l.offset), f.text)) && bad == "" {
			bad = f.path
		}
	}
	return
}

@(private = "file")
bits_of :: proc(p: rawptr, size: int) -> (n: u64) {
	bytes := ([^]u8)(p)[:size]
	for i := size - 1; i >= 0; i -= 1 {n = n << 8 | u64(bytes[i])}
	return
}

// entity_data_read sets the field named path (dotted, after the prefix) of the record at
// data (of type T) from its text; false when T has no such field or the text is not one
// of its values.
entity_data_read :: proc(T: typeid, data: rawptr, path, text: string) -> bool {
	list := make([dynamic]Data_Leaf, context.temp_allocator)
	leaves(type_info_of(T), "", 0, &list)
	for l in list {
		if l.path[1:] == path {return leaf_read(l, rawptr(uintptr(data) + l.offset), text)}
	}
	return false
}

// leaf_read sets one number of a record from its text; false when the text is not one of
// its values.
@(private = "file")
leaf_read :: proc(l: Data_Leaf, p: rawptr, text: string) -> bool {
	#partial switch v in reflect.type_info_base(l.type).variant {
	case reflect.Type_Info_Integer:
		if v.signed {
			n := strconv.parse_i64(text) or_return
			lo := -(i64(1) << uint(8 * l.type.size - 1))
			hi := (i64(1) << uint(8 * l.type.size - 1)) - 1
			if l.type.size < 8 && (n < lo || n > hi) {return false}
			set_bytes(p, u64(n), l.type.size)
		} else {
			n := strconv.parse_u64(text) or_return
			if l.type.size < 8 && n >> uint(8 * l.type.size) != 0 {return false}
			set_bytes(p, n, l.type.size)
		}
	case reflect.Type_Info_Float:
		f := strconv.parse_f64(text) or_return
		switch l.type.size {
		case 4:
			(^f32)(p)^ = f32(f)
		case 8:
			(^f64)(p)^ = f
		case:
			return false
		}
	case reflect.Type_Info_Boolean:
		switch text {
		case "true":
			([^]u8)(p)[0] = 1
		case "false":
			([^]u8)(p)[0] = 0
		case:
			return false
		}
	case reflect.Type_Info_Enum:
		for name, i in v.names {
			if name == text {
				set_bytes(p, u64(v.values[i]), l.type.size)
				return true
			}
		}
		return false
	case reflect.Type_Info_Bit_Set:
		n := strconv.parse_u64(text) or_return
		if l.type.size < 8 && n >> uint(8 * l.type.size) != 0 {return false}
		set_bytes(p, n, l.type.size)
	case:
		return false
	}
	return true
}

@(private = "file")
set_bytes :: proc(p: rawptr, n: u64, size: int) {
	bytes := ([^]u8)(p)[:size]
	for i in 0 ..< size {bytes[i] = u8(n >> uint(8 * i))}
}
