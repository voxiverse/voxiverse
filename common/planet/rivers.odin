package planet

import "common:base"
import pq "core:container/priority_queue"
import "core:math"

// Rivers and lakes from the relief, on the climate grid: depressions are filled
// (priority-flood), each cell is routed to its steepest lower neighbour on the
// filled surface, and the rain is accumulated downstream.

RIVER_FLOW :: 100.0 // flow (mm of rain, summed over the cells upstream, / 100) where a river begins
RIVER_WIDTH_MIN :: 2.0 // blocks
RIVER_WIDTH_MAX :: 24.0 // blocks
RIVER_FLOW_BIG :: 10000.0 // flow of the widest river (the Amazon's)
LAKE_DEPTH_M :: 5.0 // a filled depression this deep is a lake

Rivers :: struct {
	width, height: int,
	filled:        []f32, // metres: the land with its depressions filled to their spill level
	next:          []i32, // the cell a cell drains to; -1 for the sea (and for the sea's own cells)
	flow:          []f32, // rain summed over the cell and everything upstream, mm / 100
	lake:          []bool, // a filled depression, deep enough
}

rivers_destroy :: proc(r: ^Rivers) {
	delete(r.filled)
	delete(r.next)
	delete(r.flow)
	delete(r.lake)
	r^ = {}
}

@(private = "file")
Flood_Node :: struct {
	level: f32,
	order: int, // the order it was pushed in: ties pop first-in, first-out
	cell:  int,
}

// rivers_build routes every land cell to the sea. Deterministic on every OS.
rivers_build :: proc(l: Land, p: Precipitation, allocator := context.allocator) -> Rivers {
	w, h := l.width, l.height
	n := w * h
	r := Rivers {
		width  = w,
		height = h,
	}
	r.filled = make([]f32, n, allocator)
	r.next = make([]i32, n, allocator)
	r.flow = make([]f32, n, allocator)
	r.lake = make([]bool, n, allocator)
	for k in 0 ..< n {r.next[k] = -1}

	// Priority-flood from the sea: cells pop in nondecreasing filled level, a cell's
	// flood parent popped before it.
	q: pq.Priority_Queue(Flood_Node)
	pq.init(&q, proc(a, b: Flood_Node) -> bool {
			return a.level < b.level || (a.level == b.level && a.order < b.order)
		}, pq.default_swap_proc(Flood_Node), 1024, context.temp_allocator)
	seen := make([]bool, n, context.temp_allocator)
	parent := make([]i32, n, context.temp_allocator)
	popped := make([dynamic]int, 0, n, context.temp_allocator)
	pushed := 0
	for k in 0 ..< n {
		parent[k] = -1
		if !l.is_land[k] {
			seen[k] = true
			pq.push(&q, Flood_Node{0, pushed, k})
			pushed += 1
		}
	}
	for pq.len(q) > 0 {
		cur := pq.pop(&q)
		append(&popped, cur.cell)
		i, j := cur.cell % w, cur.cell / w
		for dj in -1 ..= 1 {
			jj := j + dj
			if jj < 0 || jj >= h {continue}
			for di in -1 ..= 1 {
				if di == 0 && dj == 0 {continue}
				nb := jj * w + (i + di + w) % w
				if seen[nb] {continue}
				seen[nb] = true
				parent[nb] = i32(cur.cell)
				level := max(l.elevation[nb], cur.level)
				r.filled[nb] = level
				pq.push(&q, Flood_Node{level, pushed, nb})
				pushed += 1
			}
		}
	}

	// Routing: the steepest strictly lower neighbour on the filled surface, else the
	// flood parent (the way out of a flat or a lake).
	for k in 0 ..< n {
		if !l.is_land[k] || !seen[k] {continue}
		i, j := k % w, k / w
		best, be := -1, r.filled[k]
		for dj in -1 ..= 1 {
			jj := j + dj
			if jj < 0 || jj >= h {continue}
			for di in -1 ..= 1 {
				if di == 0 && dj == 0 {continue}
				nb := jj * w + (i + di + w) % w
				if r.filled[nb] < be {best, be = nb, r.filled[nb]}
			}
		}
		r.next[k] = i32(best) if best >= 0 else parent[k]
		r.lake[k] = r.filled[k] - l.elevation[k] >= LAKE_DEPTH_M
	}

	// Accumulate the rain downstream, in reverse flood order (a cell's catchment is in
	// before it passes on).
	for k in 0 ..< n {
		if !l.is_land[k] {continue}
		annual := 0.0
		for m in 0 ..< 12 {annual += f64(p.month[m][k])}
		cell_cos := max(base.cos(climate_lat(h, k / w) * math.PI / 180), 0.02)
		r.flow[k] = f32(annual / 100 * cell_cos)
	}
	for s := len(popped) - 1; s >= 0; s -= 1 {
		k := popped[s]
		if !l.is_land[k] {continue}
		if nx := r.next[k]; nx >= 0 && l.is_land[nx] {r.flow[nx] += r.flow[k]}
	}
	return r
}

// river_width is how many blocks wide a river of this flow is: 0 below RIVER_FLOW,
// else 2 growing with the square root of the flow, to 24 at RIVER_FLOW_BIG.
river_width :: proc(flow: f32) -> f32 {
	if flow < RIVER_FLOW {return 0}
	share := math.sqrt(clamp(flow / RIVER_FLOW_BIG, 0, 1))
	return RIVER_WIDTH_MIN + (RIVER_WIDTH_MAX - RIVER_WIDTH_MIN) * share
}
