package server

import "../game"

// Column heights (the highest solid block of each block column) for sky
// light. Natural terrain has no overhangs, so worldgen's column_height is
// the answer until an edit changes a column's top; those are kept in
// tops. (Kept for the session, like the edits themselves until M5 saves
// them.)

// column_top is the y of the highest solid block at (x, z).
column_top :: proc(s: ^Server, x, z: i32) -> i32 {
	if top, ok := s.tops[{x, z}]; ok {return top}
	return game.column_height(s.config.seed, x, z)
}

// column_message has the heights of a chunk column.
column_message :: proc(s: ^Server, column: [2]i32) -> game.Column {
	m := game.Column {
		pos = column,
	}
	for z in i32(0) ..< game.CHUNK_SIZE {
		for x in i32(0) ..< game.CHUNK_SIZE {
			m.heights[x + z * game.CHUNK_SIZE] = column_top(
				s,
				column.x * game.CHUNK_SIZE + x,
				column.y * game.CHUNK_SIZE + z,
			)
		}
	}
	return m
}

// column_edited updates the top of p's column after the block at p changed
// to b; true if it changed.
column_edited :: proc(s: ^Server, p: game.Block_Pos, b: game.Block) -> bool {
	old := column_top(s, p.x, p.z)
	top := old
	if game.block_solid(b) && p.y > old {
		top = p.y
	} else if !game.block_solid(b) && p.y == old {
		// The top was removed: the next solid block down.
		top = game.WORLD_MIN_Y
		for y := p.y - 1; y >= game.WORLD_MIN_Y; y -= 1 {
			block, loaded := world_block(&s.world, {p.x, y, p.z})
			if !loaded {
				// Beyond what is loaded: natural terrain (or just below).
				top = min(game.column_height(s.config.seed, p.x, p.z), y)
				break
			}
			if game.block_solid(block) {
				top = y
				break
			}
		}
	}
	if top == old {return false}
	if top == game.column_height(s.config.seed, p.x, p.z) {
		delete_key(&s.tops, [2]i32{p.x, p.z})
	} else {
		s.tops[{p.x, p.z}] = top
	}
	return true
}
