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
	testing.expect(t, strings.contains(two, "import game_stopwatch \"games:stopwatch\"\n"))
	testing.expect(t, strings.contains(two, "import game_tag \"games:tag\"\n"))
	testing.expect(
		t,
		strings.contains(two, "SERVER :: []core.Game{game_stopwatch.GAME, game_tag.GAME}\n"),
	)
	testing.expect(t, strings.contains(two, "#assert(game_tag.GAME.id == \"tag\""))
}
