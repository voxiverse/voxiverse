package build

import "core:os"
import "core:strings"
import "core:testing"

// A game stamped into a tree of its own: every file of the template, for this id, with
// nothing of the template's left; a second one with the same id, or a bad id, is refused
// and leaves nothing.
@(test)
test_new_game_writes_a_game :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	DIR :: "build/tmp/new_game_test"
	os.remove_all(DIR)
	defer os.remove_all(DIR)
	os.make_directory_all(DIR)
	if !testing.expect(t, new_game_write(DIR, "ice_race")) {return}
	read :: proc(path: string) -> string {
		data, _ := os.read_entire_file_from_path(
			strings.concatenate({DIR, "/ice_race/", path}),
			context.temp_allocator,
		)
		return string(data)
	}
	for f in GAME_TEMPLATE {
		text := read(f.path)
		testing.expectf(t, text != "", "%s not written", f.path)
		for placeholder in ([]string{"@id@", "@Name@", "@NAME@"}) {
			testing.expectf(
				t,
				!strings.contains(text, placeholder),
				"%s keeps %s",
				f.path,
				placeholder,
			)
		}
	}
	expect_has :: proc(t: ^testing.T, text, part: string, loc := #caller_location) {
		testing.expectf(t, strings.contains(text, part), "no %q in\n%s", part, text, loc = loc)
	}
	rules := read("rules.odin")
	expect_has(t, rules, "package ice_race\n")
	expect_has(t, rules, "id          = \"ice_race\",\n\tname        = \"Ice Race\",")
	expect_has(t, read("records.odin"), "{name = \"ice_race.points\", value = Points}")
	expect_has(t, read("text.odin"), ".Points_Line = \"ICE RACE  {0} points\"")
	server := read("server/game.odin")
	expect_has(t, server, "package ice_race_server\n")
	expect_has(t, server, "import \"games:ice_race\"\n")
	expect_has(t, server, "GAME :: core.Game {\n\tinfo          = ice_race.INFO,")
	expect_has(t, server, "start         = start,")
	expect_has(t, read("server/game_test.odin"), "playtest.host_record(rig, ice_race.Points)")
	client := read("client/game.odin")
	expect_has(t, client, "package ice_race_client\n")
	expect_has(t, client, "GAME :: engine.Game {\n\tinfo     = ice_race.INFO,")
	expect_has(t, client, "hud      = hud,")
	expect_has(
		t,
		read("client/game_test.odin"),
		"import ice_race_server \"games:ice_race/server\"",
	)
	expect_has(t, read("README.md"), "# Ice Race\n")

	// Refused: the folder is there, an id not of a game's form, a keyword, an import.
	testing.expect(t, !new_game_write(DIR, "ice_race"), "wrote over a game")
	testing.expect(t, read("rules.odin") == rules, "a refusal changed the game")
	for id in ([]string{"", "Ice", "1st", "ice-race", "a/b", "proc", "game", "core"}) {
		testing.expectf(t, game_id_refusal(id) != "", "%q not refused", id)
		testing.expectf(t, !new_game_write(DIR, id), "%q written", id)
	}
	testing.expect_value(t, game_id_refusal("tag2"), "")
	listed, _ := os.read_all_directory_by_path(DIR, context.temp_allocator)
	testing.expect_value(t, len(listed), 1)
}

@(test)
test_game_name_of :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, game_name_of("tag"), "Tag")
	testing.expect_value(t, game_name_of("ice_race"), "Ice Race")
	testing.expect_value(t, game_name_of("f1_cup"), "F1 Cup")
}
