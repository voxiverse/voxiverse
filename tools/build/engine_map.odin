package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// docs/engine-map.md is what the engine offers a game, written from the source so that an
// agent building a game reads one file instead of searching the engine: the hooks and fields
// of core.Game and engine.Game, and every name docs/games.md lists a game may call, each with
// its signature and its doc comment's first sentence, then the types those signatures name.
// `build engine-map` writes it; `check` fails while it is stale, and when a name a game may
// call has no doc comment.

ENGINE_MAP :: "docs/engine-map.md"

// Map_List: a package a game calls, and the heading of its list in GAME_API_DOC: the
// table whose first column names what of it a game may call (parse_game_api).
Map_List :: struct {
	dir:     string,
	heading: string,
}

// MAP_LISTS: the lists, in the order the map gives them. The first is the one the import
// lint holds a game's code to (lint_game_api); the others are the kits made for games.
MAP_LISTS :: []Map_List {
	{GAME_API_PACKAGE, GAME_API_HEADING},
	{GAME_KIT_DIR, "## What the games share: `server:play`"},
	{"client/engine", "### What a game's client part calls"},
	{"client/engine", "### What a game's HUD is made of"},
	{"client/menu", "### Items and panes: `client:menu`"},
	{"client/overview", "### Commanding from above: `client:overview`"},
}

// Map_Game: a Game struct whose fields are a part's hooks: the server part's and the client part's.
Map_Game :: struct {
	dir:   string,
	alias: string,
}

MAP_GAMES :: []Map_Game{{GAME_API_PACKAGE, "core"}, {"client/engine", "engine"}}

Decl_Kind :: enum u8 {
	Proc, // a procedure, a group of them, or another name for one
	Type,
	Constant,
}

// Decl: a top-level `name :: ...` declaration of a package.
Decl :: struct {
	name: string,
	kind: Decl_Kind,
	head: string, // what follows `::` up to its body, on one line: `proc(s: ^Server) -> bool`, `struct`, `enum u8`, `8`
	body: string, // what is between its braces, as written (a struct's fields, an enum's names, a group's procedures)
	doc:  string, // its doc comment (the `//` lines right above it), on one line
	file: string,
}

// Parsed_Package: a package's public declarations, and the packages it imports by the name
// its code uses for them ("game": "common/game").
Parsed_Package :: struct {
	decls:   map[string]Decl,
	imports: map[string]string,
}

// parse_declarations adds the public top-level declarations of one file (text, at path) to
// p: `@(private)` ones and a `#+private` file's are left out.
parse_declarations :: proc(p: ^Parsed_Package, path, text: string) {
	if p.decls == nil {p.decls = make(map[string]Decl)}
	if p.imports == nil {p.imports = make(map[string]string)}
	doc := make([dynamic]string, context.temp_allocator)
	private := false
	pos := 0
	for pos < len(text) {
		end := strings.index_byte(text[pos:], '\n')
		end = len(text) if end < 0 else pos + end
		line := strings.trim_right(text[pos:end], "\r")
		next := end + 1
		switch {
		case strings.has_prefix(line, "#+private"):
			return
		case strings.has_prefix(line, "//"):
			append(&doc, strings.trim_space(line[2:]))
			pos = next
			continue
		case strings.has_prefix(line, "@("):
			if strings.contains(line, "private") {private = true}
			pos = next
			continue
		case strings.has_prefix(line, "import "):
			if alias, dir, ok := parse_import(line); ok {p.imports[alias] = dir}
		}
		n := 0
		for n < len(line) && is_ident_char(line[n]) {n += 1}
		if n > 0 && strings.has_prefix(line[n:], " ::") && !private {
			head, body, decl_end := decl_extent(text, pos + n + len(" ::"))
			name := line[:n]
			// A one-line declaration's comment may follow it (`MAX_X :: 8 // what it is`).
			code := without_comments(line)
			if len(doc) == 0 && body == "" && len(code) < len(line) {
				append(&doc, strings.trim_space(line[len(code) + len("//"):]))
			}
			p.decls[name] = Decl {
				name = name,
				kind = decl_kind(name, head),
				head = head,
				body = body,
				doc  = strings.join(doc[:], " "),
				file = path,
			}
			next = max(next, decl_end)
		}
		clear(&doc)
		private = false
		pos = next
	}
}

// parse_import: an import line's name for the package and its folder (`import "common:game"`
// is game, common/game; `import gm "common:game"` is gm). ok is false for core: and base:.
parse_import :: proc(line: string) -> (alias, dir: string, ok: bool) {
	rest := strings.trim_space(line[len("import "):])
	q := strings.index_byte(rest, '"')
	if q < 0 {return}
	alias = strings.trim_space(rest[:q])
	target, _, _ := strings.partition(rest[q + 1:], "\"")
	collection, colon, path := strings.partition(target, ":")
	if colon == "" || collection == "core" || collection == "base" || collection == "vendor" {
		return
	}
	if alias == "" {alias = filepath.base(path)}
	return alias, strings.concatenate({collection, "/", path}), true
}

// decl_kind: a procedure's head starts with proc (a group's too); a name like a type's
// (Capitalised, with a small letter) is a type; the rest are constants, but a small name
// that is another's (`fight :: squad.fight`), which is a procedure.
decl_kind :: proc(name, head: string) -> Decl_Kind {
	h := strings.trim_prefix(head, "#force_inline ")
	if strings.has_prefix(h, "proc") {return .Proc}
	lower, upper := false, false
	for c in name {
		if c >= 'a' && c <= 'z' {lower = true}
		if c >= 'A' && c <= 'Z' {upper = true}
	}
	switch {
	case name[0] >= 'A' && name[0] <= 'Z' && lower:
		return .Type
	case !upper:
		return .Proc
	}
	return .Constant
}

// decl_extent reads a declaration from start (just after its `::`): its head, up to the
// `{` that opens its body (or the end of its line, or `---`), on one line with the
// comments left out, and its body, between that brace and its match; end is past it. Strings,
// runes and comments are skipped, so a brace or a parenthesis in one counts for nothing.
decl_extent :: proc(text: string, start: int) -> (head, body: string, end: int) {
	b := strings.builder_make(context.temp_allocator)
	depth := 0 // ( and [
	i := start
	for i < len(text) {
		c := text[i]
		switch {
		case c == '/' && i + 1 < len(text) && text[i + 1] == '/':
			for i < len(text) && text[i] != '\n' {i += 1}
			continue
		case c == '"' || c == '`' || c == '\'':
			j := skip_literal(text, i)
			strings.write_string(&b, text[i:j])
			i = j
			continue
		case c == '(' || c == '[':
			depth += 1
		case c == ')' || c == ']':
			depth -= 1
		case c == '\n' && depth <= 0:
			return one_line(strings.to_string(b)), "", i
		case c == '-' && strings.has_prefix(text[i:], "---"):
			return one_line(strings.to_string(b)), "", i + 3
		case c == '{' && depth <= 0:
			close := matching_brace(text, i)
			return one_line(strings.to_string(b)), text[i + 1:close], close + 1
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return one_line(strings.to_string(b)), "", len(text)
}

// without_comments: code with its `//` comments taken out (not those in its strings).
without_comments :: proc(code: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(code) {
		c := code[i]
		switch {
		case c == '/' && i + 1 < len(code) && code[i + 1] == '/':
			for i < len(code) && code[i] != '\n' {i += 1}
			continue
		case c == '"' || c == '`' || c == '\'':
			j := skip_literal(code, i)
			strings.write_string(&b, code[i:j])
			i = j
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

// skip_literal: past the string, raw string or rune that starts at i.
skip_literal :: proc(text: string, i: int) -> int {
	quote := text[i]
	j := i + 1
	for j < len(text) && text[j] != quote {
		if quote != '`' && text[j] == '\\' {j += 1}
		if quote != '`' && text[j] == '\n' {break}
		j += 1
	}
	return min(j + 1, len(text))
}

// matching_brace: the `}` that closes the `{` at open (len(text)-1 if none does).
matching_brace :: proc(text: string, open: int) -> int {
	depth := 0
	i := open
	for i < len(text) {
		c := text[i]
		switch {
		case c == '/' && i + 1 < len(text) && text[i + 1] == '/':
			for i < len(text) && text[i] != '\n' {i += 1}
			continue
		case c == '"' || c == '`' || c == '\'':
			i = skip_literal(text, i)
			continue
		case c == '{':
			depth += 1
		case c == '}':
			depth -= 1
			if depth == 0 {return i}
		}
		i += 1
	}
	return len(text) - 1
}

// one_line: code as one line: its runs of space one space, none inside brackets' edges, no
// comma before a closing one (as odinfmt leaves a list split over lines).
one_line :: proc(code: string) -> string {
	fields := strings.fields(code, context.temp_allocator)
	s := strings.join(fields, " ", context.temp_allocator)
	for pair in ([][2]string{{"( ", "("}, {" )", ")"}, {",)", ")"}, {"[ ", "["}, {" ]", "]"}}) {
		s, _ = strings.replace_all(s, pair[0], pair[1], context.temp_allocator)
	}
	return strings.clone(s)
}

// first_sentence: a doc comment's first sentence (up to the first full stop that ends a
// word before a space: not "e.g." or "i.e."), or all of it, without the `name: ` it may
// start with (the map shows the name beside it).
first_sentence :: proc(text: string, name := "") -> string {
	doc := text
	if name != "" && strings.has_prefix(doc, name) && strings.has_prefix(doc[len(name):], ": ") {
		doc = doc[len(name) + 2:]
	}
	for i := 0; i + 1 < len(doc); i += 1 {
		if doc[i] != '.' || doc[i + 1] != ' ' {continue}
		before := doc[:i]
		if strings.has_suffix(before, "e.g") || strings.has_suffix(before, "i.e") {continue}
		return doc[:i + 1]
	}
	return doc
}

// Map_Field: one field of a struct: its name, its type on one line, its comment.
Map_Field :: struct {
	name: string,
	type: string,
	doc:  string,
}

// struct_fields: the fields of a struct's body as written, each with its comment: the one
// after it on the line it ends on, or else the lines right above it.
struct_fields :: proc(body: string) -> []Map_Field {
	fields := make([dynamic]Map_Field)
	cur := strings.builder_make(context.temp_allocator)
	above := make([dynamic]string, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator) // `a, b: T`: the names before the type
	depth := 0
	just_ended := false // a field ended on this line: a comment now is its own
	finish :: proc(
		fields: ^[dynamic]Map_Field,
		names: ^[dynamic]string,
		above: ^[dynamic]string,
		text: string,
	) {
		t := strings.trim_space(text)
		if t == "" {return}
		name, colon, type := strings.partition(t, ":")
		// (cloned: text is the builder's, which the next field writes over)
		if colon == "" {
			append(names, strings.clone(strings.trim_space(name)))
			return
		}
		append(
			names,
			strings.clone(
				strings.trim_space(strings.trim_prefix(strings.trim_space(name), "using ")),
			),
		)
		doc := strings.join(above[:], " ")
		for n in names {append(fields, Map_Field{n, one_line(type), doc})}
		clear(names)
		clear(above)
	}
	i := 0
	for i < len(body) {
		c := body[i]
		switch {
		case c == '/' && i + 1 < len(body) && body[i + 1] == '/':
			eol := strings.index_byte(body[i:], '\n')
			eol = len(body) if eol < 0 else i + eol
			comment := strings.trim_space(body[i + 2:eol])
			if just_ended && len(fields) > 0 {
				fields[len(fields) - 1].doc = comment
			} else if strings.trim_space(strings.to_string(cur)) == "" {
				append(&above, comment)
			}
			i = eol
			continue
		case c == '"' || c == '`' || c == '\'':
			j := skip_literal(body, i)
			strings.write_string(&cur, body[i:j])
			i = j
			continue
		case c == '(' || c == '[' || c == '{':
			depth += 1
		case c == ')' || c == ']' || c == '}':
			depth -= 1
		case c == '\n':
			just_ended = false
		case c == ',' && depth == 0:
			finish(&fields, &names, &above, strings.to_string(cur))
			strings.builder_reset(&cur)
			just_ended = true
			i += 1
			continue
		}
		strings.write_byte(&cur, c)
		i += 1
	}
	finish(&fields, &names, &above, strings.to_string(cur))
	return fields[:]
}

// decl_signature: a declaration as the map shows it: `name :: proc(...) -> T`, a group's
// procedures, a short enum's names, a constant's value.
decl_signature :: proc(name: string, d: Decl) -> string {
	head := d.head
	body := one_line(without_comments(d.body))
	switch {
	case d.kind == .Proc && strings.trim_prefix(head, "#force_inline ") == "proc" && d.body != "":
		return fmt.tprintf("%s :: proc{{%s}}", name, body)
	case d.kind == .Proc:
		return fmt.tprintf("%s :: %s", name, head)
	case strings.has_prefix(head, "enum") && len(body) <= 80:
		return fmt.tprintf("%s :: %s {{%s}}", name, head, strings.trim_suffix(body, ","))
	case d.body != "":
		return fmt.tprintf("%s :: %s {{...}}", name, head)
	}
	return fmt.tprintf("%s :: %s", name, head)
}

// Map_Packages: the packages the map reads, parsed once each (load_package).
Map_Packages :: map[string]Parsed_Package

// load_package: dir's declarations, parsed from its files on first use. (A value, not a
// pointer into packages, which loading another package may move.)
load_package :: proc(packages: ^Map_Packages, dir: string) -> Parsed_Package {
	if dir not_in packages {
		p: Parsed_Package
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries {
			if filepath.ext(e.name) != ".odin" || strings.has_suffix(e.name, "_test.odin") {
				continue
			}
			data, err := os.read_entire_file_from_path(e.fullpath, context.allocator)
			if err ==
			   nil {parse_declarations(&p, strings.concatenate({dir, "/", e.name}), string(data))}
		}
		packages[dir] = p
	}
	return packages[dir]
}

// engine_map renders the map from GAME_API_DOC's text (games) and the packages; problems
// are what keeps it from being whole: a listed name not declared, or with no doc comment.
engine_map :: proc(games: string, packages: ^Map_Packages) -> (text: string, problems: []string) {
	found := make([dynamic]string)
	b := strings.builder_make()
	strings.write_string(
		&b,
		"# Engine map\n\n" +
		"What the engine offers a game, written from the source by `./build.sh engine-map`: do not\n" +
		"edit it (`check` fails while it is stale). The names are those [games.md](games.md) lists a\n" +
		"game may call, each with its signature and its doc comment's first sentence; games.md says\n" +
		"how they fit together. A game's code names nothing else of `server:core` (the `import`\n" +
		"lint); the `common:` packages (`game`, `base`, `worldgen`...) and `client:ui` it calls directly.\n",
	)
	for g in MAP_GAMES {
		p := load_package(packages, g.dir)
		d, ok := p.decls["Game"]
		if !ok {
			append(&found, fmt.aprintf("%s: %s declares no Game", ENGINE_MAP, g.dir))
			continue
		}
		fmt.sbprintfln(&b, "\n## `%s.Game`\n\n%s\n", g.alias, first_sentence(d.doc, "Game"))
		strings.write_string(&b, "| Hook or field | Type | What it is |\n|---|---|---|\n")
		for f in struct_fields(d.body) {
			fmt.sbprintfln(
				&b,
				"| `%s` | `%s` | %s |",
				f.name,
				table_cell(f.type),
				table_cell(first_sentence(f.doc)),
			)
		}
	}
	for list in MAP_LISTS {
		p := load_package(packages, list.dir)
		title := strings.trim_left(list.heading, "# ")
		fmt.sbprintfln(&b, "\n## `%s` (`%s.`): %s\n", list.dir, filepath.base(list.dir), title)
		shown := make(map[string]bool, context.temp_allocator)
		for name in parse_game_api(games, list.heading) {
			if shown[name] {continue}
			shown[name] = true
			d, ok := p.decls[name]
			if !ok {
				append(
					&found,
					fmt.aprintf(
						"%s: \"%s\" lists %s, which %s does not declare (`name ::`, public)",
						GAME_API_DOC,
						title,
						name,
						list.dir,
					),
				)
				continue
			}
			if d.doc == "" {
				append(
					&found,
					fmt.aprintf(
						"%s: %s has no doc comment, and %s lists it for games: write one above it (its first sentence goes in %s)",
						d.file,
						name,
						GAME_API_DOC,
						ENGINE_MAP,
					),
				)
			}
			fmt.sbprintfln(&b, "- `%s`: %s", decl_signature(name, d), first_sentence(d.doc, name))
		}
		write_mentioned_types(&b, packages, list.dir, shown)
	}
	return strings.to_string(b), found[:]
}

// write_mentioned_types lists the types the signatures of dir's listed names (shown) name
// that are not listed themselves: dir's own and those of the packages it imports.
write_mentioned_types :: proc(
	b: ^strings.Builder,
	packages: ^Map_Packages,
	dir: string,
	shown: map[string]bool,
) {
	p := load_package(packages, dir)
	mentioned := make([dynamic]string, context.temp_allocator)
	for name in shown {
		d, ok := p.decls[name]
		if !ok {continue}
		text := d.head if d.kind == .Proc else ""
		if name == "Game" {text = without_comments(d.body)}
		for word in signature_words(text) {
			if !slice.contains(mentioned[:], word) && !shown[word] {append(&mentioned, word)}
		}
	}
	slice.sort(mentioned[:])
	lines := make([dynamic]string, context.temp_allocator)
	for word in mentioned {
		alias, dot, name := strings.partition(word, ".")
		owner := p
		if dot == "" {
			name = alias
		} else {
			other, imported := p.imports[alias]
			if !imported {continue}
			owner = load_package(packages, other)
		}
		d, ok := owner.decls[name]
		if !ok || d.kind != .Type {continue}
		doc := first_sentence(d.doc, name)
		if doc == "" {
			append(&lines, fmt.tprintf("- `%s`", decl_signature(word, d)))
		} else {
			append(&lines, fmt.tprintf("- `%s`: %s", decl_signature(word, d), doc))
		}
	}
	if len(lines) == 0 {return}
	fmt.sbprintfln(b, "\nThe types these name:\n")
	for line in lines {fmt.sbprintln(b, line)}
}

// signature_words: the names in code that may be types: identifiers starting with a capital,
// alone or after one package name (`Server`, `game.Entity_Handle`), not polymorphic (`$T`).
signature_words :: proc(code: string) -> []string {
	words := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(code) {
		if !is_ident_char(code[i]) ||
		   (i > 0 && (is_ident_char(code[i - 1]) || code[i - 1] == '$')) {
			i += 1
			continue
		}
		j := i
		for j < len(code) && (is_ident_char(code[j]) || code[j] == '.') {j += 1}
		word := strings.trim_right(code[i:j], ".")
		last := word[strings.last_index_byte(word, '.') + 1:]
		if strings.count(word, ".") <= 1 && len(last) > 0 && last[0] >= 'A' && last[0] <= 'Z' {
			append(&words, word)
		}
		i = j
	}
	return words[:]
}

// table_cell: text that may stand in a table's cell.
table_cell :: proc(text: string) -> string {
	s, _ := strings.replace_all(text, "|", "\\|", context.temp_allocator)
	return s
}

// engine_map_render reads GAME_API_DOC and renders the map from the tree.
engine_map_render :: proc() -> (text: string, problems: []string, ok: bool) {
	games, err := os.read_entire_file_from_path(GAME_API_DOC, context.allocator)
	if err != nil {
		fmt.eprintfln("map    %s: unreadable", GAME_API_DOC)
		return
	}
	packages := make(Map_Packages)
	text, problems = engine_map(string(games), &packages)
	return text, problems, true
}

// engine_map_write: `build engine-map` writes the map.
engine_map_write :: proc() -> bool {
	text, problems := engine_map_render() or_return
	if os.write_entire_file(ENGINE_MAP, transmute([]u8)text) != nil {
		fmt.eprintfln("map    could not write %s", ENGINE_MAP)
		return false
	}
	for p in problems {fmt.eprintln(p)}
	fmt.printfln("map    %s written (%d lines)", ENGINE_MAP, strings.count(text, "\n"))
	return len(problems) == 0
}

// engine_map_lint: check's part. The map is what engine_map renders now, and every name it
// lists is declared and documented.
engine_map_lint :: proc() -> bool {
	text, problems := engine_map_render() or_return
	ok := len(problems) == 0
	for p in problems {fmt.eprintln(p)}
	on_disk, err := os.read_entire_file_from_path(ENGINE_MAP, context.allocator)
	if err != nil || string(on_disk) != text {
		fmt.eprintfln(
			"map    %s is stale (the engine's declarations, their doc comments or %s's lists changed): `./build.sh engine-map` rewrites it",
			ENGINE_MAP,
			GAME_API_DOC,
		)
		ok = false
	}
	if ok {fmt.printfln("map    %s is the source's: every name a game may call is declared and documented", ENGINE_MAP)}
	return ok
}
