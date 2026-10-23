package server

import "../game"

// Column heights (the highest opaque block of each block column) for sky
// light; the rules are game/column.odin's. Natural terrain has no
// overhangs, so worldgen's column_height is the answer until an edit
// changes a column's top; those are kept in tops (and saved with their
// regions).

// column_top is the y of the highest opaque block at (x, z).
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
	query := game.Block_Query{&s.world, world_block}
	old := column_top(s, p.x, p.z)
	return column_set(s, p.x, p.z, old, game.column_top_after(query, old, p, b, s.config.seed))
}

// column_rescan finds the top of (x, z) again after a bulk edit that
// reached up to y = from (anything above the old top and from is air);
// true if it changed.
column_rescan :: proc(s: ^Server, x, z: i32, from: i32) -> bool {
	query := game.Block_Query{&s.world, world_block}
	old := column_top(s, x, z)
	return column_set(s, x, z, old, game.column_scan(query, x, z, max(old, from), s.config.seed))
}

// column_set records a column's new top (kept only where it differs from
// the natural terrain's); true if it changed.
@(private = "file")
column_set :: proc(s: ^Server, x, z: i32, old, top: i32) -> bool {
	if top == old {return false}
	if top == game.column_height(s.config.seed, x, z) {
		delete_key(&s.tops, [2]i32{x, z})
	} else {
		s.tops[{x, z}] = top
	}
	return true
}
