package build

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_game_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	server, client := GAME_LISTS[0], GAME_LISTS[1]
	none := game_list_text(server, {})
	testing.expect(t, strings.contains(none, "package games\n\nimport \"server:core\"\n"))
	testing.expect(t, strings.contains(none, "@(rodata)\nSERVER := []core.Game{}\n"))
	testing.expect(t, !strings.contains(none, "games:"))
	two := game_list_text(server, {"stopwatch", "tag"})
	testing.expect(
		t,
		strings.contains(two, "import stopwatch_server \"games:stopwatch/server\"\n"),
	)
	testing.expect(t, strings.contains(two, "import tag_server \"games:tag/server\"\n"))
	testing.expect(
		t,
		strings.contains(
			two,
			"@(rodata)\nSERVER := []core.Game{stopwatch_server.GAME, tag_server.GAME}\n",
		),
	)
	testing.expect(t, strings.contains(two, "#assert(tag_server.GAME.id == \"tag\""))
	// The client's list: client/main's alone, so the dedicated server links no client code.
	clients := game_list_text(client, {"tag"})
	testing.expect(
		t,
		strings.contains(clients, "package games_client\n\nimport \"client:engine\"\n"),
	)
	testing.expect(t, strings.contains(clients, "import tag_client \"games:tag/client\"\n"))
	testing.expect(
		t,
		strings.contains(clients, "@(rodata)\nCLIENT := []engine.Game{tag_client.GAME}\n"),
	)
	testing.expect(t, strings.contains(clients, "#assert(tag_client.GAME.id == \"tag\""))
}

// Shelving: the SHELVED file in a game's folder alone decides (nothing outside the folder
// names a shelved game); a shelved game is in neither list of games nor among the test
// packages that run, and every package of it is still type-checked; a built game is in
// all three.
@(test)
test_shelved_games_are_checked_not_built :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	built, shelved := games_found()
	testing.expect(t, len(built) > 0, "no game is built")
	packages, tested := game_packages()
	checked, run := all_packages(), all_test_packages()
	servers, clients := games_with("server"), games_with("client")
	for game in slice.concatenate([][]string{built, shelved}) {
		marked := os.exists(path_join({GAMES_DIR, game, SHELVED}))
		testing.expectf(
			t,
			marked == slice.contains(shelved, game),
			"%s: the marker does not decide",
			game,
		)
		testing.expectf(t, slice.contains(servers, game) != marked, "%s: in the server list", game)
		testing.expectf(t, slice.contains(clients, game) != marked, "%s: in the client list", game)
		for pkg in packages {
			if game_of(pkg) != game {continue}
			testing.expectf(t, slice.contains(checked, pkg), "%s is not type-checked", pkg)
		}
		for pkg in tested {
			if game_of(pkg) != game {continue}
			testing.expectf(
				t,
				slice.contains(run, pkg) != marked,
				"%s: whether its tests run",
				pkg,
			)
		}
	}
	text := game_list_text(GAME_LISTS[0], servers)
	for game in shelved {
		testing.expectf(
			t,
			!strings.contains(text, strings.concatenate({"\"games:", game, "/"})),
			"%s is imported",
			game,
		)
	}
}
