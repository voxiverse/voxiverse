package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../base"
import "../game"
import "../ui"

// The console's command line, beyond the editing every text field has
// (ui/widgets.odin): Tab completion, history (Up/Down or Ctrl+P/N, saved
// between runs), reverse search (Ctrl+R), Ctrl+L to clear the console and
// Ctrl+C to clear the line.

HISTORY_MAX :: 500

Console_Line_State :: struct {
	browsing:  int, // index into history while walking it; -1: editing the draft
	draft:     [dynamic]u8, // the line being written before walking the history
	searching: bool, // Ctrl+R
	query:     [dynamic]u8,
	found:     int, // the history line the search shows; -1: none
}

// complete_word: what Tab does to the word before the cursor, given the
// candidates for its place. The word is completed when one candidate fits
// (plus a space), extended to what all that fit share, or, when that adds
// nothing, the candidates that fit are returned to be shown.
complete_word :: proc(
	word: string,
	candidates: []string,
	allocator := context.temp_allocator,
) -> (
	completed: string,
	choices: []string,
) {
	fits := make([dynamic]string, allocator)
	for c in candidates {if strings.has_prefix(c, word) {append(&fits, c)}}
	slice.sort(fits[:])
	switch len(fits) {
	case 0:
		return word, nil
	case 1:
		return strings.concatenate({fits[0], " "}, allocator), nil
	}
	shared := fits[0]
	for f in fits[1:] {
		n := 0
		for n < len(shared) && n < len(f) && shared[n] == f[n] {n += 1}
		shared = shared[:n]
	}
	if len(shared) > len(word) {return shared, nil}
	return word, fits[:]
}

// console_tab completes the word before the cursor of the console's line.
@(private)
console_tab :: proc(app: ^App, e: ^ui.Text_Edit) {
	c := &app.console
	line := string(c.input[:])
	cursor := clamp(e.cursor, 0, len(line))
	start := strings.last_index_byte(line[:cursor], ' ') + 1
	word := line[start:cursor]
	before := strings.fields(line[:start], context.temp_allocator)
	candidates: []string
	if len(before) == 0 {
		names := make([dynamic]string, context.temp_allocator)
		for cmd in c.commands {append(&names, cmd.name)}
		candidates = names[:]
	} else {
		for cmd in c.commands {
			if cmd.name == before[0] && cmd.complete != nil {
				candidates = cmd.complete(app, len(before) - 1, before[1:])
			}
		}
	}
	completed, choices := complete_word(word, candidates)
	if len(choices) > 0 {
		console_print(c, strings.join(choices, "   ", context.temp_allocator), .Debug)
		return
	}
	if completed == word {return}
	// Replace the word (and a space already after the cursor is not doubled).
	rest := line[cursor:]
	if strings.has_suffix(completed, " ") && strings.has_prefix(rest, " ") {
		completed = completed[:len(completed) - 1]
	}
	new_line := strings.concatenate({line[:start], completed, rest}, context.temp_allocator)
	clear(&c.input)
	append(&c.input, new_line)
	e.cursor = start + len(completed)
	e.anchor = e.cursor
}

// console_line_keys handles the console's own keys this frame, before the
// line edits itself (the keys it takes, the line does not see).
@(private)
console_line_keys :: proc(app: ^App, ctx: ^ui.Context) {
	c := &app.console
	st := &c.line
	keys := ctx.input.keys_pressed
	ctrl := .Ctrl in ctx.input.modifiers && .Alt not_in ctx.input.modifiers
	e := &ctx.edit
	take :: proc(ctx: ^ui.Context, k: ui.Key) {ctx.input.keys_pressed -= {k}}

	if st.searching {
		switch {
		case ctrl && .R in keys:
			// The next older match.
			st.found = search_history(c, string(st.query[:]), st.found - 1)
			take(ctx, .R)
		case ctrl && .G in keys, ctrl && .C in keys:
			search_end(c, false, e)
			take(ctx, .G)
			take(ctx, .C)
		case .Left in keys, .Right in keys, ctrl && (.A in keys || .E in keys):
			search_end(c, true, e) // keep the match to edit
		}
		return
	}
	switch {
	case .Tab in keys:
		console_tab(app, e)
		take(ctx, .Tab)
	case .Up in keys, ctrl && .P in keys:
		walk_history(c, -1, e)
		take(ctx, .P)
	case .Down in keys, ctrl && .N in keys:
		walk_history(c, 1, e)
		take(ctx, .N)
	case ctrl && .R in keys:
		st.searching = true
		clear(&st.query)
		st.found = -1
		take(ctx, .R)
	case ctrl && .L in keys:
		console_clear(c)
		take(ctx, .L)
	case ctrl && .C in keys:
		clear(&c.input)
		st.browsing = -1
		e.cursor, e.anchor = 0, 0
		take(ctx, .C)
	}
}

// console_search_ui: while searching, the line edits the query; this
// shows what it finds. Enter runs the match.
@(private)
console_search_ui :: proc(
	app: ^App,
	ctx: ^ui.Context,
	hint: ui.Rect,
	line: ui.Rect,
) -> (
	run: string,
	ok: bool,
) {
	c := &app.console
	st := &c.line
	t := &ctx.theme
	before := len(st.query)
	submitted := ui.text_input(ctx, "console search", &st.query, line, "search the history")
	query := string(st.query[:])
	if len(st.query) != before {st.found = search_history(c, query, len(c.history) - 1)}
	match := c.history[st.found] if st.found >= 0 else ""
	text :=
		fmt.tprintf("reverse search: %s", match) if st.found >= 0 else ("reverse search: no match" if query != "" else "reverse search (Ctrl+R: older, Enter: run, Esc: cancel)")
	ui.draw_text(ctx, hint, text, t.font_size, t.text_muted)
	ctx.focused = ui.get_id(ctx, "console search")
	if submitted && st.found >= 0 {
		run = match
		search_end(c, false, &ctx.edit)
		return run, true
	}
	return
}

// console_search_cancel ends a search, keeping the line as it was (Esc).
console_search_cancel :: proc(c: ^Console) -> bool {
	if !c.line.searching {return false}
	c.line.searching = false
	return true
}

@(private = "file")
search_end :: proc(c: ^Console, keep: bool, e: ^ui.Text_Edit) {
	st := &c.line
	if keep && st.found >= 0 {
		clear(&c.input)
		append(&c.input, c.history[st.found])
		e.cursor, e.anchor = len(c.input), len(c.input)
	}
	st.searching = false
}

// search_history: the newest history line at or before `from` holding
// query; -1 if none.
@(private = "file")
search_history :: proc(c: ^Console, query: string, from: int) -> int {
	if query == "" {return -1}
	for i := min(from, len(c.history) - 1); i >= 0; i -= 1 {
		if strings.contains(c.history[i], query) {return i}
	}
	return -1
}

// walk_history moves through the history (-1: older, +1: newer), keeping
// the line being written to come back to.
@(private)
walk_history :: proc(c: ^Console, step: int, e: ^ui.Text_Edit) {
	st := &c.line
	if len(c.history) == 0 {return}
	if st.browsing < 0 {
		if step > 0 {return}
		clear(&st.draft)
		append(&st.draft, ..c.input[:])
		st.browsing = len(c.history)
	}
	st.browsing = clamp(st.browsing + step, 0, len(c.history))
	clear(&c.input)
	if st.browsing == len(c.history) {
		append(&c.input, ..st.draft[:])
		st.browsing = -1
	} else {
		append(&c.input, c.history[st.browsing])
	}
	e.cursor, e.anchor = len(c.input), len(c.input)
}

// console_remember adds a line the player ran to the history (not one a
// script ran; not twice in a row).
console_remember :: proc(c: ^Console, line: string) {
	text := strings.trim_space(line)
	c.line.browsing = -1
	if text == "" || len(c.history) > 0 && c.history[len(c.history) - 1] == text {return}
	if len(c.history) == HISTORY_MAX {
		delete(c.history[0], c.allocator)
		ordered_remove(&c.history, 0)
	}
	append(&c.history, strings.clone(text, c.allocator))
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
	for line in strings.split_lines_iterator(&rest) {console_remember(c, line)}
}

console_history_save :: proc(c: ^Console) {
	path, ok := history_path()
	if !ok || len(c.history) == 0 {return}
	b := strings.builder_make(context.temp_allocator)
	for h in c.history {fmt.sbprintln(&b, h)}
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
	return complete_first(arg, {"title", "options", "worlds", "multiplayer", "quit"})
}

@(private)
complete_vars :: proc(app: ^App, arg: int, args: []string) -> []string {
	return complete_first(arg, {"rules.", "debug."})
}

@(private)
complete_block :: proc(app: ^App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if arg == 0 {for b in HOTBAR {append(&names, game.BLOCK_INFO[b].name)}}
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
	append(&names, "air")
	for b in HOTBAR {append(&names, game.BLOCK_INFO[b].name)}
	return names[:]
}

@(private)
complete_sphere :: proc(app: ^App, arg: int, args: []string) -> []string {
	return complete_block_or_air(app, 0, nil) if arg == 1 else nil
}
