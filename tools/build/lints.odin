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

// lint_process_exec: no `os.process_exec` outside common/limited: it stops reading a
// child's output when poll says the child hung up, and Linux's lockless pipe poll can
// say so before showing what the child wrote, so its output was lost now and then
// (an empty `git tag --list`). limited.exec reads to the end.
lint_process_exec :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	if strings.contains(path, "common/limited/") {return found[:]}
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if strings.contains(outside_strings(code), "os.process_exec(") {
			append(
				&found,
				fmt.aprintf(
					"%s:%d: os.process_exec loses output now and then: use limited.exec",
					path,
					line_no,
				),
			)
		}
	}
	return found[:]
}

// outside_strings: code with what its string literals hold blanked out.
outside_strings :: proc(code: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	quoted, escaped := false, false
	for c in code {
		switch {
		case quoted && escaped:
			escaped = false
		case quoted && c == '\\':
			escaped = true
		case c == '"':
			quoted = !quoted
			strings.write_rune(&b, c)
		case !quoted:
			strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
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
	for dir in ([]string{"client", "server", "common", "tools", GAMES_DIR}) {
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
	for dir in ([]string{"client", "server", "common", "tools", GAMES_DIR}) {
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
			append(&msgs, ..lint_process_exec(path, text))
			if dir == "tools" {
				for msg in msgs {
					fmt.eprintln(msg)
					ok = false
				}
				continue
			}
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
	if ok {fmt.println("lint   ui text, colours, mode names, miniaudio imports, process_exec and the OS quarantine clean")}
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

// GAME_IMPORTERS: the executables' main packages and the tools that read a session's
// trace (which must know its game), the only code outside games/ that may import a game,
// or the lists of them the driver writes (generated:games; docs/games.md).
GAME_IMPORTERS :: []string{"client/main", "server/dedicated", "tools/netdump", "tools/replay"}

// CLIENT_IMPORTER: of those, the one that may import a game's client package or the list
// of them (generated:games/client): the dedicated server links no client code.
CLIENT_IMPORTER :: "client/main"

// Game_Part: which of a game's packages a path is in (docs/layout.md, rule 6): its shared
// package `games/<game>`, its server part `games/<game>/server` or its client part
// `games/<game>/client`.
Game_Part :: enum u8 {
	Shared,
	Server,
	Client,
}

// game_path_of: the game and part of a path under games/ ("games/tag/client/hud.odin",
// or an import's "tag/client"), from the first segment after games/.
game_path_of :: proc(rest: string) -> (game: string, part: Game_Part) {
	game = rest
	after := ""
	if slash := strings.index_byte(rest, '/');
	   slash >= 0 {game, after = rest[:slash], rest[slash + 1:]}
	switch {
	case after == "server" || strings.has_prefix(after, "server/"):
		part = .Server
	case after == "client" || strings.has_prefix(after, "client/"):
		part = .Client
	}
	return
}

// lint_game_imports: the engine never imports a game, but for the executables' main
// packages (GAME_IMPORTERS; a game's client part and the client list only client/main),
// and a game imports no other game, nor the lists of games (generated:), which import
// them all. Within a game the parts stay apart as the engine's do: the shared package
// imports neither server: nor client:, the server part no client:, and a part imports no
// other part of its game but the shared package (but for the client part's tests, which
// play the game against its server part, as client/main's play the engine's). path is
// relative to the repository, with forward slashes.
lint_game_imports :: proc(path, text: string) -> []string {
	in_game := strings.has_prefix(path, "games/")
	is_test := strings.has_suffix(path, "_test.odin")
	own, own_part := "", Game_Part.Shared
	if in_game {own, own_part = game_path_of(path[len("games/"):])}
	found := make([dynamic]string)
	line_no := 0
	rest := text
	refuse :: proc(found: ^[dynamic]string, path: string, line_no: int, target, why: string) {
		append(found, fmt.aprintf("%s:%d: import \"%s\": %s", path, line_no, target, why))
	}
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		target := import_target(line) or_continue
		switch {
		case in_game && strings.has_prefix(target, "server:") && own_part == .Shared:
			refuse(
				&found,
				path,
				line_no,
				target,
				"a game's shared package is both sides': it imports no server code",
			)
		case in_game && strings.has_prefix(target, "client:") && own_part != .Client:
			refuse(&found, path, line_no, target, "only a game's client part imports client code")
		case strings.has_prefix(target, "games:"):
			game, part := game_path_of(target[len("games:"):])
			switch {
			case in_game && game != own:
				refuse(
					&found,
					path,
					line_no,
					target,
					"a game imports no other game (what two share belongs in the engine)",
				)
			case in_game &&
			     part != .Shared &&
			     !(own_part == .Client && part == .Server && is_test):
				refuse(
					&found,
					path,
					line_no,
					target,
					"a game's parts share only its shared package",
				)
			case !in_game && !slice.contains(GAME_IMPORTERS, folder_of(path)):
				refuse(
					&found,
					path,
					line_no,
					target,
					fmt.tprintf(
						"only the main packages (%s) import a game; the engine calls it through its hooks",
						strings.join(GAME_IMPORTERS, ", ", context.temp_allocator),
					),
				)
			case !in_game && part == .Client && folder_of(path) != CLIENT_IMPORTER:
				refuse(
					&found,
					path,
					line_no,
					target,
					"only " + CLIENT_IMPORTER + " imports a game's client part",
				)
			}
		case strings.has_prefix(target, "generated:"):
			switch {
			case in_game:
				refuse(
					&found,
					path,
					line_no,
					target,
					"a game imports no list of games (they import every game)",
				)
			case !slice.contains(GAME_IMPORTERS, folder_of(path)):
				refuse(
					&found,
					path,
					line_no,
					target,
					fmt.tprintf(
						"only the main packages (%s) import the list of games",
						strings.join(GAME_IMPORTERS, ", ", context.temp_allocator),
					),
				)
			case strings.has_prefix(target, "generated:games/client") &&
			     folder_of(path) != CLIENT_IMPORTER:
				refuse(
					&found,
					path,
					line_no,
					target,
					"only " + CLIENT_IMPORTER + " imports the client list of games",
				)
			}
		}
	}
	return found[:]
}

// lint_game_shadows: no declaration of a game's package takes the name of a package one
// of its files imports (a proc `play` beside `import "server:play"`): the compiler's
// complaint names neither, and every use of the import in that file breaks. decls are
// the package's top-level names (every file of its folder). path is relative to the
// repository, with forward slashes.
lint_game_shadows :: proc(path, text: string, decls: []string) -> []string {
	found := make([dynamic]string)
	if !strings.has_prefix(path, "games/") {return found[:]}
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "import ") {continue}
		q := strings.index_byte(l, '"')
		if q < 0 {continue}
		alias := strings.trim_space(l[len("import "):q])
		if alias == "" {
			target := strings.trim_right(l[q + 1:], "\"")
			target, _, _ = strings.partition(target, "\"")
			if c := strings.last_index_any(target, ":/"); c >= 0 {target = target[c + 1:]}
			alias = target
		}
		if !slice.contains(decls, alias) {continue}
		append(
			&found,
			fmt.aprintf(
				"%s:%d: the package declares %s, the name this file imports a package as: rename the declaration",
				path,
				line_no,
				alias,
			),
		)
	}
	return found[:]
}

// lint_game_package: a game's packages are named for it (docs/layout.md, rule 6): the
// shared package `<game>`, the server part `<game>_server`, the client part `<game>_client`,
// so no two games' parts share a name and code that imports one names it so. path is relative to the repository, with forward slashes.
lint_game_package :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	if !strings.has_prefix(path, "games/") {return found[:]}
	game, part := game_path_of(path[len("games/"):])
	want := game
	switch part {
	case .Shared:
	case .Server:
		want = strings.concatenate({game, "_server"}, context.temp_allocator)
	case .Client:
		want = strings.concatenate({game, "_client"}, context.temp_allocator)
	}
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "package ") {continue}
		name := strings.trim_space(trimmed[len("package "):])
		if name != want {
			append(
				&found,
				fmt.aprintf(
					"%s:%d: package %s: a game's package here is named %s",
					path,
					line_no,
					name,
					want,
				),
			)
		}
		break
	}
	return found[:]
}

// GAME_API_DOC holds the list of what a game may call of server:core (the table under
// GAME_API_HEADING), which lint_game_api reads.
GAME_API_DOC :: "docs/games.md"
GAME_API_HEADING :: "## What a game may call"

// GAME_KIT_DIR: what the server parts of games share (server/play), built on the list.
GAME_KIT_DIR :: "server/play"

// GAME_API_PACKAGE: the package the list names the declarations of.
GAME_API_PACKAGE :: "server/core"

// parse_game_api: the names the table under GAME_API_HEADING (up to the next heading)
// lists in its first column, each backticked span's leading identifier (`teleport(s, c, ...)` is teleport).
parse_game_api :: proc(text: string) -> []string {
	names := make([dynamic]string)
	_, _, section := strings.partition(text, GAME_API_HEADING)
	rest := section
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "#") {break} 	// (the next heading, a sub-heading too)
		if !strings.has_prefix(line, "| `") {continue}
		cell, _, _ := strings.partition(line[1:], "|")
		for {
			_, _, after := strings.partition(cell, "`")
			span, found, more := strings.partition(after, "`")
			if found == "" {break}
			n := 0
			for n < len(span) && is_ident_byte(span[n]) {n += 1}
			if n > 0 {append(&names, span[:n])}
			cell = more
		}
	}
	return names[:]
}

@(private = "file")
is_ident_byte :: proc(b: u8) -> bool {
	switch b {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

// lint_game_api_declared: every name the list holds is declared at the top of a file of
// server/core (decls: the names declared there): a name renamed or deleted in the
// engine leaves no promise in the list. Each missing name is one message.
lint_game_api_declared :: proc(api: []string, decls: []string) -> []string {
	found := make([dynamic]string)
	for name in api {
		if slice.contains(decls, name) {continue}
		append(
			&found,
			fmt.aprintf(
				"%s: \"%s\" lists %s, which %s does not declare",
				GAME_API_DOC,
				GAME_API_HEADING[3:],
				name,
				GAME_API_PACKAGE,
			),
		)
	}
	return found[:]
}

// top_declarations: the names declared at the top level of Odin code (`name ::` at the
// start of a line).
top_declarations :: proc(text: string, out: ^[dynamic]string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		n := 0
		for n < len(line) && is_ident_byte(line[n]) {n += 1}
		if n > 0 && strings.has_prefix(line[n:], " ::") {append(out, line[:n])}
	}
}

// lint_game_api: a game's code names of server:core (imported as core) only what
// GAME_API_DOC lists a game may call (api): much of server/core is visible to it, and
// what a game reaches is the engine's to choose. Nor does it assign to a world's rules
// (w.rules.drops = false): it changes one with core.game_rule, journalled as the game's.
// Its tests, which drive the harness, may do either. What the games share
// (GAME_KIT_DIR) is held to the same list: it is built on what a game may call. path is
// relative to the repository, with forward slashes.
lint_game_api :: proc(path, text: string, api: []string) -> []string {
	found := make([dynamic]string)
	held := strings.has_prefix(path, "games/") || strings.has_prefix(path, GAME_KIT_DIR + "/")
	if !held || strings.has_suffix(path, "_test.odin") {
		return found[:]
	}
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		code, _, _ := strings.partition(line, "//")
		if assigns_rules(code) {
			append(
				&found,
				fmt.aprintf(
					"%s:%d: a game does not write a world's rules: core.game_rule changes one (%s)",
					path,
					line_no,
					GAME_API_DOC,
				),
			)
		}
		for i := 0; i + len("core.") < len(code); i += 1 {
			if !strings.has_prefix(code[i:], "core.") || (i > 0 && is_ident_byte(code[i - 1])) {
				continue
			}
			start := i + len("core.")
			end := start
			for end < len(code) && is_ident_byte(code[end]) {end += 1}
			name := code[start:end]
			if name != "" && !slice.contains(api, name) {
				append(
					&found,
					fmt.aprintf(
						"%s:%d: core.%s is not something a game may call (%s, \"%s\")",
						path,
						line_no,
						name,
						GAME_API_DOC,
						GAME_API_HEADING[3:],
					),
				)
			}
			i = end
		}
	}
	return found[:]
}

// assigns_rules: code assigns to a selector's rules or one of their fields
// (`w.rules = r`, `s.home.rules.drops = false`, `w.rules.size *= 2`), not compares.
@(private = "file")
assigns_rules :: proc(code: string) -> bool {
	for i := 0; i < len(code); i += 1 {
		if !strings.has_prefix(code[i:], ".rules") {continue}
		end := i + len(".rules")
		if end < len(code) && is_ident_byte(code[end]) {continue} 	// (.rules_text)
		for end < len(code) && code[end] == '.' {
			end += 1
			for end < len(code) && is_ident_byte(code[end]) {end += 1}
		}
		op := strings.trim_left_space(code[end:])
		switch {
		case strings.has_prefix(op, "=="):
		case strings.has_prefix(op, "="):
			return true
		case len(op) >= 2 && op[1] == '=' && strings.index_byte("+-*/%|&~", op[0]) >= 0:
			return true
		}
		i = end - 1
	}
	return false
}

// import_lint runs lint_relative_imports, lint_game_imports, lint_game_package and
// lint_game_api over every first-party Odin file.
import_lint :: proc() -> bool {
	ok := true
	doc, doc_err := os.read_entire_file_from_path(GAME_API_DOC, context.allocator)
	if doc_err != nil {
		fmt.eprintfln("lint   %s: unreadable", GAME_API_DOC)
		return false
	}
	api := parse_game_api(string(doc))
	decls := make([dynamic]string)
	if entries, err := os.read_all_directory_by_path(GAME_API_PACKAGE, context.allocator);
	   err == nil {
		for e in entries {
			if filepath.ext(e.name) != ".odin" || strings.has_suffix(e.name, "_test.odin") {
				continue
			}
			data, _ := os.read_entire_file_from_path(e.fullpath, context.allocator)
			top_declarations(string(data), &decls)
		}
	}
	for msg in lint_game_api_declared(api, decls[:]) {
		fmt.eprintln(msg)
		ok = false
	}
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
			for msg in lint_game_package(path, string(data)) {
				fmt.eprintln(msg)
				ok = false
			}
			if strings.has_prefix(path, GAMES_DIR + "/") {
				pkg_dir := filepath.dir(info.fullpath)
				names := make([dynamic]string, context.temp_allocator)
				if entries, derr := os.read_all_directory_by_path(pkg_dir, context.temp_allocator);
				   derr == nil {
					for e in entries {
						if filepath.ext(e.name) != ".odin" {continue}
						d, _ := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
						top_declarations(string(d), &names)
					}
				}
				for msg in lint_game_shadows(path, string(data), names[:]) {
					fmt.eprintln(msg)
					ok = false
				}
			}
			for msg in lint_game_api(path, string(data), api) {
				fmt.eprintln(msg)
				ok = false
			}
		}
	}
	if ok {fmt.println("lint   imports go through collections, only the main packages import a game, games' packages are named for them, call what docs/games.md lists (all of it declared) and write no rules")}
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
