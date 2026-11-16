package core

import "core:mem"
import "core:testing"

import "common:protocol"

// State_Rx: a test client's decoder of the server's State and Snapshot
// messages (the schema and the receiver a real client keeps in its session).
@(private)
State_Rx :: struct {
	schema:    protocol.Schema,
	rx:        protocol.Receiver,
	allocator: mem.Allocator,
}

@(private)
state_rx_init :: proc(r: ^State_Rx, allocator := context.allocator) {
	r.allocator = allocator
	context.allocator = allocator
	r.schema = protocol.game_schema(allocator = allocator)
	protocol.receiver_init(&r.rx, &r.schema, test_reg(), allocator)
}

@(private)
state_rx_destroy :: proc(r: ^State_Rx) {
	context.allocator = r.allocator
	protocol.receiver_destroy(&r.rx)
	protocol.schema_destroy(&r.schema)
}

// state_rx_take decodes a State or Snapshot message (anything else yields
// nothing); the entries are views valid until the next call.
@(private)
state_rx_take :: proc(
	t: ^testing.T,
	r: ^State_Rx,
	m: protocol.Server_Message,
) -> []protocol.Received {
	context.allocator = r.allocator
	got := make([dynamic]protocol.Received, context.temp_allocator)
	#partial switch v in m {
	case protocol.State_Message:
		testing.expect(t, protocol.receive_state(&r.rx, v.data, &got), "invalid State message")
	case protocol.Snapshot_Message:
		testing.expect(
			t,
			protocol.receive_snapshot(&r.rx, v.data, &got),
			"invalid Snapshot message",
		)
	}
	return got[:]
}
