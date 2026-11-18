package voxel

import pq "core:container/priority_queue"
import "core:math/bits"

// Least cost: a spread in which each move has an integer cost and each source a start
// value, and each cell gets the least, over the sources and the chains of moves that lead
// from them to it, of the source's value plus the moves' costs. Breadth-first distance is
// the case of every move costing 1 and every source 0 (`distance`, `nearest`); a walker's
// way with diagonals dearer than straight steps, or light that starts brighter at one
// source than at another and fades a level a cell, are others.
//
// The work is a row at a time, as a fill's: a row whose cells got cheaper is queued, and
// taking it spreads the change along x within the row (a pass each way) and then to the
// rows the other moves reach, a word of the domain and a run of values at a time. The
// queue takes the row holding the cheapest change first (Dijkstra's order, by rows), so
// when the cheapest change waiting costs c, every cell that costs less than c has its
// cost: a spread can stop at a cost, or at the first cell of a goal, and what it has is
// exact. A row is taken again only when a cheaper way into it is found after it was
// taken (in the open, under unit steps, each row is taken once).
//
// While it runs, a cell holds its potential, top less its cost (top one more than the
// limit), 0 or less when it is not reached and BLOCKED outside the domain: a move is
// then max(there, here - cost), a run of cells at a time without a branch, and a cost
// past the limit falls out as a potential of 0 or less. Light is this form already: a
// level is 15 less a distance.

// Move: a step of a spread to the cell `offset` away, for `cost` (0 or more). With `from`,
// the step is taken only from a cell of that mask: the move's own condition (a diagonal
// past two open sides, a climb with room overhead), built with the set algebra. A move
// taken backwards (a search from a goal) is the move with the opposite offset, from the
// cells of `from` translated by the offset.
Move :: struct {
	offset: Cell,
	cost:   i32,
	from:   ^Mask,
}

// moves_of: each offset of element, the origin aside, as a move of that cost: an element's
// steps, as `distance` takes them. In the element's order (y, then z, then x).
moves_of :: proc(element: Mask, cost: i32 = 1, allocator := context.allocator) -> []Move {
	out := make([dynamic]Move, allocator)
	cursor := 0
	for lo, n in runs_next(element, &cursor) {
		for k in 0 ..< n {
			o := lo + {k, 0, 0}
			if o != {} {append(&out, Move{offset = o, cost = cost})}
		}
	}
	return out[:]
}

// least_cost: out (the seeds: each source cell's start value, 0 or more, and UNREACHED on
// every other cell) becomes each cell's least cost: the least, over the seeds and the
// chains of moves leading from them to the cell through cells of domain, of the seed's
// value plus the moves' costs. A seed outside domain is dropped; a cell whose least cost
// is more than limit, or that nothing reaches, is UNREACHED. Each cost is at most
// MAX_COST. out and domain share their bounds.
//
// stop (none by default): the spread ends once the cheapest cell of stop it can reach has
// its cost: out is then the full result cut to that cost (each cell costing at most that
// has its cost, every other cell is UNREACHED). A goal is a mask of one cell.
//
// The budget counts cells: each row taken costs its length. Exhausted: out is the full
// result cut to the costs below that of the cheapest change still waiting.
least_cost :: proc(
	out: ^Field,
	domain: Mask,
	moves: []Move,
	limit: int,
	budget: int,
	stop := Mask{},
	allocator := context.allocator,
) -> (
	exhausted: bool,
) {
	assert(out.bounds == domain.bounds, "voxel: least_cost into a field of other bounds")
	size := bounds_size(domain.bounds)
	sx, sz := int(size.x), int(size.z)
	limit := i32(clamp(limit, -1, int(BLOCKED) - 2))
	top := limit + 1 // a cell's potential is top less its cost (below BLOCKED)
	// The moves along the row toward higher x, toward lower x, and to other rows; how far
	// the first two reach, and whether each is one cell (then a pass each way is enough).
	for m in moves {
		assert(m.cost >= 0 && m.cost <= MAX_COST, "voxel: a move's cost out of range")
	}
	sorted := make([dynamic]Move, 0, len(moves), allocator)
	defer delete(sorted)
	ends: [3]int
	for side in 0 ..< 3 {
		for m in moves {if move_side(m) == side {append(&sorted, m)}}
		ends[side] = len(sorted)
	}
	up_moves, down_moves := sorted[:ends[0]], sorted[ends[0]:ends[1]]
	other_moves := sorted[ends[1]:ends[2]]
	reach := 0
	single := true
	for m in sorted[:ends[1]] {
		reach = max(reach, int(abs(m.offset.x)))
		if abs(m.offset.x) != 1 {single = false}
	}
	// One step each way at most, taken from anywhere: a slide along the row.
	slide := single && len(up_moves) <= 1 && len(down_moves) <= 1
	for m in sorted[:ends[1]] {if m.from != nil {slide = false}}
	r := rows_make(rows_of(domain), sx, allocator)
	defer rows_destroy(&r)
	// The cells outside the domain are BLOCKED, the seeds potentials.
	for row in 0 ..< rows_of(domain) {
		values := out.values[row * sx:][:sx]
		dom := row_words(domain, row)
		for w, i in dom {
			for rest := ~w & span_bits(i, 0, sx); rest != 0; rest &= rest - 1 {
				values[i * 64 + int(bits.count_trailing_zeros(rest))] = BLOCKED
			}
		}
		lo, hi := sx, 0
		dearest := i32(0)
		for &v, x in values {
			if v == UNREACHED || v == BLOCKED {continue}
			assert(v >= 0 && v <= MAX_COST, "voxel: a seed out of range")
			v = top - v if v <= limit else UNREACHED
			if v > 0 {
				lo, hi = min(lo, x), x + 1
				dearest = max(dearest, v)
			}
		}
		if lo < hi {rows_mark(&r, row, lo, hi, dearest)}
	}
	stopping := len(stop.words) > 0
	goal := i32(0) // the potential of the cheapest cell of stop reached
	left := budget
	for pq.len(r.queue) > 0 {
		next := pq.pop(&r.queue)
		row := int(next.row)
		if next.potential != r.waiting[row] {continue} 	// (cheaper since)
		if goal > 0 && next.potential < goal {break}
		if left < sx {
			rows_finish(out, top, next.potential)
			return true
		}
		left -= sx
		r.waiting[row] = 0
		lo, hi := int(r.lo[row]), int(r.hi[row])
		r.lo[row], r.hi[row] = i32(sx), 0
		values := out.values[row * sx:][:sx]
		y, z := i32(row / sz), i32(row % sz)
		// Along the row, until nothing changes.
		if slide {
			if len(up_moves) > 0 {hi = cost_slide_up(values, lo, hi, up_moves[0].cost)}
			if len(down_moves) > 0 {lo = cost_slide_down(values, lo, hi, down_moves[0].cost)}
		}
		for reach > 0 && !slide {
			changed := false
			for x := lo; x < sx && x < hi + reach; x += 1 {
				for m in up_moves {
					o := int(m.offset.x)
					if x - o < 0 {continue}
					p := cost_step(values[x - o], m, domain.bounds.lo + {i32(x - o), y, z})
					if p > values[x] {
						values[x] = p
						hi = max(hi, x + 1)
						changed = true
					}
				}
			}
			for x := hi - 1; x >= 0 && x >= lo - reach; x -= 1 {
				for m in down_moves {
					o := int(m.offset.x)
					if x - o >= sx {continue}
					p := cost_step(values[x - o], m, domain.bounds.lo + {i32(x - o), y, z})
					if p > values[x] {
						values[x] = p
						lo = min(lo, x)
						changed = true
					}
				}
			}
			if single || !changed {break}
		}
		if stopping {
			for x in lo ..< hi {
				if values[x] > goal &&
				   values[x] != BLOCKED &&
				   mask_get(stop, domain.bounds.lo + {i32(x), y, z}) {
					goal = values[x]
				}
			}
		}
		// To the other rows.
		for m in other_moves {
			ty, tz := domain.bounds.lo.y + y + m.offset.y, domain.bounds.lo.z + z + m.offset.z
			t := row_at(domain, ty, tz) or_continue
			o := int(m.offset.x)
			a, b := max(lo, -o), min(hi, sx - o)
			if a >= b {continue}
			from := values[a:b]
			there := out.values[t * sx + a + o:][:b - a]
			allowed: []u64 // (the cells of the move's own, from from[0] on)
			buf: [MAX_STRIDE]u64
			if m.from != nil {
				f := row_at(m.from^, domain.bounds.lo.y + y, domain.bounds.lo.z + z) or_continue
				allowed = buf[:(b - a + 63) / 64]
				start := int(domain.bounds.lo.x - m.from.bounds.lo.x) + a
				bits_at(row_words(m.from^, f), start, allowed)
			}
			best := cost_spread(there, from, m.cost, allowed)
			if best > 0 {rows_mark(&r, t, a + o, b + o, best)}
		}
	}
	rows_finish(out, top, goal - 1)
	return false
}

// descend: a step from at back along a least-cost way: the cell of the first move (in the
// order given) that reaches at from a cell whose value plus the move's cost is at's value.
// ok false at a cell no move explains (a seed with its own value) or not reached. From a
// cell of a least-cost field, descending until it fails walks one of the cheapest ways
// back to a seed, in reverse (when no chain of moves of cost 0 is a loop).
descend :: proc(f: Field, at: Cell, moves: []Move) -> (next: Cell, ok: bool) {
	v := field_get(f, at)
	if v == UNREACHED {return}
	for m in moves {
		c := at - m.offset
		if m.from != nil && !mask_get(m.from^, c) {continue}
		u := field_get(f, c)
		if u != UNREACHED && u + m.cost == v && c != at {return c, true}
	}
	return
}

// distance: out gets each cell of domain the fewest steps (one offset of element each,
// through cells of domain) from a cell of sources, 0 on the sources' cells in domain, and
// UNREACHED for a cell further than max_steps or out of reach: least_cost with every
// move costing 1 and every source 0. out and domain share their bounds. Exhausted: every
// cell within the last step completed has its distance and every other cell is
// UNREACHED.
distance :: proc(
	out: ^Field,
	sources: Mask,
	domain: Mask,
	element: Mask,
	max_steps: int,
	budget: int,
	allocator := context.allocator,
) -> (
	exhausted: bool,
) {
	assert(out.bounds == domain.bounds, "voxel: distance into a field of other bounds")
	for &v in out.values {v = UNREACHED}
	seeds := mask_make(domain.bounds, allocator)
	defer mask_destroy(&seeds, allocator)
	unite(&seeds, sources)
	for row in 0 ..< rows_of(seeds) {write_row(out, seeds, row, 0)}
	moves := moves_of(element, 1, allocator)
	defer delete(moves, allocator)
	return least_cost(out, domain, moves, max_steps, budget, {}, allocator)
}

// nearest: the cell of targets fewest steps from `from` through domain (as `distance`
// counts them), the lowest by y, then z, then x among those as near; steps is its
// distance. found false: none within max_steps. targets and domain share their bounds.
nearest :: proc(
	targets: Mask,
	from: Cell,
	domain: Mask,
	element: Mask,
	max_steps: int,
	budget: int,
	allocator := context.allocator,
) -> (
	c: Cell,
	steps: int,
	found: bool,
	exhausted: bool,
) {
	assert(targets.bounds == domain.bounds, "voxel: nearest in masks with different bounds")
	f := field_make(domain.bounds, allocator)
	defer field_destroy(&f, allocator)
	if !bounds_has(f.bounds, from) {return}
	f.values[field_index(f, from)] = 0
	moves := moves_of(element, 1, allocator)
	defer delete(moves, allocator)
	if least_cost(&f, domain, moves, max_steps, budget, targets, allocator) {
		return {}, 0, false, true
	}
	// Every target reached costs what the first one settled did.
	sx := int(f.bounds.hi.x - f.bounds.lo.x)
	sz := int(f.bounds.hi.z - f.bounds.lo.z)
	for w, i in targets.words {
		for rest := w; rest != 0; rest &= rest - 1 {
			row := i / targets.stride
			x := (i % targets.stride) * 64 + int(bits.count_trailing_zeros(rest))
			v := f.values[row * sx + x]
			if v == UNREACHED {continue}
			return domain.bounds.lo + {i32(x), i32(row / sz), i32(row % sz)}, int(v), true, false
		}
	}
	return
}

// MAX_COST: the most a move or a seed costs (a cost and a potential then never overflow).
MAX_COST :: 1 << 24

// move_side: 0 for a move along the row toward higher x, 1 toward lower x, 2 to another
// row, -1 for none.
@(private)
move_side :: proc(m: Move) -> int {
	switch {
	case m.offset.y != 0 || m.offset.z != 0:
		return 2
	case m.offset.x > 0:
		return 0
	case m.offset.x < 0:
		return 1
	}
	return -1
}

// BLOCKED: the potential least_cost gives a cell outside the domain while it runs: no
// move raises it, and a move from it gives nothing.
@(private)
BLOCKED :: max(i32)

// cost_step: the potential a move from a cell of potential p (at from) gives: p less the
// move's cost, or -1 from a cell not reached, outside the domain or outside the move's
// own cells.
@(private)
cost_step :: #force_inline proc(p: i32, m: Move, from: Cell) -> i32 {
	if p <= 0 || p == BLOCKED || (m.from != nil && !mask_get(m.from^, from)) {return -1}
	return p - m.cost
}

// cost_slide_up: a step toward higher x for cost, taken along values from lo on and on
// past hi as long as it changes a cell; the new hi.
@(private)
cost_slide_up :: proc(values: []i32, lo, hi: int, cost: i32) -> int {
	hi := hi
	carry := values[lo - 1] if lo > 0 && values[lo - 1] != BLOCKED else -1
	#no_bounds_check for x in lo ..< len(values) {
		v := values[x]
		if v == BLOCKED {
			carry = -1
		} else {
			if carry - cost > v {
				v = carry - cost
				values[x] = v
				hi = max(hi, x + 1)
			}
			carry = v
		}
		if x >= hi {break}
	}
	return hi
}

// cost_slide_down: cost_slide_up toward lower x, from hi - 1 down; the new lo.
@(private)
cost_slide_down :: proc(values: []i32, lo, hi: int, cost: i32) -> int {
	lo := lo
	carry := values[hi] if hi < len(values) && values[hi] != BLOCKED else -1
	#no_bounds_check for x := hi - 1; x >= 0; x -= 1 {
		v := values[x]
		if v == BLOCKED {
			carry = -1
		} else {
			if carry - cost > v {
				v = carry - cost
				values[x] = v
				lo = min(lo, x)
			}
			carry = v
		}
		if x < lo {break}
	}
	return lo
}

// cost_spread: each cell of there gets what a move of that cost gives it from the cell of
// from at its place, when that is more (from only the cells whose bit of allowed is set,
// when it is given: a run of them at a time); the most any cell got (0: none). Without a
// branch within a run, so that it runs a vector at a time.
@(private)
cost_spread :: proc(there, from: []i32, cost: i32, allowed: []u64 = nil) -> (best: i32) {
	if allowed == nil {
		#no_bounds_check for p, i in from {
			q := p - cost if p != BLOCKED else -1
			old := there[i]
			new := max(old, q)
			there[i] = new
			best = max(best, new if new != old else 0)
		}
		return
	}
	for i := 0; i < len(from); {
		w := allowed[i >> 6] >> uint(i & 63)
		if w == 0 {
			i += 64 - i & 63
			continue
		}
		i += int(bits.count_trailing_zeros(w))
		if i >= len(from) {break}
		end := i
		for end < len(from) {
			rest := 64 - end & 63
			ones := int(bits.count_trailing_zeros(~(allowed[end >> 6] >> uint(end & 63))))
			end += min(ones, rest)
			if ones < rest {break}
		}
		end = min(end, len(from))
		best = max(best, cost_spread(there[i:end], from[i:end], cost))
		i = end
	}
	return
}

// Rows: what least_cost keeps of each row: the potential of its cheapest change waiting
// (0: none) and the span of x that changed since it was taken; and the queue of rows by
// that potential.
@(private)
Rows :: struct {
	waiting: []i32,
	lo, hi:  []i32,
	queue:   pq.Priority_Queue(Rows_Entry),
}

@(private)
Rows_Entry :: struct {
	potential, row: i32,
}

@(private)
rows_make :: proc(rows, width: int, allocator := context.allocator) -> Rows {
	r := Rows {
		waiting = make([]i32, rows, allocator),
		lo      = make([]i32, rows, allocator),
		hi      = make([]i32, rows, allocator),
	}
	for &v in r.lo {v = i32(width)}
	pq.init(&r.queue, proc(a, b: Rows_Entry) -> bool {
			return a.potential > b.potential || (a.potential == b.potential && a.row < b.row)
		}, pq.default_swap_proc(Rows_Entry), allocator = allocator)
	return r
}

@(private)
rows_destroy :: proc(r: ^Rows) {
	a := r.queue.queue.allocator
	delete(r.waiting, a)
	delete(r.lo, a)
	delete(r.hi, a)
	pq.destroy(&r.queue)
}

// rows_mark: the cells lo <= x < hi of row changed, the dearest of them now at potential
// p (the row is queued when that beats what it waits with).
@(private)
rows_mark :: proc(r: ^Rows, row, lo, hi: int, p: i32) {
	r.lo[row] = min(r.lo[row], i32(lo))
	r.hi[row] = max(r.hi[row], i32(hi))
	if p > r.waiting[row] {
		r.waiting[row] = p
		pq.push(&r.queue, Rows_Entry{p, i32(row)})
	}
}

// rows_finish: the potentials above cut become costs, every other cell UNREACHED.
@(private)
rows_finish :: proc(out: ^Field, top, below: i32) {
	cut := max(below, 0)
	#no_bounds_check for &v in out.values {v = top - v if v > cut && v != BLOCKED else UNREACHED}
}
