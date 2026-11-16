package core

import "common:game"
import "common:netcode"

// What the server tells a playing client about the world, as records of the
// schema's kinds and one-off events (common/game/state_kinds.odin). The server code
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

// event_send queues a one-off event for c.
@(private)
event_send :: proc(s: ^Server, c: ^Client, kind: game.Event_Kind, value: ^$T) {
	assert(s.schema.kinds[game.kind_of_event(kind)].value == T, "an event of the wrong type")
	if c.tx.schema == nil {return}
	game.sender_event(&c.tx, game.kind_of_event(kind), value)
}

// game_put sets c's record of the game's kind whose value type is T (Game.kinds) for
// this tick, under key for a keyed kind: state_put for a game. The type names the
// kind, so a game's code holds no kind number.
game_put :: proc(s: ^Server, c: ^Client, value: ^$T, key := game.Key{}) {
	kind, found := game.game_kind(&s.schema, T)
	assert(found && !s.schema.kinds[kind].is_event, "not a state kind of the game's")
	if c.tx.schema == nil {return}
	game.sender_put(&c.tx, kind, key, value)
}

// game_event queues a one-off event of the game's kind whose value type is T for c:
// event_send for a game.
game_event :: proc(s: ^Server, c: ^Client, value: ^$T) {
	kind, found := game.game_kind(&s.schema, T)
	assert(found && s.schema.kinds[kind].is_event, "not an event kind of the game's")
	if c.tx.schema == nil {return}
	game.sender_event(&c.tx, kind, value)
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
	island_put(s, c)
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

// Request: one of the game's requests from a player's client part (Game.request): its
// kind and its value, valid for the hook's call; request_value reads it as its type.
Request :: struct {
	kind:  int,
	value: rawptr,
}

// request_value: r's value as ^T when r is of the game's request kind whose value type
// is T: a game's code holds no kind number and no cast.
request_value :: proc(s: ^Server, r: Request, $T: typeid) -> (value: ^T, ok: bool) {
	kind := game.request_kind(&s.schema, T) or_return
	if r.kind != kind {return nil, false}
	return (^T)(r.value), true
}

// request_receive: a Game_Request from c, decoded and checked, to the game's hook. One
// that does not decode is the client's bug or an attack: c is refused.
@(private)
request_receive :: proc(s: ^Server, c: ^Client, r: game.Game_Request) {
	g := &s.config.game
	value, ok := game.request_decode(&s.schema, s.registry, r)
	if !ok {
		disconnect(s, c, "a game request that does not decode")
		return
	}
	if g.request != nil {g.request(s, c, {int(r.kind), value})}
}

// harness_request: c sends the game's request value, through the wire's encoding and
// the server's checks, as a client part's game_request does (tests).
harness_request :: proc(s: ^Server, c: ^Client, value: ^$T) {
	kind, found := game.request_kind(&s.schema, T)
	assert(found, "not a request kind of the game's")
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.request_encode(&w, &s.schema, kind, value)
	request_receive(s, c, {u16(kind), 0, w.buf[:]})
}
