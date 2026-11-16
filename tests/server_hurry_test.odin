package tests

import "core:testing"
import "core:time"

import "common:game"
import "server:core"

// core.hurry: the server's own thread runs the ticks asked for back to back, in far less
// than their time (a script's `ticks`), then goes back to its pace.
@(test)
test_server_hurries :: proc(t: ^testing.T) {
	s := new(core.Server)
	defer free(s)
	config := core.harness_world()
	config.game, config.workers = core.HARNESS_GAME, 1
	if !testing.expect(t, core.start(s, config, {})) {return}
	defer testing.expect(t, core.stop(s))
	HURRIED :: 10 * game.TICK_RATE // ten seconds of play
	began := time.tick_now()
	core.hurry(s, HURRIED)
	for core.hurrying(s) > 0 && time.tick_since(began) < 10 * time.Second {
		time.sleep(time.Millisecond)
	}
	took := time.tick_since(began)
	testing.expect_value(t, core.hurrying(s), 0)
	testing.expectf(t, took < 5 * time.Second, "%d ticks hurried took %v", HURRIED, took)
}
