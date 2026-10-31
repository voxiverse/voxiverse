package base

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"

// Variables: tunable fields of ordinary structs (client settings, game
// rules, debug switches). Code reads and writes the fields directly; a
// Var_Table describes them once (console name, help, range) so the console,
// the tuning panel and settings files can reach them by name. Field types
// and offsets come from reflection, so the table never restates them.
//
//	Settings :: struct {sensitivity: f32, fov: f32}
//	SETTINGS_DEFAULTS :: Settings{sensitivity = 1, fov = 70}
//	@(rodata) SETTINGS_VARS := [?]base.Var{
//		{field = "sensitivity", help = "mouse look speed", min = 0.1, max = 5},
//		{field = "fov", help = "vertical field of view, degrees", min = 50, max = 110},
//	}
//	table := base.Var_Table{"", Settings, SETTINGS_VARS[:], &defaults}
//	base.var_set(table, &settings, "fov", "90")
//
// Supported field types: bool, i32, int, f32, Var_Text, and enums (named by
// their values' names, in lower case).

Var :: struct {
	field:    string, // struct field name; also the console name
	help:     string,
	label:    string, // for menus; empty: made from the field name
	min, max: f64, // numbers: allowed range
	step:     f64, // numbers: slider step (0 = continuous, ints use 1)
	check:    proc(text: string) -> bool, // text: what is allowed (nil: anything that fits)
	hint:     string, // text: shown in an empty field
	choices:  []Var_Choice, // menus: the values offered, in order (none: a slider or a box)
	special:  []Var_Choice, // sliders: values shown in words (-1 "Off"); the value is unchanged
}

// Var_Choice: one value a menu offers, and what it calls it.
Var_Choice :: struct {
	value: f64,
	label: string,
}

// Var_Text: a text variable's value, stored in place (settings stay plain
// values: copied, compared and saved like the rest).
Var_Text :: struct {
	len: u8,
	buf: [VAR_TEXT_MAX]u8,
}

VAR_TEXT_MAX :: 48

var_text :: proc(t: ^Var_Text) -> string {
	return string(t.buf[:t.len])
}

// var_text_set stores s; false (unchanged) if it does not fit.
var_text_set :: proc(t: ^Var_Text, s: string) -> bool {
	if len(s) > VAR_TEXT_MAX {return false}
	t.len = u8(copy(t.buf[:], s))
	return true
}

Var_Table :: struct {
	prefix:   string, // console names are prefix + field ("debug.", "rules.", "")
	type:     typeid,
	vars:     []Var,
	defaults: rawptr, // a ^type with the default values
}

Var_Kind :: enum u8 {
	Bool,
	Int,
	F32,
	Text,
	Enum,
}

Var_Error :: enum u8 {
	None,
	Unknown_Name,
	Bad_Value, // not parseable as the variable's type
	Out_Of_Range, // clamped into range
}

// var_find returns the variable named name (prefix included).
var_find :: proc(t: Var_Table, name: string) -> (v: ^Var, ok: bool) {
	if !strings.has_prefix(name, t.prefix) {return nil, false}
	field := name[len(t.prefix):]
	for &v in t.vars {
		if v.field == field {return &v, true}
	}
	return nil, false
}

var_name :: proc(t: Var_Table, v: ^Var, allocator := context.temp_allocator) -> string {
	return strings.concatenate({t.prefix, v.field}, allocator)
}

// var_kind looks up the field's type; asserts it exists and is supported
// (a table naming a missing field is a programming error: the table test
// checks every table).
var_kind :: proc(t: Var_Table, v: ^Var) -> (kind: Var_Kind, offset: uintptr) {
	f := reflect.struct_field_by_name(t.type, v.field)
	assert(f.type != nil, "variable names a field the struct does not have")
	switch f.type.id {
	case bool:
		kind = .Bool
	case i32, int:
		kind = .Int
	case f32:
		kind = .F32
	case Var_Text:
		kind = .Text
	case:
		if !reflect.is_enum(f.type) {panic("unsupported variable type")}
		kind = .Enum
	}
	return kind, f.offset
}

// var_get_f64 reads a variable as a number (bools are 0 or 1; texts 0).
var_get_f64 :: proc(t: Var_Table, data: rawptr, v: ^Var) -> f64 {
	kind, offset := var_kind(t, v)
	p := rawptr(uintptr(data) + offset)
	f := reflect.struct_field_by_name(t.type, v.field)
	switch kind {
	case .Bool:
		return 1 if (^bool)(p)^ else 0
	case .Int:
		if f.type.id == i32 {return f64((^i32)(p)^)}
		return f64((^int)(p)^)
	case .F32:
		return f64((^f32)(p)^)
	case .Enum:
		value, _ := reflect.as_i64(any{p, f.type.id})
		return f64(value)
	case .Text:
	}
	return 0
}

// var_set_f64 writes a number, clamped to the range (rounded for ints).
var_set_f64 :: proc(t: Var_Table, data: rawptr, v: ^Var, value: f64) -> Var_Error {
	kind, offset := var_kind(t, v)
	p := rawptr(uintptr(data) + offset)
	value := value
	err := Var_Error.None
	if kind == .Text {return .Bad_Value}
	if kind == .Enum {
		f := reflect.struct_field_by_name(t.type, v.field)
		if _, named := enum_name(f.type, value); !named {return .Bad_Value}
		switch f.type.size {
		case 1:
			(^u8)(p)^ = u8(i64(value))
		case 2:
			(^u16)(p)^ = u16(i64(value))
		case 4:
			(^u32)(p)^ = u32(i64(value))
		case:
			(^u64)(p)^ = u64(i64(value))
		}
		return .None
	}
	if kind != .Bool && (value < v.min || value > v.max) {
		value = clamp(value, v.min, v.max)
		err = .Out_Of_Range
	}
	switch kind {
	case .Bool:
		(^bool)(p)^ = value != 0
	case .Int:
		if reflect.struct_field_by_name(t.type, v.field).type.id == i32 {
			(^i32)(p)^ = i32(math.round(value))
		} else {
			(^int)(p)^ = int(math.round(value))
		}
	case .F32:
		(^f32)(p)^ = f32(value)
	case .Text, .Enum:
	}
	return err
}

// var_set parses text for the variable named name.
var_set :: proc(t: Var_Table, data: rawptr, name: string, value_text: string) -> Var_Error {
	v, found := var_find(t, name)
	if !found {return .Unknown_Name}
	kind, offset := var_kind(t, v)
	text := strings.trim_space(value_text)
	value: f64
	switch kind {
	case .Text:
		if v.check != nil && !v.check(text) {return .Bad_Value}
		if !var_text_set((^Var_Text)(uintptr(data) + offset), text) {return .Bad_Value}
		return .None
	case .Bool:
		switch text {
		case "1", "true", "on", "yes":
			value = 1
		case "0", "false", "off", "no":
			value = 0
		case:
			return .Bad_Value
		}
	case .Int, .F32:
		ok: bool
		if value, ok = strconv.parse_f64(text); !ok || math.is_nan(value) || math.is_inf(value) {
			return .Bad_Value
		}
	case .Enum:
		f := reflect.struct_field_by_name(t.type, v.field)
		info := reflect.type_info_base(f.type).variant.(reflect.Type_Info_Enum)
		named := false
		for n, i in info.names {
			if strings.equal_fold(n, text) {
				value, named = f64(info.values[i]), true
				break
			}
		}
		if !named {return .Bad_Value}
	}
	return var_set_f64(t, data, v, value)
}

// var_format renders the variable's value as var_set reads it.
var_format :: proc(
	t: Var_Table,
	data: rawptr,
	v: ^Var,
	allocator := context.temp_allocator,
) -> string {
	kind, offset := var_kind(t, v)
	value := var_get_f64(t, data, v)
	switch kind {
	case .Text:
		return strings.clone(var_text((^Var_Text)(uintptr(data) + offset)), allocator)
	case .Bool:
		return "true" if value != 0 else "false"
	case .Int:
		return fmt.aprintf("%d", i64(value), allocator = allocator)
	case .F32:
		return fmt.aprintf("%g", f32(value), allocator = allocator)
	case .Enum:
		name, _ := enum_name(reflect.struct_field_by_name(t.type, v.field).type, value)
		return strings.to_lower(name, allocator)
	}
	return ""
}

// enum_name: the name of an enum type's value (false: it has none).
@(private = "file")
enum_name :: proc(type: ^reflect.Type_Info, value: f64) -> (string, bool) {
	info := reflect.type_info_base(type).variant.(reflect.Type_Info_Enum)
	for v, i in info.values {
		if f64(v) == value {return info.names[i], true}
	}
	return "", false
}

// var_choice: the choice nearest the variable's value (menus); false if it
// offers none.
var_choice :: proc(t: Var_Table, data: rawptr, v: ^Var) -> (index: int, ok: bool) {
	if len(v.choices) == 0 {return 0, false}
	value := var_get_f64(t, data, v)
	for c, i in v.choices {
		if abs(c.value - value) < abs(v.choices[index].value - value) {index = i}
	}
	return index, true
}

var_reset :: proc(t: Var_Table, data: rawptr, v: ^Var) {
	kind, offset := var_kind(t, v)
	if kind == .Text {
		(^Var_Text)(uintptr(data) + offset)^ = (^Var_Text)(uintptr(t.defaults) + offset)^
		return
	}
	var_set_f64(t, data, v, var_get_f64(t, t.defaults, v))
}

// vars_write renders every variable as "name = value" lines with the help
// as comments: a settings file.
vars_write :: proc(t: Var_Table, data: rawptr, b: ^strings.Builder) {
	for &v in t.vars {
		fmt.sbprintfln(b, "# %s", v.help)
		fmt.sbprintfln(b, "%s = %s", var_name(t, &v), var_format(t, data, &v))
	}
}

// Var_File_Problem is one line of a settings file that was not applied as
// written (unknown name, bad value, clamped).
Var_File_Problem :: struct {
	line:  int,
	text:  string,
	error: Var_Error,
}

// vars_read applies "name = value" lines (blank lines and # comments
// skipped). Lines that don't apply cleanly are returned; the rest are
// applied, so one bad line does not lose the others.
vars_read :: proc(
	t: Var_Table,
	data: rawptr,
	text: string,
	allocator := context.temp_allocator,
) -> []Var_File_Problem {
	problems := make([dynamic]Var_File_Problem, allocator)
	rest := text
	line_number := 0
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		s := strings.trim_space(line)
		if s == "" || s[0] == '#' {continue}
		eq := strings.index_byte(s, '=')
		if eq < 0 {
			append(&problems, Var_File_Problem{line_number, line, .Bad_Value})
			continue
		}
		name := strings.trim_space(s[:eq])
		if err := var_set(t, data, name, s[eq + 1:]); err != .None {
			append(&problems, Var_File_Problem{line_number, line, err})
		}
	}
	return problems[:]
}

// var_table_check asserts that every variable names a supported field and
// that the defaults are in range (call from a test for every table).
var_table_check :: proc(t: Var_Table) -> bool {
	ok := true
	for &v in t.vars {
		kind, _ := var_kind(t, &v)
		if kind == .Int || kind == .F32 {
			if v.min > v.max {ok = false}
			d := var_get_f64(t, t.defaults, &v)
			if d < v.min || d > v.max {ok = false}
		}
	}
	return ok
}
