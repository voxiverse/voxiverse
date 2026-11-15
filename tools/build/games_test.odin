package build

import "core:strings"
import "core:testing"

@(test)
test_game_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	none := game_list_text({})
	testing.expect(t, strings.contains(none, "SERVER :: []core.Game{}\n"))
	testing.expect(t, !strings.contains(none, "games:"))
	two := game_list_text({"stopwatch", "tag"})
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
}
