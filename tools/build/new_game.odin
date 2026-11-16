package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// `build new-game <id>` stamps out the smallest working game in games/<id>/ (docs/
// games.md): its shared package (INFO, a record, a text table), its server part (a start
// hook and one rule: a block a player breaks is a point), its client part (a line of HUD
// with the points), a test beside each and a README. Right after it, `build check` and
// `build test games/<id> games/<id>/server games/<id>/client` pass and `run -- --game <id>`
// plays it: the driver finds a game by its folder, so nothing outside it changes, and its
// files are known to git (`git add --intent-to-add`: not staged), as check's scratch lint
// asks of every file outside build/. The
// files are game_template/'s, `#load`ed, with @id@ the id, @Name@ the name players read
// and @NAME@ the HUD's. It refuses an id that is not a game's (game_id_refusal) or whose
// folder is there.

Game_Template_File :: struct {
	path: string, // under games/<id>/
	text: string,
}

GAME_TEMPLATE :: [?]Game_Template_File {
	{"README.md", #load("game_template/readme.txt", string)},
	{"rules.odin", #load("game_template/rules.txt", string)},
	{"records.odin", #load("game_template/records.txt", string)},
	{"text.odin", #load("game_template/text.txt", string)},
	{"text_test.odin", #load("game_template/text_test.txt", string)},
	{"server/game.odin", #load("game_template/server.txt", string)},
	{"server/game_test.odin", #load("game_template/server_test.txt", string)},
	{"client/game.odin", #load("game_template/client.txt", string)},
	{"client/game_test.odin", #load("game_template/client_test.txt", string)},
}

// GAME_ID_TAKEN: ids a game cannot have although they are of its form: Odin's keywords
// (its packages are named for it) and the packages its parts import (`package game`
// importing `common:game`), and the parts' own folder names.
GAME_ID_TAKEN :: []string {
	"asm",
	"auto_cast",
	"bit_field",
	"bit_set",
	"break",
	"case",
	"cast",
	"context",
	"continue",
	"defer",
	"distinct",
	"do",
	"dynamic",
	"else",
	"enum",
	"fallthrough",
	"for",
	"foreign",
	"if",
	"import",
	"in",
	"map",
	"matrix",
	"not_in",
	"or_break",
	"or_continue",
	"or_else",
	"or_return",
	"package",
	"proc",
	"return",
	"struct",
	"switch",
	"transmute",
	"typeid",
	"union",
	"using",
	"when",
	"where",
	"base",
	"client",
	"core",
	"engine",
	"game",
	"log",
	"playtest",
	"protocol",
	"server",
	"testing",
	"ui",
}

// MAX_GAME_ID: common/game's (the driver imports no game code).
MAX_GAME_ID :: 32

new_game :: proc(args: []string) -> bool {
	if len(args) != 1 {
		fmt.eprintln(
			"build: new-game <id>: a new game's id, its folder's name (singular snake_case)",
		)
		return false
	}
	id := args[0]
	if !new_game_write(GAMES_DIR, id) {return false}
	dir := path_join({GAMES_DIR, id})
	if have_odinfmt() {capture({"odinfmt", "-w", dir})} 	// (a long id may wrap a line)
	// Known to git (not staged): check's scratch lint refuses an untracked file.
	if _, added := capture({"git", "add", "--intent-to-add", dir}); !added {
		fmt.eprintfln("build: new-game: `git add --intent-to-add %s` failed: add it yourself", dir)
	}
	fmt.printfln(
		"made   %s: README.md, rules.odin, records.odin, text.odin, server/, client/ (git add -N)",
		dir,
	)
	fmt.printfln(
		"next   ./build.sh check; ./build.sh test %s %s/server %s/client; ./build.sh run -- --game %s",
		dir,
		dir,
		dir,
		id,
	)
	return true
}

// game_id_refusal: why id cannot be a new game's ("": it can). An id is a game's folder
// name, singular snake_case, as common/game's game_id_valid has it: a lower-case letter,
// then lower-case letters, digits and underscores, at most MAX_GAME_ID; and none of
// GAME_ID_TAKEN.
game_id_refusal :: proc(id: string) -> string {
	if id == "" || len(id) > MAX_GAME_ID {
		return fmt.tprintf("a game's id is 1 to %d characters", MAX_GAME_ID)
	}
	for ch, i in transmute([]u8)id {
		switch ch {
		case 'a' ..= 'z':
		case '0' ..= '9', '_':
			if i == 0 {return "a game's id starts with a lower-case letter"}
		case:
			return "a game's id is lower-case letters, digits and underscores (snake_case)"
		}
	}
	for taken in GAME_ID_TAKEN {
		if id == taken {
			return fmt.tprintf("%q is a keyword or a package its parts import", id)
		}
	}
	return ""
}

// game_name_of: the name players read, from the id: words for its underscores, each
// with a capital (`ice_race`: "Ice Race").
game_name_of :: proc(id: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	start := true
	for ch in transmute([]u8)id {
		switch {
		case ch == '_':
			strings.write_byte(&b, ' ')
			start = true
		case start && ch >= 'a' && ch <= 'z':
			strings.write_byte(&b, ch - 'a' + 'A')
			start = false
		case:
			strings.write_byte(&b, ch)
			start = false
		}
	}
	return strings.to_string(b)
}

// new_game_text: a template file's text for the game id.
new_game_text :: proc(text, id: string, allocator := context.allocator) -> string {
	name := game_name_of(id, context.temp_allocator)
	out, _ := strings.replace_all(text, "@id@", id, context.temp_allocator)
	out, _ = strings.replace_all(out, "@Name@", name, context.temp_allocator)
	out, _ = strings.replace_all(
		out,
		"@NAME@",
		strings.to_upper(name, context.temp_allocator),
		allocator,
	)
	return out
}

// new_game_write writes the game id's files under games_dir/<id>/ (false, and nothing
// left, when id is refused, its folder is there, or a file cannot be written).
new_game_write :: proc(games_dir, id: string) -> bool {
	if why := game_id_refusal(id); why != "" {
		fmt.eprintfln("build: new-game %s: %s", id, why)
		return false
	}
	dir := path_join({games_dir, id})
	if os.exists(dir) {
		fmt.eprintfln("build: new-game %s: %s is there already", id, dir)
		return false
	}
	for f in GAME_TEMPLATE {
		path := path_join({dir, f.path})
		text := new_game_text(f.text, id, context.temp_allocator)
		os.make_directory_all(filepath.dir(path))
		if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
			fmt.eprintfln("build: new-game %s: cannot write %s: %v", id, path, err)
			os.remove_all(dir)
			return false
		}
	}
	return true
}
