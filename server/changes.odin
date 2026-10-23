package server

import "../game"

// Block changes: every block the world changes in a tick (a player's edit,
// a bulk edit, an explosion; flowing water next) goes through set_block or
// changes_chunk, and changes_flush tells the players at the end of the
// tick, once: single blocks as Block_Changed, chunks changed in bulk sent
// whole (after a Bulk_Begin, so the client can show them all at once), and
// the column tops that moved.
//
// The sets live in the tick's temp allocator: they are gone with the tick.

Changes :: struct {
	// Single blocks, by who changed them (a client's index, not told again:
	// it had its Edit_Result; -1: the server, or more than one).
	blocks:  map[game.Block_Pos]int,
	chunks:  map[game.Chunk_Pos]struct{}, // changed in bulk: sent whole
	columns: map[[2]i32]struct{}, // chunk columns whose tops moved
}

// A chunk with more single changes than this in a tick is sent whole.
@(private = "file")
MAX_BLOCK_MESSAGES :: 64

@(private = "file")
changes_begin :: proc(s: ^Server) -> ^Changes {
	ch := &s.changes
	if ch.blocks == nil {
		ch.blocks = make(map[game.Block_Pos]int, 16, context.temp_allocator)
		ch.chunks = make(map[game.Chunk_Pos]struct{}, 16, context.temp_allocator)
		ch.columns = make(map[[2]i32]struct{}, 16, context.temp_allocator)
	}
	return ch
}

// set_block changes one block (by a player, or nil: the world itself);
// false if its chunk is not loaded.
set_block :: proc(s: ^Server, p: game.Block_Pos, b: game.Block, by: ^Client = nil) -> bool {
	if !world_set_block(&s.world, p, b) {return false}
	mark_edited(s, game.chunk_of(p))
	ch := changes_begin(s)
	who := int(player_id(s, by)) if by != nil else -1
	if before, seen := ch.blocks[p]; seen && before != who {who = -1}
	ch.blocks[p] = who
	if column_edited(s, p, b) {ch.columns[{p.x >> game.CHUNK_SHIFT, p.z >> game.CHUNK_SHIFT}] = {}}
	return true
}

// changes_chunk: the chunk at pos was changed in bulk (its blocks written
// directly), to be sent whole.
changes_chunk :: proc(s: ^Server, pos: game.Chunk_Pos) {
	mark_edited(s, pos)
	changes_begin(s).chunks[pos] = {}
}

// changes_column: the tops of a chunk column moved.
changes_column :: proc(s: ^Server, column: [2]i32) {
	changes_begin(s).columns[column] = {}
}

// changes_flush tells every player what changed in the chunks it has.
changes_flush :: proc(s: ^Server) {
	ch := &s.changes
	defer ch^ = {}
	if ch.blocks == nil {return}
	per_chunk := make(map[game.Chunk_Pos]int, len(ch.blocks), context.temp_allocator)
	for p in ch.blocks {per_chunk[game.chunk_of(p)] += 1}
	for pos, n in per_chunk {if n > MAX_BLOCK_MESSAGES {ch.chunks[pos] = {}}}
	for &c, i in s.clients {
		if c.state != .Playing {continue}
		whole := make([dynamic]game.Chunk_Pos, context.temp_allocator)
		for pos in ch.chunks {if pos in c.has {append(&whole, pos)}}
		if len(whole) >
		   0 {send_message(s, &c, game.Bulk_Begin{u16(min(len(whole), int(max(u16))))})}
		for column in ch.columns {
			if c.columns[column] > 0 {send_message(s, &c, column_message(s, column))}
		}
		for pos in whole {
			chunk := world_get(&s.world, pos)
			send_message(s, &c, game.Chunk_Message{pos = pos}, &chunk.blocks)
		}
		for p, who in ch.blocks {
			chunk := game.chunk_of(p)
			if who == i || chunk in ch.chunks || chunk not_in c.has {continue}
			b, _ := world_block(&s.world, p)
			send_message(s, &c, game.Block_Changed{p, b})
		}
	}
}
