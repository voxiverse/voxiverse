package server

import "core:math"
import "core:mem"
import "core:slice"

import "../game"

// Interest management: which chunks a client has, which to send next and
// which to tell it to drop. The interest area is a cylinder of chunks around
// the client's chunk (view_radius across, view_height above and below),
// walked nearest first. Chunks are dropped only past a margin, so moving
// back and forth across a chunk border does not resend anything.

// UNLOAD_MARGIN: the client drops chunks 1 chunk past the interest area,
// the server frees them 2 past it.
@(private)
UNLOAD_MARGIN :: 2

Client_State :: enum u8 {
	Connecting,
	Playing,
	Gone,
}

Client :: struct {
	state:    Client_State,
	position: [3]f64,
	center:   game.Chunk_Pos, // the chunk the client is in
	moved:    bool, // center changed since the last unload pass
	has:      map[game.Chunk_Pos]struct{}, // chunks sent and not dropped
	cursor:   int, // offsets before this are all sent
}

@(private)
client_init :: proc(c: ^Client, interest_chunks: int, arena: mem.Allocator) {
	c^ = {}
	// Within the client margin of any center it has had: comfortably less
	// than twice the interest area, so the map never grows.
	c.has = make(map[game.Chunk_Pos]struct{}, 2 * interest_chunks, arena)
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
	return in_area(pos - c.center, config.view_radius + margin, config.view_height + margin)
}

@(private)
in_area :: proc(d: game.Chunk_Pos, radius, height: i32) -> bool {
	return d.x * d.x + d.z * d.z <= radius * radius && abs(d.y) <= height
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
		if !in_world(pos) || pos in c.has {
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
		if !client_wants(c, pos, s.config, 1) {append(&drop, pos)}
	}
	for pos in drop {
		delete_key(&c.has, pos)
		send_message(s, game.Unload_Chunk{pos})
	}
	clear(&drop)
	for pos in s.world.by_pos {
		if !client_wants(c, pos, s.config, UNLOAD_MARGIN) {append(&drop, pos)}
	}
	for pos in drop {
		if chunk := world_get(&s.world, pos); chunk.state == .Ready {world_unload(&s.world, pos)}
	}
}

@(private)
in_world :: proc(p: game.Chunk_Pos) -> bool {
	return(
		abs(p.x) < game.CHUNK_LIMIT &&
		abs(p.y) < game.CHUNK_LIMIT &&
		abs(p.z) < game.CHUNK_LIMIT \
	)
}

// interest_offsets lists the chunk offsets of the interest area, nearest
// first.
@(private)
interest_offsets :: proc(radius, height: i32, allocator: mem.Allocator) -> []game.Chunk_Pos {
	out := make([dynamic]game.Chunk_Pos, 0, count_offsets(radius, height), allocator)
	for y in -height ..= height {
		for z in -radius ..= radius {
			for x in -radius ..= radius {
				if in_area({x, y, z}, radius, height) {append(&out, game.Chunk_Pos{x, y, z})}
			}
		}
	}
	slice.sort_by(out[:], proc(a, b: game.Chunk_Pos) -> bool {
		return a.x * a.x + a.y * a.y + a.z * a.z < b.x * b.x + b.y * b.y + b.z * b.z
	})
	return out[:]
}

@(private)
count_offsets :: proc(radius, height: i32) -> int {
	n := 0
	for z in -radius ..= radius {
		for x in -radius ..= radius {
			if x * x + z * z <= radius * radius {n += 1}
		}
	}
	return n * int(2 * height + 1)
}
