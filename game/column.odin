package game

// A column's top: its highest opaque block, where sky light stops. The
// server keeps the tops (sending them in Column messages); the client
// predicts them for its own edits until the server's arrive. Both use these.

// column_scan: the top of column (x, z) at or below from, as far as query
// has blocks loaded; below that, the natural terrain when the seed is known
// (else the last loaded height: a guess the server's Column corrects).
column_scan :: proc(query: Block_Query, x, z, from: i32, seed: Maybe(i64)) -> i32 {
	for y := min(from, WORLD_MAX_Y - 1); y >= WORLD_MIN_Y; y -= 1 {
		block, loaded := query.get(query.data, {x, y, z})
		if !loaded {
			natural, known := seed.?
			return min(column_height(natural, x, z), y) if known else y
		}
		if block_opaque(block) {return y}
	}
	return WORLD_MIN_Y
}

// column_top_after: the top of p's column (old before) after the block at p
// became b.
column_top_after :: proc(
	query: Block_Query,
	old: i32,
	p: Block_Pos,
	b: Block,
	seed: Maybe(i64),
) -> i32 {
	if block_opaque(b) {return max(old, p.y)}
	if p.y == old {return column_scan(query, p.x, p.z, p.y - 1, seed)} 	// the top went
	return old
}
