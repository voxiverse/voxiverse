package server

import "../game"
import "../worldgen"

// Column heights (the highest opaque block of each block column) for sky
// light; the rules are game/column.odin's. The generator knows each
// column's natural top; edits that change a top are kept in tops (and
// saved with their regions).

// column_top is the y of the highest opaque block at (x, z).
column_top :: proc(s: ^Server, x, z: i32) -> i32 {
	if top, ok := s.tops[{x, z}]; ok {return top}
	return natural_top(s, x, z)
}

// NATURAL_CACHE: chunk columns of natural tops kept (direct-mapped: a
// column whose slot is taken is computed again; the generator scans for
// them, so they are worth keeping while players are near).
NATURAL_CACHE :: 2048

Natural_Slot :: struct {
	column: [2]i32,
	valid:  bool,
	tops:   worldgen.Tops,
}

// natural_top: the generator's top of (x, z).
natural_top :: proc(s: ^Server, x, z: i32) -> i32 {
	column := [2]i32{x >> game.CHUNK_SHIFT, z >> game.CHUNK_SHIFT}
	h := u32(column.x) * 0x9e37_79b1 ~ u32(column.y) * 0x85eb_ca6b
	slot := &s.natural[(h ~ h >> 15) % NATURAL_CACHE]
	if !slot.valid || slot.column != column {
		worldgen.column_tops(&s.chunks.gen, column, &slot.tops)
		slot.column, slot.valid = column, true
	}
	return slot.tops[(x & game.CHUNK_MASK) + (z & game.CHUNK_MASK) * game.CHUNK_SIZE]
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
	query := game.Block_Query{&s.chunks, chunks_block}
	old := column_top(s, p.x, p.z)
	return column_set(
		s,
		p.x,
		p.z,
		old,
		game.column_top_after(query, old, p, b, natural_top(s, p.x, p.z)),
	)
}

// column_rescan finds the top of (x, z) again after a bulk edit that
// reached up to y = from (anything above the old top and from is air);
// true if it changed.
column_rescan :: proc(s: ^Server, x, z: i32, from: i32) -> bool {
	query := game.Block_Query{&s.chunks, chunks_block}
	old := column_top(s, x, z)
	return column_set(
		s,
		x,
		z,
		old,
		game.column_scan(query, x, z, max(old, from), natural_top(s, x, z)),
	)
}

// column_set records a column's new top (kept only where it differs from
// the natural terrain's); true if it changed.
@(private = "file")
column_set :: proc(s: ^Server, x, z: i32, old, top: i32) -> bool {
	if top == old {return false}
	if top == natural_top(s, x, z) {
		delete_key(&s.tops, [2]i32{x, z})
	} else {
		s.tops[{x, z}] = top
	}
	return true
}
