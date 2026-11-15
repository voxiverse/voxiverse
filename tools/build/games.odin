package build

import "core:fmt"
import "core:os"
import "core:strings"

// The list of games (docs/games.md): the driver writes it from the folders in games/, so
// adding a game edits no list. It is the package `generated:games`, which only the main
// packages import (the import lint), under build/: generated, never committed.

// GENERATED_DIR is the root of the collection `generated`: code the driver writes.
GENERATED_DIR :: "build/generated"
GAME_LIST_DIR :: GENERATED_DIR + "/games"
GAME_LIST :: GAME_LIST_DIR + "/games.odin"

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

// game_list_text: the list of the named games' server parts (each `games/<game>/server`
// package's GAME), in that order. The #assert keeps a game's id its folder's name.
game_list_text :: proc(names: []string) -> string {
	b := strings.builder_make()
	strings.write_string(
		&b,
		"// Written by the build driver (tools/build/games.odin) from the folders in games/.\n" +
		"// Not committed and not edited: a new game is a new folder (docs/games.md).\n" +
		"package games\n\nimport \"server:core\"\n",
	)
	if len(names) > 0 {strings.write_byte(&b, '\n')}
	for name in names {fmt.sbprintfln(&b, "import %s_server \"games:%s/server\"", name, name)}
	strings.write_string(
		&b,
		"\n// SERVER: every game's server part, by folder name.\nSERVER :: []core.Game{",
	)
	for name, i in names {
		if i > 0 {strings.write_string(&b, ", ")}
		fmt.sbprintf(&b, "%s_server.GAME", name)
	}
	strings.write_string(&b, "}\n")
	for name in names {
		fmt.sbprintf(
			&b,
			"\n#assert(%s_server.GAME.id == \"%s\", \"a game's id is its folder's name\")",
			name,
			name,
		)
	}
	if len(names) > 0 {strings.write_byte(&b, '\n')}
	return strings.to_string(b)
}

// write_game_list writes GAME_LIST for the games there are now, when it changed.
write_game_list :: proc() -> bool {
	text := game_list_text(games_with("server"))
	if old, err := os.read_entire_file_from_path(GAME_LIST, context.allocator);
	   err == nil && string(old) == text {return true}
	if err := os.make_directory_all(GAME_LIST_DIR); err != nil && err != .Exist {
		fmt.eprintfln("build: cannot make %s: %v", GAME_LIST_DIR, err)
		return false
	}
	if err := os.write_entire_file(GAME_LIST, transmute([]u8)text); err != nil {
		fmt.eprintfln("build: cannot write %s: %v", GAME_LIST, err)
		return false
	}
	return true
}
