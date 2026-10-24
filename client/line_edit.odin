package client

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import "../ui"

// Line_Editor: a command line (the console's, chat's) beyond the editing
// every text field has (ui/widgets.odin): Tab completion, history
// (Up/Down or Ctrl+P/N), reverse search (Ctrl+R), Ctrl+C to clear the line.

HISTORY_MAX :: 500

Line_Editor :: struct {
	text:      [dynamic]u8,
	history:   [dynamic]string, // lines sent (oldest first)
	browsing:  int, // index into history while walking it; -1: editing the draft
	draft:     [dynamic]u8, // the line being written before walking the history
	searching: bool, // Ctrl+R
	query:     [dynamic]u8,
	found:     int, // the history line the search shows; -1: none
	allocator: mem.Allocator,
}

// Line_Completer: what the word after `before` (the line's words before
// the cursor's) can be, for Tab.
Line_Completer :: proc(app: ^App, before: []string) -> []string

// Line_Result: what a frame of line_edit did.
Line_Result :: struct {
	submitted: bool, // Enter: line is what to run or send (now in the history)
	line:      string, // (temp allocator)
	choices:   []string, // Tab could not choose: these fit (to show)
}

line_editor_init :: proc(le: ^Line_Editor, allocator := context.allocator) {
	le^ = {
		text      = make([dynamic]u8, allocator),
		history   = make([dynamic]string, allocator),
		draft     = make([dynamic]u8, allocator),
		query     = make([dynamic]u8, allocator),
		browsing  = -1,
		found     = -1,
		allocator = allocator,
	}
}

line_editor_destroy :: proc(le: ^Line_Editor) {
	for h in le.history {delete(h, le.allocator)}
	delete(le.text)
	delete(le.history)
	delete(le.draft)
	delete(le.query)
}

// line_edit: one frame of the line in rect (hint: where a search shows
// what it finds; the caller makes room while le.searching). Only the top
// overlay's line takes keys and keeps the focus.
line_edit :: proc(
	app: ^App,
	ctx: ^ui.Context,
	le: ^Line_Editor,
	id: string,
	rect, hint: ui.Rect,
	placeholder: string,
	top: bool,
	complete: Line_Completer,
) -> (
	r: Line_Result,
) {
	if top {r.choices = line_keys(app, ctx, le, complete)}
	if le.searching {
		search_id := fmt.tprintf("%s search", id)
		before := len(le.query)
		submitted := ui.text_input(ctx, search_id, &le.query, rect, "search the history")
		query := string(le.query[:])
		if len(le.query) != before {le.found = search_history(le, query, len(le.history) - 1)}
		match := le.history[le.found] if le.found >= 0 else ""
		text :=
			fmt.tprintf("reverse search: %s", match) if le.found >= 0 else ("reverse search: no match" if query != "" else "reverse search (Ctrl+R: older, Enter: run, Esc: cancel)")
		ui.draw_text(ctx, hint, text, ctx.theme.font_size, ctx.theme.text_muted)
		if top {ctx.focused = ui.get_id(ctx, search_id)}
		if submitted && le.found >= 0 {
			r.submitted, r.line = true, strings.clone(match, context.temp_allocator)
			search_end(le, false, &ctx.edit)
			line_remember(le, r.line)
		}
		return
	}
	if ui.text_input(ctx, id, &le.text, rect, placeholder) {
		r.submitted, r.line = true, strings.clone(string(le.text[:]), context.temp_allocator)
		line_remember(le, r.line)
		clear(&le.text)
	}
	if top {ctx.focused = ui.get_id(ctx, id)}
	return
}

// line_search_cancel ends a search, keeping the line as it was (Esc).
line_search_cancel :: proc(le: ^Line_Editor) -> bool {
	if !le.searching {return false}
	le.searching = false
	return true
}

// line_set replaces the line (the cursor at its end).
line_set :: proc(le: ^Line_Editor, e: ^ui.Text_Edit, text: string) {
	clear(&le.text)
	append(&le.text, text)
	e.cursor, e.anchor = len(le.text), len(le.text)
}

// line_keys handles the line's own keys this frame, before the line edits
// itself (the keys it takes, the line does not see).
@(private = "file")
line_keys :: proc(
	app: ^App,
	ctx: ^ui.Context,
	le: ^Line_Editor,
	complete: Line_Completer,
) -> []string {
	keys := ctx.input.keys_pressed
	ctrl := .Ctrl in ctx.input.modifiers && .Alt not_in ctx.input.modifiers
	e := &ctx.edit
	take :: proc(ctx: ^ui.Context, k: ui.Key) {ctx.input.keys_pressed -= {k}}

	if le.searching {
		switch {
		case ctrl && .R in keys:
			// The next older match.
			le.found = search_history(le, string(le.query[:]), le.found - 1)
			take(ctx, .R)
		case ctrl && .G in keys, ctrl && .C in keys:
			search_end(le, false, e)
			take(ctx, .G)
			take(ctx, .C)
		case .Left in keys, .Right in keys, ctrl && (.A in keys || .E in keys):
			search_end(le, true, e) // keep the match to edit
		}
		return nil
	}
	switch {
	case .Tab in keys:
		take(ctx, .Tab)
		if complete != nil {return line_tab(app, le, e, complete)}
	case .Up in keys, ctrl && .P in keys:
		walk_history(le, -1, e)
		take(ctx, .P)
	case .Down in keys, ctrl && .N in keys:
		walk_history(le, 1, e)
		take(ctx, .N)
	case ctrl && .R in keys:
		le.searching = true
		clear(&le.query)
		le.found = -1
		take(ctx, .R)
	case ctrl && .C in keys:
		clear(&le.text)
		le.browsing = -1
		e.cursor, e.anchor = 0, 0
		take(ctx, .C)
	}
	return nil
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

// line_tab completes the word before the cursor; the choices when it
// cannot.
@(private = "file")
line_tab :: proc(
	app: ^App,
	le: ^Line_Editor,
	e: ^ui.Text_Edit,
	complete: Line_Completer,
) -> []string {
	line := string(le.text[:])
	cursor := clamp(e.cursor, 0, len(line))
	start := strings.last_index_byte(line[:cursor], ' ') + 1
	word := line[start:cursor]
	before := strings.fields(line[:start], context.temp_allocator)
	completed, choices := complete_word(word, complete(app, before))
	if len(choices) > 0 {return choices}
	if completed == word {return nil}
	// Replace the word (and a space already after the cursor is not doubled).
	rest := line[cursor:]
	if strings.has_suffix(completed, " ") && strings.has_prefix(rest, " ") {
		completed = completed[:len(completed) - 1]
	}
	new_line := strings.concatenate({line[:start], completed, rest}, context.temp_allocator)
	clear(&le.text)
	append(&le.text, new_line)
	e.cursor = start + len(completed)
	e.anchor = e.cursor
	return nil
}

@(private = "file")
search_end :: proc(le: ^Line_Editor, keep: bool, e: ^ui.Text_Edit) {
	if keep && le.found >= 0 {line_set(le, e, le.history[le.found])}
	le.searching = false
}

// search_history: the newest history line at or before `from` holding
// query; -1 if none.
@(private = "file")
search_history :: proc(le: ^Line_Editor, query: string, from: int) -> int {
	if query == "" {return -1}
	for i := min(from, len(le.history) - 1); i >= 0; i -= 1 {
		if strings.contains(le.history[i], query) {return i}
	}
	return -1
}

// walk_history moves through the history (-1: older, +1: newer), keeping
// the line being written to come back to.
walk_history :: proc(le: ^Line_Editor, step: int, e: ^ui.Text_Edit) {
	if len(le.history) == 0 {return}
	if le.browsing < 0 {
		if step > 0 {return}
		clear(&le.draft)
		append(&le.draft, ..le.text[:])
		le.browsing = len(le.history)
	}
	le.browsing = clamp(le.browsing + step, 0, len(le.history))
	if le.browsing == len(le.history) {
		line_set(le, e, string(le.draft[:]))
		le.browsing = -1
	} else {
		line_set(le, e, le.history[le.browsing])
	}
}

// line_remember adds a line to the history (not twice in a row).
line_remember :: proc(le: ^Line_Editor, line: string) {
	text := strings.trim_space(line)
	le.browsing = -1
	if text == "" || len(le.history) > 0 && le.history[len(le.history) - 1] == text {return}
	if len(le.history) == HISTORY_MAX {
		delete(le.history[0], le.allocator)
		ordered_remove(&le.history, 0)
	}
	append(&le.history, strings.clone(text, le.allocator))
}
