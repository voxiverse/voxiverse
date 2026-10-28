package server

import "core:mem"
import "core:testing"

import "../common/game"

// State_Rx: a test client's decoder of the server's State and Snapshot
// messages (the schema and the receiver a real client keeps in its session).
@(private)
State_Rx :: struct {
	schema:    game.Schema,
	rx:        game.Receiver,
	allocator: mem.Allocator,
}

@(private)
state_rx_init :: proc(r: ^State_Rx, allocator := context.allocator) {
	r.allocator = allocator
	context.allocator = allocator
	r.schema = game.game_schema(allocator)
	game.receiver_init(&r.rx, &r.schema, test_reg(), allocator)
}

@(private)
state_rx_destroy :: proc(r: ^State_Rx) {
	context.allocator = r.allocator
	game.receiver_destroy(&r.rx)
	game.schema_destroy(&r.schema)
}

// state_rx_take decodes a State or Snapshot message (anything else yields
// nothing); the entries are views valid until the next call.
@(private)
state_rx_take :: proc(t: ^testing.T, r: ^State_Rx, m: game.Server_Message) -> []game.Received {
	context.allocator = r.allocator
	got := make([dynamic]game.Received, context.temp_allocator)
	#partial switch v in m {
	case game.State_Message:
		testing.expect(t, game.receive_state(&r.rx, v.data, &got), "invalid State message")
	case game.Snapshot_Message:
		testing.expect(t, game.receive_snapshot(&r.rx, v.data, &got), "invalid Snapshot message")
	}
	return got[:]
}
