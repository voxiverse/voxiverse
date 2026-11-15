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

// game_names: the games, by folder name (the top-level packages under games/), sorted.
game_names :: proc() -> []string {
	packages, _ := game_packages()
	names := make([dynamic]string)
	for pkg in packages {
		name := pkg[len(GAMES_DIR) + 1:]
		if strings.index_byte(name, '/') < 0 {append(&names, name)}
	}
	return names[:]
}

// game_list_text: the list of the named games' server sides (each package's GAME), in
// that order. The #assert keeps a game's id its folder's name.
game_list_text :: proc(names: []string) -> string {
	b := strings.builder_make()
	strings.write_string(
		&b,
		"// Written by the build driver (tools/build/games.odin) from the folders in games/.\n" +
		"// Not committed and not edited: a new game is a new folder (docs/games.md).\n" +
		"package games\n\nimport \"server:core\"\n",
	)
	if len(names) > 0 {strings.write_byte(&b, '\n')}
	for name in names {fmt.sbprintfln(&b, "import game_%s \"games:%s\"", name, name)}
	strings.write_string(
		&b,
		"\n// SERVER: every game's server side, by folder name.\nSERVER :: []core.Game{",
	)
	for name, i in names {
		if i > 0 {strings.write_string(&b, ", ")}
		fmt.sbprintf(&b, "game_%s.GAME", name)
	}
	strings.write_string(&b, "}\n")
	for name in names {
		fmt.sbprintf(
			&b,
			"\n#assert(game_%s.GAME.id == \"%s\", \"a game's id is its folder's name\")",
			name,
			name,
		)
	}
	if len(names) > 0 {strings.write_byte(&b, '\n')}
	return strings.to_string(b)
}

// write_game_list writes GAME_LIST for the games there are now, when it changed.
write_game_list :: proc() -> bool {
	text := game_list_text(game_names())
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
