package server

import "core:math"
import "core:mem"

import "../base"
import "../game"

// Interest management (the area is defined in game/interest.odin): which
// chunks a client has, which to send next and which to tell it to drop.

Client_State :: enum u8 {
	Connecting,
	Playing,
	Gone,
}

Client :: struct {
	state:      Client_State,
	position:   [3]f64,
	center:     game.Chunk_Pos, // the chunk the client is in
	moved:      bool, // center changed since the last unload pass
	has:        map[game.Chunk_Pos]struct{}, // chunks sent and not dropped
	columns:    map[[2]i32]int, // chunks it has per column (its Column was sent while > 0)
	cursor:     int, // offsets before this are all sent
	player:     game.Player_State,
	inputs:     game.Input_Queue,
	teleported: bool, // since the last Player_Update
	edits:      [MAX_QUEUED_EDITS]game.Edit, // waiting for their input (oldest first)
	edit_count: int,
	teleport:   [2]f32, // yaw, pitch to look after it
}

// MAX_QUEUED_EDITS: edits waiting for the input they follow; more than this
// means the client is far ahead of what it has sent, or lying.
MAX_QUEUED_EDITS :: 64

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
	return nil
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

// client_wants: pos is within the interest area plus margin.
@(private)
client_wants :: proc(c: ^Client, pos: game.Chunk_Pos, config: Config, margin: i32) -> bool {
	if c.state != .Playing {return false}
	return game.in_interest(
		pos - c.center,
		config.view_radius + margin,
		config.view_height + margin,
	)
}

// stream requests and sends the nearest chunks the client lacks, within the
// tick's budgets.
@(private)
stream :: proc(s: ^Server) {
	c := &s.client
	budget := SEND_BUDGET
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
			if requesting {requesting = world_request(&s.world, pos)}
			if !requesting && budget == 0 {break}
			continue
		}
		if chunk.state != .Ready || budget == 0 {continue}
		column := [2]i32{pos.x, pos.z}
		if c.columns[column] == 0 {send_message(s, column_message(s, column))}
		c.columns[column] += 1
		send_message(s, game.Chunk_Message{pos = pos}, &chunk.blocks)
		c.has[pos] = {}
		budget -= 1
		if budget == 0 && !requesting {break}
	}
}

// unload_far tells the client to drop chunks it no longer needs and frees
// those no client needs.
@(private)
unload_far :: proc(s: ^Server) {
	c := &s.client
	drop := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in c.has {
		if !client_wants(c, pos, s.config, game.CLIENT_DROP_MARGIN) {append(&drop, pos)}
	}
	for pos in drop {
		delete_key(&c.has, pos)
		send_message(s, game.Unload_Chunk{pos})
		column := [2]i32{pos.x, pos.z}
		c.columns[column] -= 1
		if c.columns[column] == 0 {delete_key(&c.columns, column)}
	}
	clear(&drop)
	for pos in s.world.by_pos {
		if !client_wants(c, pos, s.config, game.SERVER_UNLOAD_MARGIN) {append(&drop, pos)}
	}
	for pos in drop {
		if chunk := world_get(&s.world, pos); chunk.state == .Ready {world_unload(&s.world, pos)}
	}
}
