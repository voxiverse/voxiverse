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

// settings_command: `/<game> set <name> <value>` sets a setting when c holds the
// permission node and the value is in its bounds, and says so; `/<game> set` alone tells
// the settings and how to set them. handled false when the first argument is not `set`
// (the game's own commands, which may share a setting's name), changed true when one
// was set. A name that is no setting, a value out of its bounds, or a player without
// the node is refused and told why.
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
	name := s.config.game.name
	if len(args) >= 1 && args[0] == "set" {
		if len(args) != 3 {
			core.notice(
				s,
				c,
				fmt.tprintf(
					"%s: %s (%s)",
					name,
					settings_text(table, settings),
					settings_usage(table),
				),
			)
			return true, false
		}
		if _, known := base.var_find(table, args[1]); !known {
			core.notice(
				s,
				c,
				fmt.tprintf("%s: no setting %s (%s)", name, args[1], settings_usage(table)),
			)
			return true, false
		}
		return true, settings_set(s, c, table, settings, node, args[1], args[2])
	}
	return false, false
}

// settings_set: one setting set from its text, said or refused (true: it was set).
@(private = "file")
settings_set :: proc(
	s: ^core.Server,
	c: ^core.Client,
	table: base.Var_Table,
	settings: rawptr,
	node, setting, value: string,
) -> bool {
	v, _ := base.var_find(table, setting)
	name := s.config.game.name
	if !core.allowed(s, c, node) {
		core.notice(s, c, fmt.tprintf("You may not change %s's settings (%s)", name, node))
		return false
	}
	trial := scratch_copy(table, settings)
	if base.var_set(table, trial, setting, value) != .None {
		core.notice(s, c, fmt.tprintf("%s: %s", name, setting_usage(table, v)))
		return false
	}
	mem.copy(settings, trial, reflect.size_of_typeid(table.type))
	core.notice(
		s,
		c,
		fmt.tprintf(
			"%s: %s = %s (%s)",
			name,
			setting,
			base.var_format(table, settings, v),
			v.help,
		),
	)
	return true
}

// settings_usage: every setting as its command takes it, "set frags <1..200> | set time
// <30..3600>".
settings_usage :: proc(table: base.Var_Table) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for &v in table.vars {append(&parts, fmt.tprintf("set %s", setting_usage(table, &v)))}
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

// Saved_Line: a line of what a game keeps with the universe (game.cfg): its key, the
// first word (or what stands before an `=`), and the rest, trimmed: "best = 12" and
// "hero 3 140 7 ana" are {"best", "12"} and {"hero", "3 140 7 ana"}.
Saved_Line :: struct {
	key, value: string,
}

// saved_lines: the text's lines as keys and values (temp memory), blank lines and
// `#` comments left out.
saved_lines :: proc(text: string) -> []Saved_Line {
	out := make([dynamic]Saved_Line, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		cut := strings.index_any(l, "= \t")
		if cut < 0 {
			append(&out, Saved_Line{l, ""})
			continue
		}
		value := strings.trim_space(l[cut:])
		if strings.has_prefix(value, "=") {value = strings.trim_space(value[1:])}
		append(&out, Saved_Line{l[:cut], value})
	}
	return out[:]
}

// settings_read: what the universe kept (the game's load hook), its settings and the
// game's own lines together: the lines that name a setting are read into settings, and
// the rest are the game's (own, temp memory), in order. False, with no setting changed,
// for a value out of its bounds.
settings_read :: proc(
	table: base.Var_Table,
	settings: rawptr,
	text: string,
) -> (
	own: []Saved_Line,
	ok: bool,
) {
	mine := strings.builder_make(context.temp_allocator)
	rest := make([dynamic]Saved_Line, context.temp_allocator)
	for l in saved_lines(text) {
		if _, known := base.var_find(table, l.key); known {
			fmt.sbprintfln(&mine, "%s = %s", l.key, l.value)
		} else {
			append(&rest, l)
		}
	}
	if !settings_load(table, settings, strings.to_string(mine)) {return nil, false}
	return rest[:], true
}

// settings_load: settings from "name = value" lines; false, with nothing changed, for a
// line that names none or a value out of its bounds.
@(private = "package")
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
