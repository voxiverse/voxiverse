package server

import pq "core:container/priority_queue"
import "core:math"

import "common:game"

// Pathfinding for walking entities: A* over the block grid. A walker
// stands in a block of air on a solid block (one block tall is enough for
// a sheep); from there it can walk to any of the 8 neighbours (diagonals
// only past two open sides: no cutting corners), step up one block (with
// room overhead) or drop down at most MAX_DROP. Unloaded chunks count as
// walls. A search expands at most `budget` blocks; if the goal is not
// reached it returns the way to the block that got closest, so the walker
// still heads the right way.

MAX_DROP :: 3
MAX_PATH :: 32 // waypoints kept

Path :: struct {
	steps: [MAX_PATH]game.Block_Pos, // the blocks to stand in, in order (not the start)
	count: int,
	whole: bool, // reaches the goal (else: as near as the budget got)
}

// standable: a walker can stand in p (air, with solid ground below).
standable :: proc(q: game.Block_Query, p: game.Block_Pos) -> bool {
	return !game.solid_at(q, p) && game.solid_at(q, p + {0, -1, 0})
}

// find_path searches from start to goal (both blocks to stand in).
find_path :: proc(
	q: game.Block_Query,
	start, goal: game.Block_Pos,
	budget: int,
) -> (
	path: Path,
	ok: bool,
) {
	if !standable(q, start) {return}
	Node :: struct {
		pos: game.Block_Pos,
		f:   f32,
	}
	open: pq.Priority_Queue(Node)
	pq.init(
		&open,
		proc(a, b: Node) -> bool {return a.f < b.f},
		pq.default_swap_proc(Node),
		64,
		context.temp_allocator,
	)
	came := make(map[game.Block_Pos]game.Block_Pos, 256, context.temp_allocator)
	cost := make(map[game.Block_Pos]f32, 256, context.temp_allocator)
	cost[start] = 0
	pq.push(&open, Node{start, guess(start, goal)})
	best, best_h := start, guess(start, goal)
	for expanded := 0; pq.len(open) > 0 && expanded < budget; expanded += 1 {
		at := pq.pop(&open).pos
		if at == goal {
			best, best_h = at, 0
			break
		}
		if h := guess(at, goal); h < best_h {best, best_h = at, h}
		for d in NEIGHBOURS {
			step := game.Block_Pos{at.x + d.x, at.y, at.z + d.y}
			if d.x != 0 && d.y != 0 {
				// Diagonal: both sides it passes must be open at this height.
				if game.solid_at(q, {at.x + d.x, at.y, at.z}) ||
				   game.solid_at(q, {at.x, at.y, at.z + d.y}) {
					continue
				}
			}
			to, extra, can := reach(q, at, step)
			if !can {continue}
			c := cost[at] + (math.SQRT_TWO if d.x != 0 && d.y != 0 else 1) + extra
			if old, seen := cost[to]; seen && old <= c {continue}
			cost[to] = c
			came[to] = at
			pq.push(&open, Node{to, c + guess(to, goal)})
		}
	}
	// Walk back from the best block reached.
	backwards: [dynamic]game.Block_Pos
	backwards.allocator = context.temp_allocator
	for p := best; p != start; p = came[p] {append(&backwards, p)}
	n := min(len(backwards), MAX_PATH)
	for i in 0 ..< n {path.steps[i] = backwards[len(backwards) - 1 - i]}
	path.count = n
	path.whole = best == goal && len(backwards) <= MAX_PATH
	return path, true
}

// reach: where a walker in `from` ends up moving into the column of `step`
// (same height, one up, or dropping), and what that costs on top of the
// distance; false if it cannot.
@(private = "file")
reach :: proc(
	q: game.Block_Query,
	from, step: game.Block_Pos,
) -> (
	to: game.Block_Pos,
	extra: f32,
	ok: bool,
) {
	if standable(q, step) {return step, 0, true}
	up := step + {0, 1, 0}
	if game.solid_at(q, step) {
		// Step up: room over our head to jump, and a place to stand.
		if !game.solid_at(q, from + {0, 1, 0}) && standable(q, up) {return up, 0.5, true}
		return {}, 0, false
	}
	// Open air: drop until the ground (not too far).
	for drop in 1 ..= MAX_DROP {
		down := step - {0, i32(drop), 0}
		if game.solid_at(q, down) {return {}, 0, false}
		if standable(q, down) {return down, 0.3 * f32(drop), true}
	}
	return {}, 0, false
}

// guess: the remaining cost at best (octile distance, and height).
@(private = "file")
guess :: proc(a, b: game.Block_Pos) -> f32 {
	dx, dz := f32(abs(a.x - b.x)), f32(abs(a.z - b.z))
	return max(dx, dz) + (math.SQRT_TWO - 1) * min(dx, dz) + 0.5 * f32(abs(a.y - b.y))
}

@(private = "file", rodata)
NEIGHBOURS := [8][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
