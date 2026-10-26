package server

import "../game"
import "../netcode"

// What the server tells a playing client about the world, as records of the
// schema's kinds and one-off events (game/state_kinds.odin). The server code
// says what the client should see now (a put, an event); replica_flush, once
// per client at the end of the tick, turns that into State messages
// (reliable: deltas against what the client was last sent) and Snapshot
// messages (unreliable: deltas against the newest snapshot it acknowledged).

// state_put sets c's record of kind (under key) for this tick. Several puts
// in a tick coalesce: the last wins. Keyed kinds are views: a record not put in
// a tick is removed.
@(private)
state_put :: proc(s: ^Server, c: ^Client, kind: game.State_Kind, value: ^$T, key := game.Key{}) {
	assert(s.schema.kinds[kind].value == T, "a record of the wrong type")
	if c.tx.schema == nil {return}
	game.sender_put(&c.tx, int(kind), key, value)
}

// state_remove removes a record by hand (a keyed kind's records go by
// themselves when they are not put).
@(private)
state_remove :: proc(c: ^Client, kind: game.State_Kind, key := game.Key{}) {
	if c.tx.schema == nil {return}
	game.sender_remove(&c.tx, int(kind), key)
}

// event_send queues a one-off event for c.
@(private)
event_send :: proc(s: ^Server, c: ^Client, kind: game.Event_Kind, value: ^$T) {
	assert(s.schema.kinds[game.kind_of_event(kind)].value == T, "an event of the wrong type")
	if c.tx.schema == nil {return}
	game.sender_event(&c.tx, game.kind_of_event(kind), value)
}

// event_broadcast queues an event for every playing client (in world, if
// given).
@(private)
event_broadcast :: proc(s: ^Server, kind: game.Event_Kind, value: ^$T, world: ^World = nil) {
	for &c in s.clients {
		if c.state == .Playing && (world == nil || c.world == world) {
			event_send(s, &c, kind, value)
		}
	}
}

// replicate_tick puts what every client sees of the world at the end of a
// tick: who is there, the entities, its inventory, the rules, the clock when
// it is due. (Most of it is the same as last tick and costs nothing: the
// sender sends only what differs from what the client was last sent.)
@(private)
replicate_tick :: proc(s: ^Server, c: ^Client) {
	players_put(s, c)
	entities_put(s, c)
	inv := game.Inventory_State{c.inv_acked, c.inventory}
	state_put(s, c, .Inventory, &inv)
	c.inv_changed = false
	rules := c.world.rules
	state_put(s, c, .Rules, &rules)
	if c.clock_pending || s.time_stopped {
		c.clock_pending = false
		clock := game.Clock{c.world.clock, u32(s.tick)}
		state_put(s, c, .Clock, &clock)
	}
}

// clock_resend: the time was set, or what it means changed: everyone in w is
// told the clock again at the end of the tick.
@(private)
clock_resend :: proc(s: ^Server, w: ^World) {
	for &c in s.clients {
		if c.state == .Playing && c.world == w {c.clock_pending = true}
	}
}

// replica_seed gives c's copy the value the client already has from Welcome
// or World_Changed: the world's rules, so they travel only when one changes.
@(private)
replica_seed :: proc(s: ^Server, c: ^Client) {
	rules := c.world.rules
	game.sender_seed(&c.tx, int(game.State_Kind.Rules), &rules)
}

// replica_flush sends c what was put and queued since the last flush.
@(private)
replica_flush :: proc(s: ^Server, c: ^Client) {
	if c.tx.schema == nil || c.link == nil {return}
	out := make([dynamic]game.Outgoing, context.temp_allocator)
	game.sender_flush(&c.tx, u32(s.tick), game.block_of_position(c.player.position), &out)
	for o in out {send_bytes(s, c, o.data, reliable = !o.snapshot)}
}

// send_bytes sends an encoded message to a client (the pipe, or the network).
@(private)
send_bytes :: proc(s: ^Server, c: ^Client, data: []u8, reliable: bool) {
	switch l in c.link {
	case Local:
		game.send(s.local, data)
	case netcode.Peer_Id:
		netcode.host_send(&s.host, l, data, reliable)
	}
}
