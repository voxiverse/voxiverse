package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The lists of games (docs/games.md): the driver writes them from the folders in games/, so
// adding a game edits no list. They are the packages `generated:games` (every game's server
// part: SERVER) and `generated:games/client` (every game's client part: CLIENT), which only
// the main packages import, the client list client/main alone (the import lint), under
// build/: generated, never committed.

// GENERATED_DIR is the root of the collection `generated`: code the driver writes.
GENERATED_DIR :: "build/generated"

// Game_List: one list the driver writes: where, its package, the part of every game it
// lists (a package `games/<game>/<part>`, whose GAME it holds), and the engine's type
// of that GAME.
Game_List :: struct {
	path:   string,
	pkg:    string,
	part:   string,
	name:   string, // the constant: SERVER, CLIENT
	engine: string, // the package that declares the type: "server:core"
	type:   string, // "core.Game"
}

GAME_LISTS :: [?]Game_List {
	{
		path = GENERATED_DIR + "/games/games.odin",
		pkg = "games",
		part = "server",
		name = "SERVER",
		engine = "server:core",
		type = "core.Game",
	},
	{
		path = GENERATED_DIR + "/games/client/games.odin",
		pkg = "games_client",
		part = "client",
		name = "CLIENT",
		engine = "client:engine",
		type = "engine.Game",
	},
}

// games_with: the games that have a part (a package `games/<game>/<part>`), by folder
// name, sorted.
games_with :: proc(part: string) -> []string {
	packages, _ := game_packages()
	names := make([dynamic]string)
	for pkg in packages {
		rest := pkg[len(GAMES_DIR) + 1:]
		game, _ := game_path_of(rest)
		if rest == strings.concatenate({game, "/", part}, context.temp_allocator) {
			append(&names, game)
		}
	}
	return names[:]
}

// game_list_text: the list of the named games' parts (each `games/<game>/<part>` package's
// GAME, imported as `<game>_<part>`), in that order. The #assert keeps a game's id its
// folder's name.
game_list_text :: proc(list: Game_List, names: []string) -> string {
	b := strings.builder_make()
	fmt.sbprintf(
		&b,
		"// Written by the build driver (tools/build/games.odin) from the folders in games/.\n" +
		"// Not committed and not edited: a new game is a new folder (docs/games.md).\n" +
		"package %s\n\nimport \"%s\"\n",
		list.pkg,
		list.engine,
	)
	if len(names) > 0 {strings.write_byte(&b, '\n')}
	for name in names {
		fmt.sbprintfln(&b, "import %s_%s \"games:%s/%s\"", name, list.part, name, list.part)
	}
	fmt.sbprintf(
		&b,
		"\n// %s: every game's %s part, by folder name.\n%s :: []%s{{",
		list.name,
		list.part,
		list.name,
		list.type,
	)
	for name, i in names {
		if i > 0 {strings.write_string(&b, ", ")}
		fmt.sbprintf(&b, "%s_%s.GAME", name, list.part)
	}
	strings.write_string(&b, "}\n")
	for name in names {
		fmt.sbprintf(
			&b,
			"\n#assert(%s_%s.GAME.id == \"%s\", \"a game's id is its folder's name\")",
			name,
			list.part,
			name,
		)
	}
	if len(names) > 0 {strings.write_byte(&b, '\n')}
	return strings.to_string(b)
}

// write_game_lists writes every list (GAME_LISTS) for the games there are now, each when
// it changed.
write_game_lists :: proc() -> bool {
	for list in GAME_LISTS {
		text := game_list_text(list, games_with(list.part))
		if old, err := os.read_entire_file_from_path(list.path, context.allocator);
		   err == nil && string(old) == text {continue}
		dir := filepath.dir(list.path)
		if err := os.make_directory_all(dir); err != nil && err != .Exist {
			fmt.eprintfln("build: cannot make %s: %v", dir, err)
			return false
		}
		if err := os.write_entire_file(list.path, transmute([]u8)text); err != nil {
			fmt.eprintfln("build: cannot write %s: %v", list.path, err)
			return false
		}
	}
	return true
}
