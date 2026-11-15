package build

import "core:strings"
import "core:testing"

@(test)
test_game_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	server, client := GAME_LISTS[0], GAME_LISTS[1]
	none := game_list_text(server, {})
	testing.expect(t, strings.contains(none, "package games\n\nimport \"server:core\"\n"))
	testing.expect(t, strings.contains(none, "SERVER :: []core.Game{}\n"))
	testing.expect(t, !strings.contains(none, "games:"))
	two := game_list_text(server, {"stopwatch", "tag"})
	testing.expect(
		t,
		strings.contains(two, "import stopwatch_server \"games:stopwatch/server\"\n"),
	)
	testing.expect(t, strings.contains(two, "import tag_server \"games:tag/server\"\n"))
	testing.expect(
		t,
		strings.contains(two, "SERVER :: []core.Game{stopwatch_server.GAME, tag_server.GAME}\n"),
	)
	testing.expect(t, strings.contains(two, "#assert(tag_server.GAME.id == \"tag\""))
	// The client's list: client/main's alone, so the dedicated server links no client code.
	clients := game_list_text(client, {"tag"})
	testing.expect(
		t,
		strings.contains(clients, "package games_client\n\nimport \"client:engine\"\n"),
	)
	testing.expect(t, strings.contains(clients, "import tag_client \"games:tag/client\"\n"))
	testing.expect(t, strings.contains(clients, "CLIENT :: []engine.Game{tag_client.GAME}\n"))
	testing.expect(t, strings.contains(clients, "#assert(tag_client.GAME.id == \"tag\""))
}
