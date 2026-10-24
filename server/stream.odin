package server

import "core:math"
import "core:mem"

import "../base"
import "../game"
import "../netcode"

// Clients, and interest management for each (the area is defined in
// game/interest.odin): which chunks a client has, which to send next and
// which to tell it to drop; and which chunks no client wants any more.

Client_State :: enum u8 {
	Free, // an empty seat
	Connecting, // connected, waiting for Hello
	Proving, // Challenge sent, waiting for the Proof
	Choosing, // proved; Characters sent, waiting for Choose
	Playing,
	Gone, // refused; dropped soon (kick_at), or the local pipe closed
}

// Client_Link: how to reach a client.
Client_Link :: union {
	Local, // the in-process pipe (Server.local)
	netcode.Peer_Id,
}

Local :: struct {}

Client :: struct {
	state:        Client_State,
	link:         Client_Link,
	grants:       [dynamic]game.Grant, // what they may do, resolved (heap; permissions.odin)
	world:        ^World, // where they are (Playing)
	account:      game.Account, // (proved once Playing)
	nonce:        game.Nonce, // the Challenge sent
	wanted:       [game.MAX_NAME_LENGTH]u8, // the character asked for in Hello ("": choose)
	wanted_len:   int,
	name_buf:     [game.MAX_NAME_LENGTH]u8,
	name_len:     int,
	kick_at:      u64, // tick to drop a refused client
	kick_reason:  string, // (a constant)
	position:     [3]f64,
	center:       game.Chunk_Pos, // the chunk the client is in
	moved:        bool, // center changed since the last unload pass
	has:          map[game.Chunk_Pos]struct{}, // chunks sent and not dropped
	columns:      map[[2]i32]int, // chunks it has per column (its Column was sent while > 0)
	known:        map[u32]struct{}, // entities it has been told about (entities.odin)
	cursor:       int, // offsets before this are all sent
	player:       game.Player_State,
	inputs:       game.Input_Queue,
	teleported:   bool, // since the last Player_Update
	landing:      Maybe(Landing), // an arrival waiting for its blocks (spawn.odin)
	actions:      [MAX_QUEUED_ACTIONS]Action, // waiting for their input (oldest first; actions.odin)
	action_count: int,
	teleport:     [2]f32, // yaw, pitch to look after it
	look:         [2]f32, // yaw, pitch of the last input applied (saved with the player)
	fired_at:     u64, // tick of its last rocket (a rate limit)
	chat_tokens:  int, // lines it may say now (chat.odin)
	chat_tick:    u64, // the bucket refilled up to here
	address:      string, // its IP address ("": the local player; owned)
	back:         Maybe(Place), // where it was before its last teleport
	afk:          bool,
	reply:        [game.MAX_NAME_LENGTH]u8, // who it last whispered with (r)
	reply_len:    int,
	tpa:          Tpa, // a teleport request to it
	inventory:    game.Inventory,
	inv_acked:    u32, // its newest Inventory_Request applied
	inv_changed:  bool, // since the last Inventory_Update sent
}

// What may be sent to a client per tick: bytes of chunks (at 30 Hz about
// 1.9 MiB/s: an empty or buried chunk is a few bytes, a surface one a few
// hundred), and chunks at most (each costs encoding on the tick).
@(private)
SEND_BUDGET_BYTES :: 64 * 1024
@(private)
SEND_BUDGET_CHUNKS :: 256
// A remote client with this much unacknowledged reliable data gets no more
// chunks until it catches up (the rest wait: streaming is nearest first).
@(private)
MAX_BACKLOG :: 512 * 1024

// MAX_QUEUED_ACTIONS: actions waiting for the input they follow; more than
// this means the client is far ahead of what it has sent, or lying.
MAX_QUEUED_ACTIONS :: 64

@(private)
client_init :: proc(c: ^Client, config: Config, arena: mem.Allocator) -> mem.Allocator_Error {
	c^ = {}
	// A client holds at most its interest area plus the drop margin.
	most := game.interest_count(
		config.view_radius + game.CLIENT_DROP_MARGIN,
		config.view_height + game.CLIENT_DROP_MARGIN,
	)
	c.has = base.map_make_fixed(map[game.Chunk_Pos]struct{}, most, arena) or_return
	// Its columns: the interest area's columns plus the margin.
	columns := game.interest_count(config.view_radius + game.CLIENT_DROP_MARGIN, 0)
	c.columns = base.map_make_fixed(map[[2]i32]int, columns, arena) or_return
	c.known = base.map_make_fixed(map[u32]struct{}, MAX_KNOWN_ENTITIES, arena) or_return
	return nil
}

// client_reset frees the seat (keeping its maps' memory for the next).
@(private)
client_reset :: proc(c: ^Client) {
	for g in c.grants {delete(g.pattern)}
	delete(c.grants)
	delete(c.address)
	has, columns, known := c.has, c.columns, c.known
	clear(&has)
	clear(&columns)
	clear(&known)
	c^ = {
		has     = has,
		columns = columns,
		known   = known,
	}
}

@(private)
client_name :: proc(c: ^Client) -> string {
	return string(c.name_buf[:c.name_len])
}

@(private)
set_position :: proc(c: ^Client, p: [3]f64) {
	c.position = p
	center := game.chunk_of({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
	if center != c.center {
		c.center = center
		c.moved = true
		c.cursor = 0
	}
}

// client_wants: pos is within the client's interest area plus margin.
@(private)
client_wants :: proc(c: ^Client, pos: game.Chunk_Pos, config: Config, margin: i32) -> bool {
	if c.state != .Playing {return false}
	return game.in_interest(
		pos - c.center,
		config.view_radius + margin,
		config.view_height + margin,
	)
}

// anyone_wants: some playing client wants pos.
@(private)
anyone_wants :: proc(w: ^World, pos: game.Chunk_Pos, margin: i32) -> bool {
	s := w.server
	for &c in s.clients {
		if c.world == w && client_wants(&c, pos, s.config, margin) {return true}
	}
	return false
}

// stream requests and sends the nearest chunks the client lacks, within the
// tick's budgets (and, over the network, while the client keeps up).
@(private)
stream :: proc(s: ^Server, c: ^Client) {
	w := c.world
	budget, bytes := SEND_BUDGET_CHUNKS, SEND_BUDGET_BYTES
	if p, ok := c.link.(netcode.Peer_Id); ok && netcode.host_backlog(&s.host, p) > MAX_BACKLOG {
		budget = 0
	}
	requesting := true
	all_sent := true
	for i in c.cursor ..< len(s.offsets) {
		pos := c.center + s.offsets[i]
		if !game.in_world(pos) || pos in c.has {
			if all_sent {c.cursor = i + 1}
			continue
		}
		all_sent = false
		// A column's first chunk goes with its Column (its tops): those
		// are worked out by the workers too, asked for when first met.
		column := [2]i32{pos.x, pos.z}
		column_ready := c.columns[column] > 0 || natural_known(w, column)
		if !column_ready && requesting && column not_in w.tops_pending {
			requesting = chunks_request_tops(&w.chunks, column)
			if requesting {w.tops_pending[column] = {}}
		}
		chunk := chunks_get(&w.chunks, pos)
		if chunk == nil {
			if requesting {
				base.profile_scope("request chunk")
				requesting = request_chunk(w, pos)
			}
			// Requests go in order: once the workers are full, what lies
			// beyond is not generating (unless loaded for another client:
			// sent once the walk gets there).
			if !requesting {break}
			continue
		}
		if chunk.state != .Ready || budget == 0 || !column_ready {continue}
		if c.columns[column] == 0 {bytes -= send_message(s, c, column_message(w, column))}
		c.columns[column] += 1
		{
			base.profile_scope("send chunk")
			bytes -= send_message(s, c, game.Chunk_Message{pos = pos}, &chunk.blocks)
		}
		c.has[pos] = {}
		budget -= 1
		if bytes <= 0 {budget = 0}
		if budget == 0 && !requesting {break}
	}
}

// drop_far tells the client to drop chunks it no longer needs.
@(private)
drop_far :: proc(s: ^Server, c: ^Client) {
	drop := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in c.has {
		if !client_wants(c, pos, s.config, game.CLIENT_DROP_MARGIN) {append(&drop, pos)}
	}
	for pos in drop {
		delete_key(&c.has, pos)
		send_message(s, c, game.Unload_Chunk{pos})
		column := [2]i32{pos.x, pos.z}
		c.columns[column] -= 1
		if c.columns[column] == 0 {delete_key(&c.columns, column)}
	}
}

// unload_unwanted frees the chunks no client needs (edited ones go to the
// save, not away).
@(private)
unload_unwanted :: proc(w: ^World) {
	drop := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in w.chunks.by_pos {
		if !anyone_wants(w, pos, game.SERVER_UNLOAD_MARGIN) {append(&drop, pos)}
	}
	for pos in drop {
		if chunk := chunks_get(&w.chunks, pos); chunk.state == .Ready {
			keep_edits(w, chunk)
			chunks_unload(&w.chunks, pos)
		}
	}
}
