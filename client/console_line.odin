package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../base"
import "../common/game"

// The console's command line (a Line_Editor, line_edit.odin): Tab
// completes commands and their arguments; the history is saved between
// runs.

// console_candidates: Tab's candidates on the console's line: a command,
// then what its arguments can be.
@(private)
console_candidates :: proc(app: ^App, before: []string) -> []string {
	c := &app.console
	// A slash line: server commands (the names the server sent), then players.
	if line := string(c.line.text[:]); strings.has_prefix(line, "/") {
		names := make([dynamic]string, context.temp_allocator)
		s := app.session
		if s == nil {return nil}
		if len(before) == 0 {
			for name in s.commands {append(&names, strings.concatenate({"/", name}, context.temp_allocator))}
		} else {
			append(&names, s.config.name)
			for _, o in s.others {append(&names, o.name)}
			append(&names, "@s", "@p", "@a", "@r")
		}
		return names[:]
	}
	if len(before) == 0 {
		names := make([dynamic]string, context.temp_allocator)
		for cmd in c.commands {append(&names, cmd.name)}
		return names[:]
	}
	for cmd in c.commands {
		if cmd.name == before[0] && cmd.complete != nil {
			return cmd.complete(app, len(before) - 1, before[1:])
		}
	}
	return nil
}

// History file: beside the settings file.
@(private = "file")
history_path :: proc() -> (string, bool) {
	settings, ok := settings_path()
	if !ok {return "", false}
	path, err := filepath.join(
		{filepath.dir(settings), "console_history.txt"},
		context.temp_allocator,
	)
	return path, err == nil
}

console_history_load :: proc(c: ^Console) {
	path, ok := history_path()
	if !ok {return}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {line_remember(&c.line, line)}
}

console_history_save :: proc(c: ^Console) {
	path, ok := history_path()
	if !ok || len(c.line.history) == 0 {return}
	b := strings.builder_make(context.temp_allocator)
	for h in c.line.history {fmt.sbprintln(&b, h)}
	if err := os.write_entire_file(path, b.buf[:]); err != nil {
		log.warnf("console cannot save its history path=%s error=%v", path, err)
	}
}

// --- What each command's arguments can be (for Tab) ------------------------

@(private)
complete_variables :: proc(app: ^App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if arg == 0 {
		for v in app_variables(app) {
			for &var in v.table.vars {append(&names, base.var_name(v.table, &var))}
		}
		if app.session == nil {
			t := game.rules_table()
			for &var in t.vars {append(&names, base.var_name(t, &var))}
		}
	} else if arg == 1 && len(args) > 0 {
		// A switch: its two values.
		for v in app_variables(app) {
			if var, ok := base.var_find(v.table, args[0]); ok {
				if kind, _ := base.var_kind(v.table, var);
				   kind == .Bool {append(&names, "true", "false")}
			}
		}
	}
	return names[:]
}

@(private)
complete_first :: proc(arg: int, words: []string) -> []string {
	return words if arg == 0 else nil
}

@(private)
complete_time :: proc(app: ^App, arg: int, args: []string) -> []string {
	return complete_first(arg, {"sunrise", "day", "noon", "sunset", "night", "midnight"})
}

@(private)
complete_screen :: proc(app: ^App, arg: int, args: []string) -> []string {
	return complete_first(
		arg,
		{
			"title",
			"game",
			"menu",
			"inventory",
			"stats",
			"options",
			"worlds",
			"multiplayer",
			"quit",
		},
	)
}

@(private)
complete_vars :: proc(app: ^App, arg: int, args: []string) -> []string {
	return complete_first(arg, {"rules.", "debug.", "telemetry."})
}

@(private)
complete_block :: proc(app: ^App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if arg == 0 {
		for def in app.session.reg.blocks.types {
			if game.can_place(&app.session.reg.blocks, def.default) {
				append(&names, game.block_name(app.session.reg, def.default))
			}
		}
	}
	return names[:]
}

@(private)
complete_command :: proc(app: ^App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if arg == 0 {for cmd in app.console.commands {append(&names, cmd.name)}}
	return names[:]
}

@(private)
complete_world :: proc(app: ^App, arg: int, args: []string) -> []string {
	if arg != 0 {return nil}
	names := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(saves_dir(), context.temp_allocator)
	if err != nil {return nil}
	for e in entries {
		if e.type == .Directory && !strings.contains(e.name, " ") {append(&names, e.name)}
	}
	return names[:]
}

@(private)
complete_block_or_air :: proc(app: ^App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for def in app.session.reg.blocks.types {
		b := def.default
		if b == .Air || game.can_place(&app.session.reg.blocks, b) {
			append(&names, game.block_name(app.session.reg, b))
		}
	}
	return names[:]
}

@(private)
complete_sphere :: proc(app: ^App, arg: int, args: []string) -> []string {
	return complete_block_or_air(app, 0, nil) if arg == 1 else nil
}
