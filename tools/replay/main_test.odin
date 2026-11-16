package replay

import "core:testing"

import "common:game"
import "common:protocol"
import "common:starmap"

// welcome_trace: a trace's records with the server's Welcome naming a game.
@(private = "file")
welcome_trace :: proc(played: string) -> []protocol.Trace_Record {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	welcome := protocol.Welcome {
		protocol    = protocol.PROTOCOL_VERSION,
		tick_rate   = game.TICK_RATE,
		view_radius = 4,
		view_height = 2,
		rules       = game.RULES_DEFAULTS,
		address     = {starmap.EARTH_GALAXY, starmap.EARTH_WORLD},
		game        = played,
	}
	protocol.encode_server(&w, welcome)
	records := make([]protocol.Trace_Record, 1, context.temp_allocator)
	records[0] = {0, .Server, w.buf[:]}
	return records
}

// A trace replays with the game its session played (before: always the default game, so
// another game's trace replayed without its rules); a game this build lacks replays as
// the default one.
@(test)
test_replay_plays_the_traces_game :: proc(t: ^testing.T) {
	base_registry = game.registry_base(context.temp_allocator)
	defer base_registry = nil
	testing.expect_value(t, trace_game(welcome_trace("flood")).id, "flood")
	testing.expect(
		t,
		trace_game(welcome_trace("flood")).tick != nil,
		"flood's rules are not there",
	)
	testing.expect_value(t, trace_game(welcome_trace("nonesuch")).id, game.DEFAULT_GAME)
	testing.expect_value(t, trace_game({}).id, game.DEFAULT_GAME)
}
