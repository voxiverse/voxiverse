package server

import "core:slice"

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
MAX_BLOCK_MESSAGES :: game.MAX_BLOCKS_CHANGED

@(private = "file")
changes_begin :: proc(w: ^World) -> ^Changes {
	ch := &w.changes
	if ch.blocks == nil {
		ch.blocks = make(map[game.Block_Pos]int, 16, context.temp_allocator)
		ch.chunks = make(map[game.Chunk_Pos]struct{}, 16, context.temp_allocator)
		ch.columns = make(map[[2]i32]struct{}, 16, context.temp_allocator)
	}
	return ch
}

// set_block changes one block (by a player, or nil: the world itself);
// false if its chunk is not loaded.
set_block :: proc(w: ^World, p: game.Block_Pos, b: game.Block, by: ^Client = nil) -> bool {
	s := w.server
	if !chunks_set_block(&w.chunks, p, b) {return false}
	mark_edited(w, game.chunk_of(p))
	ch := changes_begin(w)
	who := int(player_id(s, by)) if by != nil else -1
	if before, seen := ch.blocks[p]; seen && before != who {who = -1}
	ch.blocks[p] = who
	if column_edited(w, p, b) {ch.columns[{p.x >> game.CHUNK_SHIFT, p.z >> game.CHUNK_SHIFT}] = {}}
	wake_water(w, p)
	plant_check(w, p + {0, 1, 0}) // (a plant above lost its footing, perhaps)
	return true
}

// changes_chunk: the chunk at pos was changed in bulk (its blocks written
// directly), to be sent whole.
changes_chunk :: proc(w: ^World, pos: game.Chunk_Pos) {
	mark_edited(w, pos)
	changes_begin(w).chunks[pos] = {}
}

// changes_column: the tops of a chunk column moved.
changes_column :: proc(w: ^World, column: [2]i32) {
	changes_begin(w).columns[column] = {}
}

// changes_flush tells every player what changed in the chunks it has.
changes_flush :: proc(w: ^World) {
	s := w.server
	ch := &w.changes
	defer ch^ = {}
	if ch.blocks == nil {return}
	per_chunk := make(map[game.Chunk_Pos]int, len(ch.blocks), context.temp_allocator)
	for p in ch.blocks {per_chunk[game.chunk_of(p)] += 1}
	// Chunks with many single changes go whole too, but not as part of a
	// bulk edit's group (flowing water need not appear all at once).
	busy := make(map[game.Chunk_Pos]struct{}, 16, context.temp_allocator)
	for pos, n in per_chunk {if n > MAX_BLOCK_MESSAGES && pos not_in ch.chunks {busy[pos] = {}}}
	for &c, i in s.clients {
		if c.state != .Playing || c.world != w {continue}
		whole := make([dynamic]game.Chunk_Pos, context.temp_allocator)
		for pos in ch.chunks {if pos in c.has {append(&whole, pos)}}
		if len(whole) >
		   0 {send_message(s, &c, game.Bulk_Begin{u16(min(len(whole), int(max(u16))))})}
		for pos in busy {if pos in c.has {append(&whole, pos)}} 	// after the group
		for column in ch.columns {
			if c.columns[column] > 0 {send_message(s, &c, column_message(w, column))}
		}
		for pos in whole {
			chunk := chunks_get(&w.chunks, pos)
			send_message(s, &c, game.Chunk_Message{pos = pos}, &chunk.blocks)
		}
		// A player's edit, heard; the world's changes (flowing water), one
		// batch per chunk.
		batches := make(map[game.Chunk_Pos]game.Blocks_Changed, 16, context.temp_allocator)
		for p, who in ch.blocks {
			chunk := game.chunk_of(p)
			if who == i || chunk in ch.chunks || chunk in busy || chunk not_in c.has {continue}
			b, _ := chunks_block(&w.chunks, p)
			if who >= 0 {
				send_message(s, &c, game.Block_Changed{p, b})
				continue
			}
			_, batch, _, _ := map_entry(&batches, chunk)
			batch.chunk = chunk
			batch.entries[batch.count] = {u16(game.local_index(game.local_of(p))), b}
			batch.count += 1
		}
		// In order (map order varies): the same messages every run.
		chunks := make([dynamic]game.Chunk_Pos, 0, len(batches), context.temp_allocator)
		for chunk in batches {append(&chunks, chunk)}
		slice.sort_by(chunks[:], proc(a, b: game.Chunk_Pos) -> bool {
			if a.y != b.y {return a.y < b.y}
			if a.z != b.z {return a.z < b.z}
			return a.x < b.x
		})
		for chunk in chunks {send_message(s, &c, batches[chunk])}
	}
}
