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
}

// Chunks sent to a client per tick (at 30 Hz: 1440 per second).
@(private)
SEND_BUDGET :: 48
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
anyone_wants :: proc(s: ^Server, pos: game.Chunk_Pos, margin: i32) -> bool {
	for &c in s.clients {
		if client_wants(&c, pos, s.config, margin) {return true}
	}
	return false
}

// stream requests and sends the nearest chunks the client lacks, within the
// tick's budgets (and, over the network, while the client keeps up).
@(private)
stream :: proc(s: ^Server, c: ^Client) {
	budget := SEND_BUDGET
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
		chunk := world_get(&s.world, pos)
		if chunk == nil {
			if requesting {requesting = request_chunk(s, pos)}
			if !requesting && budget == 0 {break}
			continue
		}
		if chunk.state != .Ready || budget == 0 {continue}
		column := [2]i32{pos.x, pos.z}
		if c.columns[column] == 0 {send_message(s, c, column_message(s, column))}
		c.columns[column] += 1
		send_message(s, c, game.Chunk_Message{pos = pos}, &chunk.blocks)
		c.has[pos] = {}
		budget -= 1
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
unload_unwanted :: proc(s: ^Server) {
	drop := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in s.world.by_pos {
		if !anyone_wants(s, pos, game.SERVER_UNLOAD_MARGIN) {append(&drop, pos)}
	}
	for pos in drop {
		if chunk := world_get(&s.world, pos); chunk.state == .Ready {
			keep_edits(s, chunk)
			world_unload(&s.world, pos)
		}
	}
}
