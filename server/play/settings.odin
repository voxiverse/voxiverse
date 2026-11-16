package play

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

import "common:base"
import "server:core"

// A game's settings: the numbers its admin may change (a match's frag limit, a run's
// lives), a plain struct of its own described once by a base.Var_Table (each field's
// name, help and bounds), which gives the command that sets them, the text kept with the
// universe and the reading of it back.
//
//	Settings :: struct {frags: int, time: int}
//	@(rodata) SETTINGS_VARS := [?]base.Var{{field = "frags", help = "the first to this many wins", min = 1, max = 200}, ...}
//	SETTINGS :: base.Var_Table{"", Settings, SETTINGS_VARS[:], &DEFAULT_SETTINGS}

// settings_command: `/<game> <name> <value>` sets a setting when c holds the permission
// node and the value is in its bounds, and says so; handled false when args name no
// setting (the game's other commands), changed true when one was set. A value out of
// its bounds, or a player without the node, is refused and told why.
settings_command :: proc(
	s: ^core.Server,
	c: ^core.Client,
	table: base.Var_Table,
	settings: rawptr,
	node: string,
	args: []string,
) -> (
	handled, changed: bool,
) {
	if len(args) != 2 {return false, false}
	v, known := base.var_find(table, args[0])
	if !known {return false, false}
	name := s.config.game.name
	if !core.allowed(s, c, node) {
		core.notice(s, c, fmt.tprintf("You may not change %s's settings (%s)", name, node))
		return true, false
	}
	trial := scratch_copy(table, settings)
	if base.var_set(table, trial, args[0], args[1]) != .None {
		core.notice(s, c, fmt.tprintf("%s: %s", name, setting_usage(table, v)))
		return true, false
	}
	mem.copy(settings, trial, reflect.size_of_typeid(table.type))
	core.notice(
		s,
		c,
		fmt.tprintf(
			"%s: %s = %s (%s)",
			name,
			args[0],
			base.var_format(table, settings, v),
			v.help,
		),
	)
	return true, true
}

// settings_usage: every setting as its command takes it, "frags <1..200> | time <30..3600>".
settings_usage :: proc(table: base.Var_Table) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for &v in table.vars {append(&parts, setting_usage(table, &v))}
	return strings.join(parts[:], " | ", context.temp_allocator)
}

// settings_text: every setting and its value, "frags 15, time 300".
settings_text :: proc(table: base.Var_Table, settings: rawptr) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for &v in table.vars {
		append(&parts, fmt.tprintf("%s %s", v.field, base.var_format(table, settings, &v)))
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// settings_save: the settings as the universe keeps them (the game's save hook):
// "name = value" lines, each under its help as a comment.
settings_save :: proc(table: base.Var_Table, settings: rawptr, out: ^strings.Builder) {
	base.vars_write(table, settings, out)
}

// settings_load: the settings the universe kept (the game's load hook); false, with
// nothing changed, for a line that names none or a value out of its bounds.
settings_load :: proc(table: base.Var_Table, settings: rawptr, text: string) -> bool {
	trial := scratch_copy(table, settings)
	if len(base.vars_read(table, trial, text)) > 0 {return false}
	mem.copy(settings, trial, reflect.size_of_typeid(table.type))
	return true
}

@(private = "file")
setting_usage :: proc(table: base.Var_Table, v: ^base.Var) -> string {
	kind, _ := base.var_kind(table, v)
	#partial switch kind {
	case .Int:
		return fmt.tprintf("%s <%d..%d>", v.field, i64(v.min), i64(v.max))
	case .F32:
		return fmt.tprintf("%s <%g..%g>", v.field, v.min, v.max)
	case .Bool:
		return fmt.tprintf("%s <on|off>", v.field)
	}
	return fmt.tprintf("%s <value>", v.field)
}

// scratch_copy: a copy of the settings to try a change on (temp memory).
@(private = "file")
scratch_copy :: proc(table: base.Var_Table, settings: rawptr) -> rawptr {
	size := reflect.size_of_typeid(table.type)
	trial, _ := mem.alloc(size, type_info_of(table.type).align, context.temp_allocator)
	mem.copy(trial, settings, size)
	return trial
}
