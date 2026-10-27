package game

import "core:testing"

// One column (x = z = 0): blocks by height, loaded from loaded_from up.
@(private = "file")
Column_World :: struct {
	blocks:      map[i32]Block,
	loaded_from: i32,
}

@(private = "file")
column_query :: proc(w: ^Column_World) -> Block_Query {
	return {w, proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			w := (^Column_World)(data)
			if p.y < w.loaded_from {return .Air, false}
			return w.blocks[p.y] or_else .Air, true
		}}
}

@(test)
test_column_tops :: proc(t: ^testing.T) {
	w := Column_World {
		loaded_from = 0,
	}
	defer delete(w.blocks)
	w.blocks[2] = .Stone
	w.blocks[5] = .Dirt
	q := column_query(&w)
	testing.expect_value(t, column_scan(q, 0, 0, 100, nil), 5)
	testing.expect_value(t, column_scan(q, 0, 0, 4, nil), 2)

	// Placing above raises it; below or beside the top changes nothing.
	testing.expect_value(t, column_top_after(q, 5, {0, 9, 0}, .Lamp, nil), 9)
	testing.expect_value(t, column_top_after(q, 5, {0, 3, 0}, .Sand, nil), 5)
	testing.expect_value(t, column_top_after(q, 5, {0, 3, 0}, .Air, nil), 5)
	// Air above air: no change.
	testing.expect_value(t, column_top_after(q, 5, {0, 7, 0}, .Air, nil), 5)
	// Breaking the top: the next opaque block down.
	w.blocks[5] = .Air
	testing.expect_value(t, column_top_after(q, 5, {0, 5, 0}, .Air, nil), 2)
	// Nothing left above the unloaded part: the client guesses the last
	// loaded height, the server (knowing the seed) the natural terrain.
	w.blocks[2] = .Air
	testing.expect_value(t, column_top_after(q, 2, {0, 2, 0}, .Air, nil), -1)
	testing.expect_value(t, column_scan(q, 0, 0, 1, i32(-9)), -9)
	testing.expect_value(t, column_scan(q, 0, 0, 1, i32(30)), -1) // never above where it was cut
	// Nothing anywhere: the bottom of the world.
	w.loaded_from = WORLD_MIN_Y
	testing.expect_value(t, column_scan(q, 0, 0, 10, nil), WORLD_MIN_Y)
}
