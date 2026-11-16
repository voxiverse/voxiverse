package path

import pq "core:container/priority_queue"
import "core:mem"

import "common:game"

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
	// The blocks as they were at the last field_build, solid or not, over the area and
	// the margin a body's moves look at (GRID_BELOW under it, MAX_BODY beyond): a search
	// reads them here, not through a query, and a walker's next move is judged against
	// the same blocks its cost was found with. Outside it, everything is solid.
	grid_lo:   game.Block_Pos,
	grid_size: [3]i32,
	solid:     []bool,
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
	grid_lo := lo - {1, GRID_BELOW, 1}
	grid_size := size + {1 + MAX_BODY, GRID_BELOW + MAX_BODY + 1, 1 + MAX_BODY}
	cost, err := make([]f32, int(size.x * size.y * size.z), allocator, loc)
	if err != nil {return false}
	solid, err2 := make([]bool, int(grid_size.x * grid_size.y * grid_size.z), allocator, loc)
	if err2 != nil {
		delete(cost, allocator)
		return false
	}
	f^ = {
		lo        = lo,
		hi        = hi,
		size      = size,
		cost      = cost,
		grid_lo   = grid_lo,
		grid_size = grid_size,
		solid     = solid,
		allocator = allocator,
	}
	for &c in f.cost {c = NO_WAY}
	return true
}

field_destroy :: proc(f: ^Field) {
	delete(f.cost, f.allocator)
	delete(f.solid, f.allocator)
	f^ = {}
}

// field_solid: the field's copy of the blocks, as a search reads them.
@(private = "file")
field_solid :: proc(f: ^Field) -> Solid {
	return {f, proc(data: rawptr, p: game.Block_Pos) -> bool {
			f := (^Field)(data)
			d := p - f.grid_lo
			if d.x < 0 || d.y < 0 || d.z < 0 {return true}
			if d.x >= f.grid_size.x || d.y >= f.grid_size.y || d.z >= f.grid_size.z {return true}
			return f.solid[d.x + f.grid_size.x * (d.z + f.grid_size.z * d.y)]
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

// field_build searches from the goal (a block the body stands in) over the area: every
// block a body of that size can reach the goal from gets its cost. Returns how many
// it reached (0: the goal is not standable or outside). Moves never leave the area.
field_build :: proc(f: ^Field, q: game.Block_Query, goal: game.Block_Pos, body := SMALL) -> int {
	f.goal, f.body, f.reached = goal, body, 0
	for &c in f.cost {c = NO_WAY}
	cell := 0
	for y in 0 ..< f.grid_size.y {
		for z in 0 ..< f.grid_size.z {
			for x in 0 ..< f.grid_size.x {
				f.solid[cell] = game.solid_at(q, f.grid_lo + {x, y, z})
				cell += 1
			}
		}
	}
	solid := field_solid(f)
	at, inside := field_index(f, goal)
	if !inside || !stands(solid, goal, body) {return 0}
	// Where the body stands, once (most blocks are air in midair, or inside the ground).
	stand := make([]bool, len(f.cost), context.temp_allocator)
	cell = 0
	for y in f.lo.y ..= f.hi.y {
		for z in f.lo.z ..= f.hi.z {
			for x in f.lo.x ..= f.hi.x {
				stand[cell] = stands(solid, {x, y, z}, body)
				cell += 1
			}
		}
	}
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
				if !in_area || !stand[j] || f.cost[j] <= n.cost {continue}
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
