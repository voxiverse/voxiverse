package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Source lints, run by `check` (they were tests that read the sources). None has an
// exemption or a skip list: a rule is kept by changing the code it finds.

// The interface layers of the client: the files of the packages that draw screens, menus,
// overlays, the console, the HUD and the button prompts.
LAYER_FOLDERS :: []string {
	"client/screen",
	"client/menu",
	"client/overlay",
	"client/console",
	"client/hud",
	"client/prompt",
}

is_layer_file :: proc(path: string) -> bool {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {return false}
	folder, name := path[:slash], path[slash + 1:]
	if strings.has_suffix(name, "_test.odin") {return false}
	for layer in LAYER_FOLDERS {
		if folder == layer ||
		   strings.has_suffix(
			   folder,
			   strings.concatenate({"/", layer}, context.temp_allocator),
		   ) {return true}
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

// lint_colour_literals: no `ui.Color{` and no untyped colour literal (`{0, 0, 0, 255}`:
// three integer literals and a fourth component) in a layer file: interface colours come from
// the theme, artwork colours from data.
lint_colour_literals :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if strings.contains(code, "ui.Color{") || has_untyped_colour(code) {
			append(
				&found,
				fmt.aprintf("%s:%d: a colour literal: use a theme colour", path, line_no),
			)
		}
	}
	return found[:]
}

// has_untyped_colour: whether the code holds `{r, g, b, a}` with r, g and b integer literals.
has_untyped_colour :: proc(code: string) -> bool {
	rest := code
	for {
		open := strings.index_byte(rest, '{')
		if open < 0 {return false}
		rest = rest[open + 1:]
		at := rest
		ints := 0
		for ints < 3 {
			at = strings.trim_left_space(at)
			n := 0
			for n < len(at) && at[n] >= '0' && at[n] <= '9' {n += 1}
			if n == 0 {break}
			at = strings.trim_left_space(at[n:])
			if len(at) == 0 || at[0] != ',' {break}
			at = at[1:]
			ints += 1
		}
		if ints == 3 && strings.contains(at, "}") {return true}
	}
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

// PLATFORM_PACKAGES: the only packages that may link a system library (the OS quarantine).
PLATFORM_PACKAGES :: []string{"common/platform/", "client/platform/"}

// lint_os_quarantine: no `foreign import` of a system library outside the platform packages,
// and no exemption list. (Tests and tools/ keep direct OS access and are not scanned.)
lint_os_quarantine :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	for prefix in PLATFORM_PACKAGES {
		if strings.has_prefix(path, prefix) ||
		   strings.contains(
			   path,
			   strings.concatenate({"/", prefix}, context.temp_allocator),
		   ) {return found[:]}
	}
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if strings.contains(code, "foreign import") || strings.contains(code, "\"system:") {
			append(
				&found,
				fmt.aprintf(
					"%s:%d: foreign import or system: library outside the platform packages: move it behind common/platform or client/platform",
					path,
					line_no,
				),
			)
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

// lint_test_timing: no `*_test.odin` outside tests/ sleeps or reads a clock (time.sleep,
// time.now, tick_now, tick_since): a unit test counts ticks and steps a harness; what
// needs the real clock is a system test (tests/).
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
						"%s:%d: %s in a unit test: step ticks, or move it to tests/",
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

// lint_test_servers: no `start(&srv` in a unit test outside tests/: a unit test runs the
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
					"%s:%d: start(&srv...) in a unit test: use harness_start, or move it to tests/",
					path,
					line_no,
				),
			)
		}
	}
	return found[:]
}

// test_lint scans the unit tests (every `_test.odin` outside tests/) with the two rules above.
test_lint :: proc() -> bool {
	ok := true
	for dir in ([]string{"client", "server", "common", "tools"}) {
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
			append(&msgs, ..lint_os_quarantine(path, text))
			if dir == "client" && is_layer_file(path) {
				append(&msgs, ..lint_ui_literals(path, text))
				append(&msgs, ..lint_colour_literals(path, text))
			}
			for msg in msgs {
				fmt.eprintln(msg)
				ok = false
			}
		}
	}
	if ok {fmt.println("lint   ui text, colours, mode names, miniaudio imports and the OS quarantine clean")}
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

// import_target: the quoted path of an `import` or `foreign import` line, if it is one.
import_target :: proc(line: string) -> (target: string, ok: bool) {
	trimmed := strings.trim_left_space(line)
	if !strings.has_prefix(trimmed, "import ") &&
	   !strings.has_prefix(trimmed, "foreign import ") {return}
	open := strings.index_byte(trimmed, '"')
	if open < 0 {return}
	target = trimmed[open + 1:]
	if end := strings.index_byte(target, '"'); end >= 0 {target = target[:end]}
	return target, true
}

// lint_relative_imports: every first-party import goes through a collection
// (`common:game`, `client:gpu`), never a path relative to the importing file.
lint_relative_imports :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		target := import_target(line) or_continue
		if strings.index_byte(target, ':') >= 0 {continue}
		append(
			&found,
			fmt.aprintf(
				"%s:%d: import \"%s\" is a relative path: import through a collection (client:, server:, common:, games:)",
				path,
				line_no,
				target,
			),
		)
	}
	return found[:]
}

// GAME_IMPORTERS: the executables' main packages, the only code outside games/ that may
// import a game (docs/games.md).
GAME_IMPORTERS :: []string{"client/main", "server/dedicated"}

// lint_game_imports: the engine never imports a game, but for the executables' main
// packages (GAME_IMPORTERS), and a game imports no other game. path is relative to the
// repository, with forward slashes.
lint_game_imports :: proc(path, text: string) -> []string {
	game_of :: proc(rest: string) -> string {
		if slash := strings.index_byte(rest, '/'); slash >= 0 {return rest[:slash]}
		return rest
	}
	own := ""
	if strings.has_prefix(path, "games/") {own = game_of(path[len("games/"):])}
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		target := import_target(line) or_continue
		if !strings.has_prefix(target, "games:") {continue}
		imported := game_of(target[len("games:"):])
		switch {
		case own != "" && imported != own:
			append(
				&found,
				fmt.aprintf(
					"%s:%d: import \"%s\": a game imports no other game (what two share belongs in the engine)",
					path,
					line_no,
					target,
				),
			)
		case own == "" && !slice.contains(GAME_IMPORTERS, folder_of(path)):
			append(
				&found,
				fmt.aprintf(
					"%s:%d: import \"%s\": only the main packages (%s) import a game; the engine calls it through its hooks",
					path,
					line_no,
					target,
					strings.join(GAME_IMPORTERS, ", ", context.temp_allocator),
				),
			)
		}
	}
	return found[:]
}

// import_lint runs lint_relative_imports and lint_game_imports over every first-party Odin
// file.
import_lint :: proc() -> bool {
	ok := true
	for dir in ([]string{"tests", "common", "client", "server", "tools", GAMES_DIR}) {
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
			path := repo_path(info.fullpath)
			for msg in lint_relative_imports(path, string(data)) {
				fmt.eprintln(msg)
				ok = false
			}
			for msg in lint_game_imports(path, string(data)) {
				fmt.eprintln(msg)
				ok = false
			}
		}
	}
	if ok {fmt.println("lint   imports go through collections, and only the main packages import a game")}
	return ok
}

// lint_collections: the wrapper scripts and the editor config pass the same collections the
// driver does (COLLECTIONS), so a hand-run `odin` and the editor resolve imports the same way.
lint_collections :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	for flag in COLLECTIONS {
		name := flag[len("-collection:"):]
		eq := strings.index_byte(name, '=')
		if strings.has_suffix(path, ".json") {
			want := fmt.aprintf(
				"{{ \"name\": \"%s\", \"path\": \"%s\" }}",
				name[:eq],
				name[eq + 1:],
			)
			if !strings.contains(text, want) {
				append(
					&found,
					fmt.aprintf("%s: collection %s is missing from ols.json", path, name[:eq]),
				)
			}
		} else if !strings.contains(text, flag) {
			append(
				&found,
				fmt.aprintf("%s: %s is missing: keep it in step with COLLECTIONS", path, flag),
			)
		}
	}
	return found[:]
}

// collections_lint checks build.sh, build.bat and ols.json against COLLECTIONS.
collections_lint :: proc() -> bool {
	ok := true
	for path in ([]string{"build.sh", "build.bat", "ols.json"}) {
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			fmt.eprintfln("lint   %s: unreadable", path)
			ok = false
			continue
		}
		for msg in lint_collections(path, string(data)) {
			fmt.eprintln(msg)
			ok = false
		}
	}
	if ok {fmt.println("lint   build.sh, build.bat and ols.json name the collections")}
	return ok
}
