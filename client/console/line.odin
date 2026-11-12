package console

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "client:engine"
import "client:screen"
import "common:base"
import "common:game"

// The console's command line (a Line_Editor, line_edit.odin): Tab
// completes commands and their arguments; the history is saved between
// runs.

// console_candidates: Tab's candidates on the console's line: a command,
// then what its arguments can be.
@(private)
console_candidates :: proc(app: ^engine.App, before: []string) -> []string {
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
	settings, ok := engine.settings_path()
	if !ok {return "", false}
	path, err := filepath.join(
		{filepath.dir(settings), "console_history.txt"},
		context.temp_allocator,
	)
	return path, err == nil
}

console_history_load :: proc(c: ^engine.Console) {
	path, ok := history_path()
	if !ok {return}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {engine.line_remember(&c.line, line)}
}

console_history_save :: proc(c: ^engine.Console) {
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
complete_variables :: proc(app: ^engine.App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if arg == 0 {
		for v in engine.app_variables(app) {
			for &var in v.table.vars {append(&names, base.var_name(v.table, &var))}
		}
		if app.session == nil {
			t := game.rules_table()
			for &var in t.vars {append(&names, base.var_name(t, &var))}
		}
	} else if arg == 1 && len(args) > 0 {
		// A switch: its two values.
		for v in engine.app_variables(app) {
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

// The words complete_screen and complete_vars offer: globals, as the slices
// they return outlive the call (a literal in the procedure would be on its stack).
@(private = "file")
SCREEN_WORDS := []string {
	"title",
	"game",
	"menu",
	"inventory",
	"stats",
	"options",
	"universes",
	"multiplayer",
	"quit",
}
@(private = "file")
VAR_WORDS := []string{"rules.", "debug.", "telemetry."}

@(private)
complete_screen :: proc(app: ^engine.App, arg: int, args: []string) -> []string {
	return complete_first(arg, SCREEN_WORDS)
}

@(private)
complete_vars :: proc(app: ^engine.App, arg: int, args: []string) -> []string {
	return complete_first(arg, VAR_WORDS)
}

@(private)
complete_command :: proc(app: ^engine.App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if arg == 0 {for cmd in app.console.commands {append(&names, cmd.name)}}
	return names[:]
}

@(private)
complete_world :: proc(app: ^engine.App, arg: int, args: []string) -> []string {
	if arg != 0 {return nil}
	names := make([dynamic]string, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(screen.saves_dir(), context.temp_allocator)
	if err != nil {return nil}
	for e in entries {
		if e.type == .Directory && !strings.contains(e.name, " ") {append(&names, e.name)}
	}
	return names[:]
}
