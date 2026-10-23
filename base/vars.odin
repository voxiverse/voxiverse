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
// Supported field types: bool, i32, int, f32.

Var :: struct {
	field:    string, // struct field name; also the console name
	help:     string,
	label:    string, // for menus; empty: made from the field name
	min, max: f64, // numbers: allowed range
	step:     f64, // numbers: slider step (0 = continuous, ints use 1)
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
	case:
		panic("unsupported variable type")
	}
	return kind, f.offset
}

// var_get_f64 reads a variable as a number (bools are 0 or 1).
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
	}
	return 0
}

// var_set_f64 writes a number, clamped to the range (rounded for ints).
var_set_f64 :: proc(t: Var_Table, data: rawptr, v: ^Var, value: f64) -> Var_Error {
	kind, offset := var_kind(t, v)
	p := rawptr(uintptr(data) + offset)
	value := value
	err := Var_Error.None
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
	}
	return err
}

// var_set parses text for the variable named name.
var_set :: proc(t: Var_Table, data: rawptr, name: string, value_text: string) -> Var_Error {
	v, found := var_find(t, name)
	if !found {return .Unknown_Name}
	kind, _ := var_kind(t, v)
	text := strings.trim_space(value_text)
	value: f64
	switch kind {
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
	kind, _ := var_kind(t, v)
	value := var_get_f64(t, data, v)
	switch kind {
	case .Bool:
		return "true" if value != 0 else "false"
	case .Int:
		return fmt.aprintf("%d", i64(value), allocator = allocator)
	case .F32:
		return fmt.aprintf("%g", f32(value), allocator = allocator)
	}
	return ""
}

var_reset :: proc(t: Var_Table, data: rawptr, v: ^Var) {
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
		if kind != .Bool {
			if v.min > v.max {ok = false}
			d := var_get_f64(t, t.defaults, &v)
			if d < v.min || d > v.max {ok = false}
		}
	}
	return ok
}
