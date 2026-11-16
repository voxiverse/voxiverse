package netdump

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

// A trace of a session that played a game is read with that game's state kinds (before,
// with the engine's alone: every State message carrying the game's records was counted as
// one that does not decode).
@(test)
test_netdump_reads_the_games_kinds :: proc(t: ^testing.T) {
	base_registry = game.registry_base(context.temp_allocator)
	defer base_registry = nil
	scratch := new(game.Block_Array)
	defer free(scratch)
	flood := trace_schema(welcome_trace("flood"), scratch)
	defer protocol.schema_destroy(&flood)
	found := false
	for k in flood.kinds {found ||= k.name == "flood.round"}
	testing.expect(t, found, "the game's kinds are not in the schema")
	none := trace_schema(welcome_trace("nonesuch"), scratch)
	defer protocol.schema_destroy(&none)
	testing.expect_value(
		t,
		len(none.kinds),
		len(protocol.game_schema(allocator = context.temp_allocator).kinds),
	)
}
