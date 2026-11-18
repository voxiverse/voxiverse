package path

import pq "core:container/priority_queue"
import "core:mem"

import "common:game"
import "common:voxel"

// Fields: the cost of the way to one goal from every block a body can stand in
// within an area, found by one search outward from the goal (Dijkstra over the
// moves a walker makes, taken backwards). Every walker in the area then takes the
// move that costs least from where it stands (field_next): a wave of a tower
// defence to its core, a herd to its pen, workers to a store, all for the price of
// one search however many walk. A block from which no way leads has no cost; so
// "is there still a way from A to the goal" is a lookup, and "would a block there
// shut it" a search with that block in place (with_block).

MAX_FIELD_BLOCKS :: 1 << 20 // blocks an area holds at most (4 MiB of costs)

// NO_WAY: the cost of a block from which the goal cannot be reached.
NO_WAY :: max(f32)

Field :: struct {
	lo, hi:    game.Block_Pos, // the area, inclusive
	size:      [3]i32,
	goal:      game.Block_Pos,
	body:      Body,
	cost:      []f32, // per block of the area: x fastest, then z, then y
	reached:   int, // blocks from which the goal is reached (the last field_build)
	// The solid blocks as they were at the last field_build, over the area and the margin
	// a body's moves look at (field_grid: GRID_BELOW under it, MAX_BODY beyond): a search
	// reads them here, not through a query, and a walker's next move is judged against
	// the same blocks its cost was found with. Outside it, everything is solid.
	solid:     voxel.Mask,
	allocator: mem.Allocator,
}

// GRID_BELOW: blocks under the area a field keeps (the ground its lowest walkers
// stand on).
GRID_BELOW :: 1

// field_make: a field over the area lo..hi (inclusive) with no way anywhere; false
// for an area over MAX_FIELD_BLOCKS (or upside down).
field_make :: proc(
	f: ^Field,
	lo, hi: game.Block_Pos,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	size := hi - lo + 1
	if size.x <= 0 || size.y <= 0 || size.z <= 0 {return false}
	if i64(size.x) * i64(size.y) * i64(size.z) > MAX_FIELD_BLOCKS {return false}
	cost, err := make([]f32, int(size.x * size.y * size.z), allocator, loc)
	if err != nil {return false}
	f^ = {
		lo        = lo,
		hi        = hi,
		size      = size,
		cost      = cost,
		allocator = allocator,
	}
	f.solid = voxel.mask_make(field_grid(f), allocator, loc)
	for &c in f.cost {c = NO_WAY}
	return true
}

field_destroy :: proc(f: ^Field) {
	delete(f.cost, f.allocator)
	voxel.mask_destroy(&f.solid, f.allocator)
	f^ = {}
}

// field_grid: the cells a field keeps the blocks of: its area, GRID_BELOW under it, a
// block before it and MAX_BODY beyond it along x and z, MAX_BODY + 1 over it.
field_grid :: proc(f: ^Field) -> voxel.Bounds {
	return {f.lo - {1, GRID_BELOW, 1}, f.hi + 1 + {MAX_BODY, MAX_BODY + 1, MAX_BODY}}
}

// field_solid: the field's copy of the blocks, as a search reads them.
@(private = "file")
field_solid :: proc(f: ^Field) -> Solid {
	return {f, proc(data: rawptr, p: game.Block_Pos) -> bool {
			return voxel.mask_get((^Field)(data).solid, p)
		}}
}

// field_index: p's place in the cost array; false outside the area.
field_index :: proc(f: ^Field, p: game.Block_Pos) -> (int, bool) {
	d := p - f.lo
	if d.x < 0 || d.y < 0 || d.z < 0 || d.x >= f.size.x || d.y >= f.size.y || d.z >= f.size.z {
		return 0, false
	}
	return int(d.x + f.size.x * (d.z + f.size.z * d.y)), true
}

// field_cost: what the way to the goal costs from p (a block the body stands in);
// false when there is none (or p is outside the area).
field_cost :: proc(f: ^Field, p: game.Block_Pos) -> (cost: f32, ok: bool) {
	i := field_index(f, p) or_return
	return f.cost[i], f.cost[i] != NO_WAY
}

// field_build searches from the goal (a block the body stands in) over the area, with
// solid the solid blocks (game.solid_at's) over field_grid at least: every block a body
// of that size can reach the goal from gets its cost. Returns how many it reached (0: the
// goal is not standable or outside). Moves never leave the area.
field_build :: proc(f: ^Field, solid: voxel.Mask, goal: game.Block_Pos, body := SMALL) -> int {
	g, s := f.solid.bounds, solid.bounds
	covers := s.lo.x <= g.lo.x && s.lo.y <= g.lo.y && s.lo.z <= g.lo.z
	covers &&= s.hi.x >= g.hi.x && s.hi.y >= g.hi.y && s.hi.z >= g.hi.z
	assert(covers, "a field built from blocks short of its grid")
	voxel.mask_copy(&f.solid, solid)
	f.solid.outside = true // (past the grid: a search never reads there)
	return field_search(f, goal, body)
}

// field_trial: a search over `from`'s copy of the blocks with the block at `at` solid or
// not (solid): would a block there shut the way? `trial` (made with field_make over the
// same area) gets the answer; `from` is left as it was. What the blocks were is not read
// again, so a question costs a search, not a look at every block of the area.
field_trial :: proc(trial, from: ^Field, at: game.Block_Pos, solid: bool) -> int {
	assert(trial.lo == from.lo && trial.hi == from.hi, "a trial field over another area")
	voxel.mask_copy(&trial.solid, from.solid)
	if voxel.bounds_has(trial.solid.bounds, at) {voxel.mask_set(&trial.solid, at, solid)}
	return field_search(trial, from.goal, from.body)
}

// field_search: the search of field_build over the field's copy of the blocks.
@(private = "file")
field_search :: proc(f: ^Field, goal: game.Block_Pos, body: Body) -> int {
	f.goal, f.body, f.reached = goal, body, 0
	for &c in f.cost {c = NO_WAY}
	solid := field_solid(f)
	// Where the body stands, once (most blocks are air in midair, or inside the ground).
	stand := voxel.mask_make({f.lo, f.hi + 1}, context.temp_allocator)
	standable_mask(&stand, f.solid, body)
	at, inside := field_index(f, goal)
	if !inside || !voxel.mask_get(stand, goal) {return 0}
	Node :: struct {
		pos:  game.Block_Pos,
		cost: f32,
	}
	open: pq.Priority_Queue(Node)
	pq.init(
		&open,
		proc(a, b: Node) -> bool {return a.cost < b.cost},
		pq.default_swap_proc(Node),
		256,
		context.temp_allocator,
	)
	f.cost[at] = 0
	pq.push(&open, Node{goal, 0})
	for pq.len(open) > 0 {
		n := pq.pop(&open)
		i, _ := field_index(f, n.pos)
		if n.cost > f.cost[i] {continue} 	// (a stale entry: found cheaper since)
		f.reached += 1
		// Whoever could move into n.pos: from the column behind each direction, at
		// the same height, one lower (a step up) or up to MAX_DROP higher (a drop).
		for d in NEIGHBOURS {
			for dy in i32(-1) ..= MAX_DROP {
				from := game.Block_Pos{n.pos.x - d.x, n.pos.y + dy, n.pos.z - d.y}
				j, in_area := field_index(f, from)
				if !in_area || !voxel.mask_get(stand, from) || f.cost[j] <= n.cost {continue}
				to, length, extra, can := move(solid, from, d, body)
				if !can || to != n.pos {continue}
				c := n.cost + length + extra
				if c < f.cost[j] {
					f.cost[j] = c
					pq.push(&open, Node{from, c})
				}
			}
		}
	}
	return f.reached
}

// field_next: the block a walker standing in `from` goes to next (the move that costs
// least, to a block with a way, among the blocks as they were at the last build);
// false at the goal, or where there is no way.
field_next :: proc(f: ^Field, from: game.Block_Pos) -> (to: game.Block_Pos, ok: bool) {
	here, has := field_cost(f, from)
	if !has || from == f.goal {return}
	best := here
	solid := field_solid(f)
	for d in NEIGHBOURS {
		next, length, extra, can := move(solid, from, d, f.body)
		if !can {continue}
		there, has_way := field_cost(f, next)
		if has_way && there + length + extra <= best + 0.001 && there < here {
			to, ok, best = next, true, there + length + extra
		}
	}
	return
}
