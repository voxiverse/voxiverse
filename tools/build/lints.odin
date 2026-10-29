package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Source lints, run by `check` (they were tests that read the sources). None has an
// exemption or a skip list: a rule is kept by changing the code it finds.

// The interface layers of the client: screens, menus, overlays and the HUD.
is_layer_file :: proc(name: string) -> bool {
	if strings.has_suffix(name, "_test.odin") {return false}
	for prefix in ([]string{"screen_", "menu_", "overlay_", "hud_"}) {
		if strings.has_prefix(name, prefix) {return true}
	}
	return false
}

// lint_ui_literals: no string literal in a ui.button, ui.label, ui.title or toast call of a
// layer file: they take a key (tr) or a registry name, never English written in the call.
lint_ui_literals :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	for hit in literal_calls(text) {
		append(
			&found,
			fmt.aprintf("%s:%d: a string literal in %s: use tr(key)", path, hit.line, hit.call),
		)
	}
	return found[:]
}

// lint_colour_literals: no `ui.Color{` in a layer file: interface colours come from the
// theme, artwork colours from data.
lint_colour_literals :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if strings.contains(code, "ui.Color{") {
			append(
				&found,
				fmt.aprintf("%s:%d: a colour literal: use a theme colour", path, line_no),
			)
		}
	}
	return found[:]
}

// lint_mode_names: no code tests a game mode by name; systems ask for abilities.
lint_mode_names :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		for word in ([]string{"creative", "survival"}) {
			for op in ([]string{"== \"", "!= \""}) {
				plain := fmt.tprintf("%s%s\"", op, word)
				based := fmt.tprintf("%sbase:%s", op, word)
				if strings.contains(code, plain) || strings.contains(code, based) {
					append(
						&found,
						fmt.aprintf(
							"%s:%d: a game mode tested by name: ask for an ability",
							path,
							line_no,
						),
					)
				}
			}
		}
	}
	return found[:]
}

// lint_miniaudio: `vendor:miniaudio` is the output device's layer only (client/audio/device.odin,
// until the next tier replaces it): every Ogg the game reads goes through common/ogg.
lint_miniaudio :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	if strings.has_suffix(path, "client/audio/device.odin") {return found[:]}
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if strings.contains(code, "\"vendor:miniaudio\"") {
			append(
				&found,
				fmt.aprintf(
					"%s:%d: vendor:miniaudio outside client/audio/device.odin: decode with common/ogg",
					path,
					line_no,
				),
			)
		}
	}
	return found[:]
}

// lint_test_timing: no `*_test.odin` outside smoke/ sleeps or reads a clock (time.sleep,
// time.now, tick_now, tick_since): a unit test counts ticks and steps a harness; what
// needs the real clock is a smoke test.
lint_test_timing :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		for word in ([]string{"time.sleep", "time.now", "tick_now", "tick_since"}) {
			if strings.contains(code, word) {
				append(
					&found,
					fmt.aprintf(
						"%s:%d: %s in a unit test: step ticks, or move it to smoke/",
						path,
						line_no,
						word,
					),
				)
			}
		}
	}
	return found[:]
}

// lint_test_servers: no `start(&srv` in a unit test outside smoke/: a unit test runs the
// stepped server on the harness (harness_start), never a threaded one.
lint_test_servers :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if strings.contains(code, "start(&srv") {
			append(
				&found,
				fmt.aprintf(
					"%s:%d: start(&srv...) in a unit test: use harness_start, or move it to smoke/",
					path,
					line_no,
				),
			)
		}
	}
	return found[:]
}

// test_lint scans the unit tests (every `_test.odin` outside smoke/) with the two rules above.
test_lint :: proc() -> bool {
	ok := true
	for dir in ([]string{"client", "server", "common", "base", "dedicated", "tools"}) {
		w := os.walker_create(dir)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type != .Regular || !strings.has_suffix(info.name, "_test.odin") {continue}
			data, err := os.read_entire_file_from_path(info.fullpath, context.allocator)
			if err != nil {
				fmt.eprintfln("lint   %s: unreadable", info.fullpath)
				ok = false
				continue
			}
			path, _ := strings.replace_all(info.fullpath, "\\", "/")
			msgs := make([dynamic]string)
			append(&msgs, ..lint_test_timing(path, string(data)))
			append(&msgs, ..lint_test_servers(path, string(data)))
			for msg in msgs {
				fmt.eprintln(msg)
				ok = false
			}
		}
	}
	if ok {fmt.println("lint   unit tests neither sleep, read a clock nor start a threaded server")}
	return ok
}

// source_lint runs the source lints over the first-party code.
source_lint :: proc() -> bool {
	ok := true
	for dir in ([]string{"client", "server", "common"}) {
		w := os.walker_create(dir)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type != .Regular || filepath.ext(info.name) != ".odin" {continue}
			data, err := os.read_entire_file_from_path(info.fullpath, context.allocator)
			if err != nil {
				fmt.eprintfln("lint   %s: unreadable", info.fullpath)
				ok = false
				continue
			}
			text := string(data)
			path, _ := strings.replace_all(info.fullpath, "\\", "/")
			msgs := make([dynamic]string)
			append(&msgs, ..lint_miniaudio(path, text))
			if strings.has_suffix(info.name, "_test.odin") {
				for msg in msgs {
					fmt.eprintln(msg)
					ok = false
				}
				continue
			}
			append(&msgs, ..lint_mode_names(path, text))
			if dir == "client" && filepath.dir(path) == "client" && is_layer_file(info.name) {
				append(&msgs, ..lint_ui_literals(path, text))
				append(&msgs, ..lint_colour_literals(path, text))
			}
			for msg in msgs {
				fmt.eprintln(msg)
				ok = false
			}
		}
	}
	if ok {fmt.println("lint   ui text, colours, mode names and miniaudio imports clean")}
	return ok
}

// lint_ci_test_names: every name in a `-define:ODIN_TEST_NAMES=pkg.test,...` of the workflow
// is one of `tests` (as "pkg.test"): a step naming a test that is gone would run nothing and pass.
lint_ci_test_names :: proc(path, text: string, tests: []string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	KEY :: "ODIN_TEST_NAMES="
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		at := strings.index(line, KEY)
		if at < 0 {continue}
		list := line[at + len(KEY):]
		if end := strings.index_any(list, " \t\"'"); end >= 0 {list = list[:end]}
		for name in strings.split(list, ",", context.temp_allocator) {
			exists := false
			for t in tests {if t == name {exists = true}}
			if !exists {
				append(
					&found,
					fmt.aprintf(
						"%s:%d: ODIN_TEST_NAMES names %s, which is not a test",
						path,
						line_no,
						name,
					),
				)
			}
		}
	}
	return found[:]
}

// test_names lists every `@(test)` proc under the first-party directories (SOURCE_DIRS' roots, and smoke) as "pkg.name".
test_names :: proc() -> (names: []string, ok: bool) {
	out := make([dynamic]string)
	ok = true
	for dir in ([]string{"smoke", "common", "base", "client", "server", "dedicated", "tools"}) {
		w := os.walker_create(dir)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type != .Regular || !strings.has_suffix(info.name, "_test.odin") {continue}
			data, err := os.read_entire_file_from_path(info.fullpath, context.allocator)
			if err != nil {
				fmt.eprintfln("lint   %s: unreadable", info.fullpath)
				ok = false
				continue
			}
			append(&out, ..tests_in(string(data)))
		}
	}
	return out[:], ok
}

// tests_in: "pkg.name" of each `@(test)` proc in one file's text.
tests_in :: proc(text: string) -> []string {
	out := make([dynamic]string)
	pkg := ""
	marked := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "package ") {pkg = strings.trim_space(l[len("package "):])}
		if l == "@(test)" {marked = true; continue}
		if marked {
			if name, match, _ := strings.partition(l, " ::"); match != "" {
				append(&out, fmt.aprintf("%s.%s", pkg, name))
			}
			marked = false
		}
	}
	return out[:]
}

// ci_lint reads the workflow and checks the test names it runs.
ci_lint :: proc() -> bool {
	path := ".github/workflows/ci.yml"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("lint   %s: unreadable", path)
		return false
	}
	tests, ok := test_names()
	for msg in lint_ci_test_names(path, string(data), tests) {
		fmt.eprintln(msg)
		ok = false
	}
	if ok {fmt.println("lint   ci.yml names only existing tests")}
	return ok
}

Literal_Call :: struct {
	line: int,
	call: string,
}

// literal_calls: the ui.button, ui.label, ui.title and toast calls in
// source whose arguments (but for `id = "..."`, an id and not a text)
// contain a string literal (the empty one aside).
literal_calls :: proc(source: string) -> []Literal_Call {
	out := make([dynamic]Literal_Call, context.allocator)
	// Comments out (a // to the end of the line), strings kept.
	b := strings.builder_make(context.allocator)
	in_string := false
	for i := 0; i < len(source); i += 1 {
		c := source[i]
		if in_string {
			strings.write_byte(&b, c)
			if c == '\\' && i + 1 < len(source) {
				i += 1
				strings.write_byte(&b, source[i])
			} else if c == '"' {in_string = false}
			continue
		}
		if c == '"' {in_string = true} else if c == '\'' && i + 2 < len(source) {
			// a character literal: copied whole ('"' is not a string)
			end := i + 2
			if source[i + 1] == '\\' {end += 1}
			strings.write_string(&b, source[i:min(end + 1, len(source))])
			i = end
			continue
		} else if c == '/' && i + 1 < len(source) && source[i + 1] == '/' {
			for i < len(source) && source[i] != '\n' {i += 1}
			strings.write_byte(&b, '\n')
			continue
		}
		strings.write_byte(&b, c)
	}
	text := strings.to_string(b)
	for call in ([]string{"ui.button(", "ui.label(", "ui.title(", "toast("}) {
		from := 0
		for {
			at := strings.index(text[from:], call)
			if at < 0 {break}
			at += from
			from = at + len(call)
			if at > 0 {
				prev := text[at - 1]
				if prev == '_' ||
				   (prev >= 'a' && prev <= 'z') ||
				   (prev >= 'A' && prev <= 'Z') {continue}
			}
			// The arguments, to the matching parenthesis.
			depth, i := 1, from
			quoted := false
			for ; i < len(text) && depth > 0; i += 1 {
				c := text[i]
				if quoted {
					if c == '\\' {i += 1} else if c == '"' {quoted = false}
					continue
				}
				switch c {
				case '"':
					quoted = true
				case '(':
					depth += 1
				case ')':
					depth -= 1
				}
			}
			args := text[from:max(i - 1, from)]
			if id := strings.index(args, "id = \""); id >= 0 {
				end := strings.index(args[id + 6:], "\"")
				if end >=
				   0 {args = strings.concatenate({args[:id], args[id + 6 + end + 1:]}, context.allocator)}
			}
			args, _ = strings.replace_all(args, "\"\"", "", context.allocator) // (nothing to say)
			if strings.contains(args, "\"") {
				line := 1 + strings.count(text[:at], "\n")
				append(&out, Literal_Call{line, strings.trim_right(call, "(")})
			}
		}
	}
	return out[:]
}
