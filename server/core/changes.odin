package core

import "core:log"

import "common:base"
import "common:game"
import "common:protocol"
import "common:voxel"

// Block changes: every block the world changes in a tick (a player's edit,
// a bulk edit, an explosion; flowing water next) goes through set_block or
// changes_chunk, and changes_flush tells the players at the end of the
// tick, once: single blocks as Block records, chunks changed in bulk sent
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
	cells:   map[Cell_Key]struct{}, // channel values changed one cell at a time (channels.odin)
}

// A chunk with more single changes than this in a tick is sent whole.
@(private = "file")
MAX_BLOCK_MESSAGES :: protocol.MAX_BLOCKS_CHANGED

changes_begin :: proc(w: ^World) -> ^Changes {
	ch := &w.changes
	if ch.blocks == nil {
		ch.blocks = make(map[game.Block_Pos]int, 16, context.temp_allocator)
		ch.chunks = make(map[game.Chunk_Pos]struct{}, 16, context.temp_allocator)
		ch.columns = make(map[[2]i32]struct{}, 16, context.temp_allocator)
		ch.cells = make(map[Cell_Key]struct{}, 16, context.temp_allocator)
	}
	return ch
}

// block_at: the block at p in w; false while its chunk is not loaded (or still
// generating), and the block is then .Air.
block_at :: proc(w: ^World, p: game.Block_Pos) -> (game.Block, bool) {
	return chunks_block(&w.chunks, p)
}

// set_block changes one block, by act (its cause: journal.odin), told to
// everyone but the player it came from (by; nil: the world itself); false if
// its chunk is not loaded or the change is refused (admit).
set_block :: proc(
	w: ^World,
	p: game.Block_Pos,
	block: game.Block,
	act: Act,
	by: ^Client = nil,
) -> bool {
	s := w.server
	old, loaded := chunks_block(&w.chunks, p)
	if !loaded {return false}
	b := block
	cause := act_current(w, act)
	if admit(w, cause, p) != .Yes {return false}
	query := game.Block_Query{&w.chunks, chunks_block, &s.registry.blocks, {}}
	b = game.shape_update(s.registry, b, p, query) // (a fence set by a command joins what is beside it)
	if !chunks_set_block(&w.chunks, p, b) {return false}
	if old != b {
		channels_reset_cell(w, p)
		walkers_changed(w, p, p)
		block_change_note(w, {area = {p, p}, old = old, new = b}, by)
	}
	journal_entry(w, cause, p, old, b)
	entity_lifecycle(w, p, old, b, cause)
	mark_edited(w, game.chunk_of(p))
	ch := changes_begin(w)
	who := int(player_id(s, by)) if by != nil else -1
	if before, seen := ch.blocks[p]; seen && before != who {who = -1}
	ch.blocks[p] = who
	if column_edited(w, p, b) {ch.columns[{p.x >> game.CHUNK_SHIFT, p.z >> game.CHUNK_SHIFT}] = {}}
	sim_wake(w, p, cause.action)
	// A plant or a ladder beside lost its footing, perhaps (not when this is a settle's own
	// change: what it unsettles, the settle took already).
	for d in ([6][3]i32{{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) {
		if cause.how == .Support || !support_fails(w, p + d) {continue}
		words: [9]u64 // (a 3 by 3 by 3 box's)
		beside := voxel.mask_over({p - 1, p + 2}, words[:])
		voxel.diamond(&beside, p, 1)
		voxel.mask_set(&beside, p, false)
		supports_settle(w, beside, cause.action)
		break
	}
	updates: [4]game.Block_Change
	for u in updates[:game.neighbour_updates(s.registry, p, query, &updates)] {
		set_block(w, u.pos, u.b, cause) // (a fence beside joins or lets go)
	}
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
	if s.config.stepped {
		for p in ch.blocks {append(&w.touched, game.chunk_of(p))}
		for pos in ch.chunks {append(&w.touched, pos)}
		for k in ch.cells {append(&w.touched, game.chunk_of(k.pos))}
	}
	per_chunk := make(map[game.Chunk_Pos]int, len(ch.blocks), context.temp_allocator)
	for p in ch.blocks {per_chunk[game.chunk_of(p)] += 1}
	// Chunks with many single changes go whole too, but not as part of a
	// bulk edit's group (flowing water need not appear all at once).
	busy_set := make(map[game.Chunk_Pos]struct{}, 16, context.temp_allocator)
	for pos, n in per_chunk {if n > MAX_BLOCK_MESSAGES && pos not_in ch.chunks {busy_set[pos] = {}}}
	// In order (map order varies): the same messages every run.
	busy := base.keys_sorted(busy_set, game.chunk_pos_less, context.temp_allocator)
	bulk := base.keys_sorted(ch.chunks, game.chunk_pos_less, context.temp_allocator)
	columns := base.keys_sorted(ch.columns, column_less, context.temp_allocator)
	edits := base.keys_sorted(ch.blocks, game.block_pos_less, context.temp_allocator)
	cells := base.keys_sorted(ch.cells, cell_less, context.temp_allocator)
	infos := s.registry.channels
	for &c, i in s.clients {
		if c.state != .Playing || c.world != w {continue}
		disturb_near_changes(s, &c, edits, bulk)
		whole := make([dynamic]game.Chunk_Pos, context.temp_allocator)
		for pos in bulk {if pos in c.has {append(&whole, pos)}}
		if len(whole) >
		   0 {send_message(s, &c, protocol.Bulk_Begin{u16(min(len(whole), int(max(u16))))})}
		for pos in busy {if pos in c.has {append(&whole, pos)}} 	// after the group
		for column in columns {
			if c.columns[column] > 0 {send_message(s, &c, column_message(w, column))}
		}
		for pos in whole {
			chunk := chunks_get(&w.chunks, pos)
			send_message(s, &c, chunk_message(w, chunk), &chunk.blocks)
			machines_sent(s, &c, chunk)
			belts_sent(s, &c, chunk)
		}
		// A player's edit, heard; the world's changes (flowing water), quietly.
		for p in edits {
			who := ch.blocks[p]
			chunk := game.chunk_of(p)
			if who == i || chunk in ch.chunks || chunk in busy_set || chunk not_in c.has {continue}
			b, _ := chunks_block(&w.chunks, p)
			record := protocol.Block_Record{u16(b), who >= 0}
			state_put(s, &c, .Block, &record, protocol.key_of_block(p))
		}
		// A replicated channel's changed cells, after the blocks (a block change reset
		// its channels: the reset is among them).
		for k in cells {
			chunk := game.chunk_of(k.pos)
			if chunk in ch.chunks || chunk in busy_set || chunk not_in c.has {continue}
			if int(k.channel) >= len(infos) || !infos[k.channel].replicated {continue}
			v, _ := chunks_channel(w, k.pos, int(k.channel))
			record := protocol.Channel_Record{v}
			state_put(s, &c, .Channel, &record, protocol.key_of_cell(k.pos, int(k.channel)))
		}
	}
}

@(private = "file")
cell_less :: proc(a, b: Cell_Key) -> bool {
	if a.pos != b.pos {return game.block_pos_less(a.pos, b.pos)}
	return a.channel < b.channel
}

@(private = "file")
column_less :: proc(a, b: [2]i32) -> bool {
	if a.y != b.y {return a.y < b.y}
	return a.x < b.x
}

// Block_Change: blocks a world changed, as a game's block_changed hook is told them:
// one block (old and new say what it was and is), or a bulk edit's box (bulk: read
// the blocks).
Block_Change :: struct {
	area:     Box,
	old, new: game.Block, // one block's (a bulk edit: .Air and .Air)
	bulk:     bool,
	by:       ^Client, // the player whose edit it was (nil: the world, a command, the game)
}

// Noted_Change: a change kept until the game is told: the player as a Player_Ref, so
// one who left by then is nobody.
Noted_Change :: struct {
	change: Block_Change,
	by:     Maybe(Player_Ref),
}

// MAX_NOTED_CHANGES: changes a world keeps for its game in a tick; more are dropped,
// and said (a game that needs every block of a flood watches the area instead).
MAX_NOTED_CHANGES :: 4096

// block_change_note keeps a change for the game's block_changed hook (when it has
// one), told before its next tick.
block_change_note :: proc(w: ^World, change: Block_Change, by: ^Client = nil) {
	s := w.server
	if s.config.game.block_changed == nil {return}
	if len(w.noted_changes) >= MAX_NOTED_CHANGES {
		if w.noted_dropped == 0 {
			log.warnf(
				"server more than %d block changes in a tick: the game is told the first",
				MAX_NOTED_CHANGES,
			)
		}
		w.noted_dropped += 1
		return
	}
	noted := Noted_Change {
		change = change,
	}
	noted.change.by = nil
	if by != nil {noted.by = player_ref(s, by)}
	append(&w.noted_changes, noted)
}

// block_changes_tell: the game hears of the changes kept since its last tick.
block_changes_tell :: proc(w: ^World) {
	s := w.server
	defer {
		clear(&w.noted_changes)
		w.noted_dropped = 0
	}
	g := &s.config.game
	if g.block_changed == nil {return}
	for n in w.noted_changes {
		change := n.change
		if ref, set := n.by.?; set {change.by = player_of(s, ref)}
		g.block_changed(s, w, change)
	}
}
