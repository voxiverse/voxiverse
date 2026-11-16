package game

import "core:testing"

// Belts (belt.odin): items keep their order and spacing, pass to the belt in front (round a
// corner too), and wait at the end when it has no room.

@(private = "file")
Test_Belt :: struct {
	lane: Lane,
	dir:  Block_Pos,
}

@(private = "file")
Test_Belts :: map[Block_Pos]Test_Belt

@(private = "file")
test_find :: proc(data: rawptr, p: Block_Pos) -> (^Lane, u16, Block_Pos, bool) {
	belts := (^Test_Belts)(data)
	b, ok := &belts[p]
	if !ok {return nil, 0, {}, false}
	return &b.lane, LANE_SPACING / 2, b.dir, true
}

@(private = "file")
lane_at :: proc(belts: ^Test_Belts, p: Block_Pos) -> ^Lane {
	b, _ := &belts[p]
	return &b.lane
}

@(private = "file")
step :: proc(belts: ^Test_Belts, ticks: int) {
	for _ in 0 ..< ticks {
		active := make([dynamic]Block_Pos, context.temp_allocator)
		for p in belts {append(&active, p)}
		for i in 1 ..< len(active) {
			for j := i; j > 0 && block_pos_less(active[j], active[j - 1]); j -= 1 {
				active[j], active[j - 1] = active[j - 1], active[j]
			}
		}
		out := Lanes_Stepped {
			awake = make([dynamic]Block_Pos, context.temp_allocator),
			gave  = make([dynamic]Block_Pos, context.temp_allocator),
		}
		lanes_step(active[:], test_find, belts, &out)
	}
}

@(test)
test_a_belt_carries_items_in_order_round_a_corner :: proc(t: ^testing.T) {
	belts: Test_Belts
	defer delete(belts)
	// Three east, then a corner north: (0..2, 0, 0) east, (3, 0, 0) north to (3, 0, -1).
	for x in i32(0) ..< 3 {belts[{x, 0, 0}] = {
			dir = {1, 0, 0},
		}}
	belts[{3, 0, 0}] = {
		dir = {0, 0, -1},
	}
	belts[{3, 0, -1}] = {
		dir = {0, 0, -1},
	}
	first := lane_at(&belts, {0, 0, 0})
	testing.expect(t, lane_put(first, Item(11)))
	testing.expect(t, !lane_put(first, Item(12)), "room for two at the start")
	step(&belts, 2) // (half a block a tick at most: two ticks give the next its room)
	testing.expect(t, lane_put(first, Item(12)))
	step(&belts, 2)
	testing.expect(t, lane_put(first, Item(13)))
	step(&belts, 400)
	// The last belt faces nothing: its items wait there, in order, spaced, the rest behind.
	end := lane_at(&belts, {3, 0, -1})
	testing.expect_value(t, end.count, 3)
	for it, i in end.items[:end.count] {testing.expect_value(t, it.item, Item(11 + i))}
	testing.expect_value(t, end.items[0].at, LANE_END)
	for i in 1 ..< int(end.count) {
		testing.expect(t, end.items[i - 1].at - end.items[i].at >= LANE_SPACING, "too close")
	}
	// Blocked: more pile up behind it, a belt full before the one feeding it fills.
	for _ in 0 ..< 8 {
		lane_put(first, Item(20))
		step(&belts, 6)
	}
	step(&belts, 400)
	testing.expect_value(t, end.count, LANE_ITEMS)
	testing.expect_value(t, belts[{3, 0, 0}].lane.count, LANE_ITEMS)
	// Taken off the end: the one behind moves up, and the belt behind hands one on.
	item, ok := lane_take(end)
	testing.expect(t, ok && item == Item(11))
	step(&belts, 10)
	testing.expect_value(t, end.count, LANE_ITEMS)
	testing.expect_value(t, end.items[0].item, Item(12))
}
