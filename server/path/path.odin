package path

import pq "core:container/priority_queue"
import "core:math"

import "common:game"
import "common:voxel"

// Pathfinding for walking entities: A* over the block grid. A walker of a Body
// stands in blocks of air (its footprint, as tall as it is) over solid ground;
// from there it can walk to any of the 8 neighbours (diagonals only past two
// open sides: no cutting corners), step up one block (with room overhead) or
// drop down at most MAX_DROP. Unloaded chunks count as walls. A search expands
// at most `budget` blocks; if the goal is not reached it returns the way to the
// block that got closest, so the walker still heads the right way. Many walkers
// with one goal share a Field instead (field.odin): one search for all of them.

MAX_DROP :: 3
MAX_PATH :: 32 // waypoints kept
MAX_BODY :: 4 // blocks a body is wide or tall at most (a kind's box is at most 4)

// Body: the blocks a walker needs: a square footprint `width` blocks a side (from
// the block it stands in towards +x and +z: a body two wide stands with its centre
// on that block's far corner) and `height` blocks of air from its feet up; and
// whether it climbs a block's step (`climb` 1: jumps up one; 0: walks round it).
Body :: struct {
	width, height, climb: i32,
}

// SMALL: one block of air on solid ground, climbing steps (a creature a block high).
SMALL :: Body{1, 1, 1}

// body_of: the body a box needs, width (x and z) by height in blocks, climbing a
// step if it jumps a block high.
body_of :: proc(box: [2]f32, jump: f32) -> Body {
	blocks :: proc(x: f32) -> i32 {return clamp(i32(math.ceil(x - 0.001)), 1, MAX_BODY)}
	return {blocks(box[0]), blocks(box[1]), 1 if jump >= 1 else 0}
}

// body_center: where a body standing in p has its centre (the bottom of its box).
body_center :: proc(p: game.Block_Pos, body: Body) -> [3]f64 {
	half := f64(body.width) / 2
	return {f64(p.x) + half, f64(p.y), f64(p.z) + half}
}

// body_block: the block a body whose box's bottom centre is at `at` stands in.
body_block :: proc(at: [3]f64, body: Body) -> game.Block_Pos {
	half := f64(body.width) / 2
	return {
		i32(math.floor(at.x - half + 0.5)),
		i32(math.floor(at.y + 0.01)),
		i32(math.floor(at.z - half + 0.5)),
	}
}

Path :: struct {
	steps: [MAX_PATH]game.Block_Pos, // the blocks to stand in, in order (not the start)
	count: int,
	whole: bool, // reaches the goal (else: as near as the budget got)
}

// Solid: what a search asks of the blocks: whether p is solid (a query's
// game.solid_at, or a field's copy of its area: grid.odin).
Solid :: struct {
	data:  rawptr,
	solid: proc(data: rawptr, p: game.Block_Pos) -> bool,
}

// solid_of: the blocks as q has them.
solid_of :: proc(q: ^game.Block_Query) -> Solid {
	return {q, proc(data: rawptr, p: game.Block_Pos) -> bool {
			return game.solid_at((^game.Block_Query)(data)^, p)
		}}
}

// open: the body fits in p: no solid block in its footprint, its height up.
open :: proc(q: game.Block_Query, p: game.Block_Pos, body := SMALL) -> bool {
	q := q
	return fits(solid_of(&q), p, body)
}

// standable: a walker can stand in p: it fits, with solid ground under its footprint
// (under one of its blocks at least). standable_mask says it of a box of cells at once.
standable :: proc(q: game.Block_Query, p: game.Block_Pos, body := SMALL) -> bool {
	q := q
	return stands(solid_of(&q), p, body)
}

// standable_mask: dst becomes the cells of its bounds a body stands in over the solid
// cells: erode(free, body) ∩ (solid moved up one ⊕ the footprint turned back), the cells
// where all of the body is free and some of its footprint is over solid ground. A cell
// outside solid's bounds is neither free nor ground, so solid's bounds hold the body
// and the row under it for every cell of dst (a field's grid does). The cells
// `standable` says one at a time.
standable_mask :: proc(
	dst: ^voxel.Mask,
	solid: voxel.Mask,
	body: Body,
	allocator := context.temp_allocator,
) {
	free := voxel.mask_make(solid.bounds, allocator)
	defer voxel.mask_destroy(&free, allocator)
	voxel.mask_copy(&free, solid)
	voxel.complement(&free)
	room := voxel.mask_full({{}, {body.width, body.height, body.width}}, allocator)
	defer voxel.mask_destroy(&room, allocator)
	voxel.erode(dst, free, room)
	under := voxel.mask_full({{1 - body.width, 0, 1 - body.width}, {1, 1, 1}}, allocator)
	defer voxel.mask_destroy(&under, allocator)
	ground := voxel.mask_make({dst.bounds.lo - {0, 1, 0}, dst.bounds.hi - {0, 1, 0}}, allocator)
	defer voxel.mask_destroy(&ground, allocator)
	voxel.dilate(&ground, solid, under)
	voxel.translate(&ground, {0, 1, 0})
	voxel.intersect(dst, ground)
}

// fits and stands: standable_mask's rule at one cell (a search with no box of cells to
// make masks over asks them as it goes).
@(private)
fits :: proc(s: Solid, p: game.Block_Pos, body: Body) -> bool {
	for dy in 0 ..< body.height {
		for dz in 0 ..< body.width {
			for dx in 0 ..< body.width {
				if s.solid(s.data, p + {dx, dy, dz}) {return false}
			}
		}
	}
	return true
}

@(private)
stands :: proc(s: Solid, p: game.Block_Pos, body: Body) -> bool {
	if !fits(s, p, body) {return false}
	for dz in 0 ..< body.width {
		for dx in 0 ..< body.width {
			if s.solid(s.data, p + {dx, -1, dz}) {return true}
		}
	}
	return false
}

// crosses: the path goes through or beside the box lo..hi (a block there changed:
// the way may be shut, or a shorter one open), counting the body's blocks.
crosses :: proc(p: ^Path, lo, hi: game.Block_Pos, body := SMALL) -> bool {
	for s in p.steps[:p.count] {
		if s.x + body.width < lo.x || s.x - 1 > hi.x {continue}
		if s.z + body.width < lo.z || s.z - 1 > hi.z {continue}
		if s.y + body.height < lo.y || s.y - 2 > hi.y {continue}
		return true
	}
	return false
}

// find searches from start to goal (both blocks to stand in).
find :: proc(
	q: game.Block_Query,
	start, goal: game.Block_Pos,
	budget: int,
	body := SMALL,
) -> (
	path: Path,
	ok: bool,
) {
	q := q
	solid := solid_of(&q)
	if !stands(solid, start, body) {return}
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
	// What each block was expanded at: popped again at that cost (a stale entry) it would
	// move nothing, so it is skipped and costs none of the budget. Found cheaper since, it
	// is expanded again, as it always was.
	expanded_at := make(map[game.Block_Pos]f32, 256, context.temp_allocator)
	pq.push(&open, Node{start, guess(start, goal)})
	best, best_h := start, guess(start, goal)
	for expanded := 0; pq.len(open) > 0 && expanded < budget; {
		at := pq.pop(&open).pos
		if c, seen := expanded_at[at]; seen && c == cost[at] {continue}
		expanded_at[at] = cost[at]
		expanded += 1
		if at == goal {
			best, best_h = at, 0
			break
		}
		if h := guess(at, goal); h < best_h {best, best_h = at, h}
		for d in NEIGHBOURS {
			to, length, extra, can := move(solid, at, d, body)
			if !can {continue}
			c := cost[at] + length + extra // (in this order: the sum is the same to the bit as it ever was)
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

// move: where a walker in `from` ends up going one block in direction d (x, z: one
// of NEIGHBOURS), and what that costs: its length (1 or a diagonal's) and what a
// climb or a drop adds; false if it cannot. Diagonals only past two open sides.
@(private)
move :: proc(
	s: Solid,
	from: game.Block_Pos,
	d: [2]i32,
	body: Body,
) -> (
	to: game.Block_Pos,
	length, extra: f32,
	ok: bool,
) {
	step := game.Block_Pos{from.x + d.x, from.y, from.z + d.y}
	if d.x != 0 && d.y != 0 {
		// Diagonal: both sides it passes must be open at this height.
		if !fits(s, {from.x + d.x, from.y, from.z}, body) ||
		   !fits(s, {from.x, from.y, from.z + d.y}, body) {
			return
		}
	}
	to, extra, ok = reach(s, from, step, body)
	return to, math.SQRT_TWO if d.x != 0 && d.y != 0 else 1, extra, ok
}

// reach: where a walker in `from` ends up moving into the column of `step`
// (same height, one up, or dropping), and what that costs on top of the
// distance; false if it cannot.
@(private = "file")
reach :: proc(
	s: Solid,
	from, step: game.Block_Pos,
	body: Body,
) -> (
	to: game.Block_Pos,
	extra: f32,
	ok: bool,
) {
	if stands(s, step, body) {return step, 0, true}
	up := step + {0, 1, 0}
	if !fits(s, step, body) {
		// Step up: a climber with room over its head to jump, and a place to stand.
		if body.climb > 0 && fits(s, from + {0, 1, 0}, body) && stands(s, up, body) {
			return up, 0.5, true
		}
		return {}, 0, false
	}
	// Open air: drop until the ground (not too far).
	for drop in 1 ..= MAX_DROP {
		down := step - {0, i32(drop), 0}
		if !fits(s, down, {body.width, 1, 0}) {return {}, 0, false}
		if stands(s, down, body) {return down, 0.3 * f32(drop), true}
	}
	return {}, 0, false
}

// guess: the remaining cost at best (octile distance, and height).
@(private = "file")
guess :: proc(a, b: game.Block_Pos) -> f32 {
	dx, dz := f32(abs(a.x - b.x)), f32(abs(a.z - b.z))
	return max(dx, dz) + (math.SQRT_TWO - 1) * min(dx, dz) + 0.5 * f32(abs(a.y - b.y))
}

@(rodata)
NEIGHBOURS := [8][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}

// With_Block: a query in which one block reads as another, to ask about a
// placement before it is made (would this wall shut the way?).
With_Block :: struct {
	q:     game.Block_Query,
	at:    game.Block_Pos,
	block: game.Block,
}

// with_block: q, but the block at w.at reads as w.block (w must outlive its use).
with_block :: proc(w: ^With_Block) -> game.Block_Query {
	return {w, proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
			w := (^With_Block)(data)
			if p == w.at {return w.block, true}
			return w.q.get(w.q.data, p)
		}, w.q.table, w.q.extra}
}
