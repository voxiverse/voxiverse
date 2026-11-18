package voxel

import "core:math/bits"

// Reachability and distance: a set spreading through a domain, each step to the cells one
// offset of element away. A flood fill is the spread run until it stops (`fill`), the
// connected parts of a set are what it reaches from each cell not yet reached
// (`components`), and the number of steps it takes to reach a cell is that cell's distance
// (`distance`, `nearest`). The element's offsets (the origin aside) are the moves: the 6
// neighbours, the 4 of the plane, a fall and the 4 sides, any mask of offsets.
//
// The work is a row at a time: a row that grew is queued, and taking it spreads it along
// x within the row and then to the rows its offsets reach. The budget counts cells: each
// row taken costs its length.

// fill: reached (the seed) becomes the cells of domain the seed reaches: the least set
// that holds the seed's cells in domain and every cell of domain one offset of element
// from a cell it holds. reached and domain share their bounds. Exhausted (the budget
// spent first): reached holds part of that set, the seed's cells among it, and nothing
// outside it.
fill :: proc(
	reached: ^Mask,
	domain: Mask,
	element: Mask,
	budget: int,
	allocator := context.allocator,
) -> (
	exhausted: bool,
) {
	assert(reached.bounds == domain.bounds, "voxel: fill of masks with different bounds")
	intersect(reached, domain)
	s := spread_make(domain.bounds, element, allocator)
	defer spread_destroy(&s, allocator)
	for row in 0 ..< rows_of(domain) {
		for w in row_words(reached^, row) {if w != 0 {spread_push(&s, row); break}}
	}
	left := budget
	return !spread_close(reached, domain, &s, &left)
}

// components: labels gets each cell of m the number of its connected part, 1, 2 ... in the
// order of the parts' first cells (by y, then z, then x), and 0 to every cell not in m;
// count is the number of parts. Two cells are connected when a chain of cells of m, each
// one offset of element from the last, joins them; element is symmetric (with each offset
// its opposite). labels and m share their bounds. Exhausted: the parts numbered so far are
// whole and every other cell is 0.
components :: proc(
	labels: ^Field,
	m: Mask,
	element: Mask,
	budget: int,
	allocator := context.allocator,
) -> (
	count: int,
	exhausted: bool,
) {
	assert(labels.bounds == m.bounds, "voxel: components into a field of other bounds")
	for &v in labels.values {v = 0}
	s := spread_make(m.bounds, element, allocator)
	defer spread_destroy(&s, allocator)
	for o in s.offsets {
		assert(mask_get(element, -o), "voxel: components under an element that is not symmetric")
	}
	remaining := mask_make(m.bounds, allocator)
	defer mask_destroy(&remaining, allocator)
	mask_copy(&remaining, m)
	reached := mask_make(m.bounds, allocator)
	defer mask_destroy(&reached, allocator)
	left := budget
	for row in 0 ..< rows_of(m) {
		for i in 0 ..< m.stride {
			for remaining.words[row * m.stride + i] != 0 {
				w := remaining.words[row * m.stride + i]
				reached.words[row * m.stride + i] = w & (~w + 1) // (the part's first cell)
				spread_push(&s, row)
				if !spread_close(&reached, remaining, &s, &left) {
					return count, true
				}
				count += 1
				for t in s.touched {
					write_row(labels, reached, int(t), i32(count))
					for &r, j in row_words(reached, int(t)) {
						remaining.words[int(t) * m.stride + j] &~= r
						r = 0
					}
					flag_off(s.seen, int(t))
				}
				clear(&s.touched)
			}
		}
	}
	return
}

// distance: out gets each cell of domain the fewest steps (one offset of element each,
// through cells of domain) from a cell of sources, 0 on the sources' cells in domain, and
// UNREACHED for a cell further than max_steps or out of reach. out and domain share their
// bounds. Exhausted: every cell within the last step completed has its distance and every
// other cell is UNREACHED.
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
	l := layers_make(sources, domain, element, allocator)
	defer layers_destroy(&l, allocator)
	for row in l.frontier_rows {write_row(out, l.frontier, int(row), 0)}
	left := budget
	for step in 1 ..= max_steps {
		if len(l.frontier_rows) == 0 {break}
		if !layers_step(&l, domain, &left) {return true}
		for row in l.next_rows {write_row(out, l.next, int(row), i32(step))}
		layers_advance(&l)
	}
	return false
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
	start := mask_make({from, from + 1}, allocator)
	defer mask_destroy(&start, allocator)
	mask_set(&start, from)
	l := layers_make(start, domain, element, allocator)
	defer layers_destroy(&l, allocator)
	left := budget
	for step in 0 ..= max_steps {
		if len(l.frontier_rows) == 0 {break}
		if step > 0 {
			if !layers_step(&l, domain, &left) {return {}, 0, false, true}
			layers_advance(&l)
		}
		best := max(int)
		for row in l.frontier_rows {
			if int(row) >= best {continue}
			for w, i in row_words(l.frontier, int(row)) {
				if w & targets.words[int(row) * targets.stride + i] != 0 {best = int(row); break}
			}
		}
		if best == max(int) {continue}
		for w, i in row_words(l.frontier, best) {
			hit := w & targets.words[best * targets.stride + i]
			if hit == 0 {continue}
			sz := int(domain.bounds.hi.z - domain.bounds.lo.z)
			x := i32(i * 64) + i32(bits.count_trailing_zeros(hit))
			return domain.bounds.lo + {x, i32(best / sz), i32(best % sz)}, step, true, false
		}
	}
	return
}

// descend: a step from at back toward the field's zeros: the first cell (in the element's
// order: y, then z, then x) from which one move of element reaches at, whose value is one
// less. ok false at a zero or a cell not reached. From a cell of a distance field,
// descending until it fails walks one of the shortest ways back to the sources, in
// reverse.
descend :: proc(f: Field, at: Cell, element: Mask) -> (next: Cell, ok: bool) {
	v := field_get(f, at)
	if v <= 0 {return}
	cursor := 0
	for lo, n in runs_next(element, &cursor) {
		for k in 0 ..< n {
			c := at - (lo + {k, 0, 0})
			if field_get(f, c) == v - 1 {return c, true}
		}
	}
	return
}

// Spread: what a spread keeps besides its masks: the element as offsets, the queue of rows
// to take (a ring, each row in it at most once) and the rows it touched.
@(private)
Spread :: struct {
	offsets:  [dynamic]Cell, // the element's offsets, the origin aside
	up, down: bool, // {1, 0, 0} and {-1, 0, 0} among them
	queue:    []i32,
	head:     int,
	waiting:  int,
	queued:   []u64, // a bit for each row: in the queue
	seen:     []u64, // a bit for each row: in touched
	touched:  [dynamic]i32, // the rows pushed since touched was last emptied
}

@(private)
spread_make :: proc(b: Bounds, element: Mask, allocator := context.allocator) -> Spread {
	s := bounds_size(b)
	rows := int(s.y) * int(s.z)
	sp := Spread {
		offsets = make([dynamic]Cell, allocator),
		queue   = make([]i32, max(rows, 1), allocator),
		queued  = make([]u64, (rows + 63) / 64, allocator),
		seen    = make([]u64, (rows + 63) / 64, allocator),
		touched = make([dynamic]i32, allocator),
	}
	cursor := 0
	for lo, n in runs_next(element, &cursor) {
		for k in 0 ..< n {
			o := lo + {k, 0, 0}
			switch o {
			case {}:
				continue
			case {1, 0, 0}:
				sp.up = true
			case {-1, 0, 0}:
				sp.down = true
			}
			append(&sp.offsets, o)
		}
	}
	return sp
}

@(private)
spread_destroy :: proc(s: ^Spread, allocator := context.allocator) {
	delete(s.offsets)
	delete(s.queue, allocator)
	delete(s.queued, allocator)
	delete(s.seen, allocator)
	delete(s.touched)
}

@(private)
spread_push :: proc(s: ^Spread, row: int) {
	if flag_get(s.queued, row) {return}
	flag_on(s.queued, row)
	s.queue[(s.head + s.waiting) % len(s.queue)] = i32(row)
	s.waiting += 1
	if !flag_get(s.seen, row) {
		flag_on(s.seen, row)
		append(&s.touched, i32(row))
	}
}

// spread_close: takes queued rows until none is left (true) or the budget is spent (false),
// spreading reached through domain.
@(private)
spread_close :: proc(reached: ^Mask, domain: Mask, s: ^Spread, left: ^int) -> bool {
	sz := int(domain.bounds.hi.z - domain.bounds.lo.z)
	cost := max(int(domain.bounds.hi.x - domain.bounds.lo.x), 1)
	buf: [MAX_STRIDE]u64
	moved := buf[:domain.stride]
	for s.waiting > 0 {
		if left^ < cost {return false}
		left^ -= cost
		row := int(s.queue[s.head])
		s.head = (s.head + 1) % len(s.queue)
		s.waiting -= 1
		flag_off(s.queued, row)
		words := row_words(reached^, row)
		spread_row(words, row_words(domain, row), s)
		y, z := domain.bounds.lo.y + i32(row / sz), domain.bounds.lo.z + i32(row % sz)
		for o in s.offsets {
			if o.y == 0 && o.z == 0 {continue}
			t := row_at(domain, y + o.y, z + o.z) or_continue
			bits_at(words, -int(o.x), moved)
			if grow(row_words(reached^, t), row_words(domain, t), moved) {spread_push(s, t)}
		}
	}
	return true
}

// spread_row: words (a row of the spread) becomes what it reaches within its row through
// dom by the element's moves along x.
@(private)
spread_row :: proc(words, dom: []u64, s: ^Spread) {
	buf: [MAX_STRIDE]u64
	moved := buf[:len(words)]
	for {
		changed := false
		if s.up && spread_up(words, dom) {changed = true}
		if s.down && spread_down(words, dom) {changed = true}
		along := false
		for o in s.offsets {
			if o.y != 0 || o.z != 0 || abs(o.x) == 1 {continue}
			along = true
			bits_at(words, -int(o.x), moved)
			if grow(words, dom, moved) {changed = true}
		}
		if !along || !changed {return}
	}
}

// spread_up: each run of dom's bits holding a bit of words fills from that bit toward
// higher x: a word at a time, the carry crossing from word to word, and within a word by
// doubling (the bits reached 1, 2, 4 ... 32 cells on).
@(private)
spread_up :: proc(words, dom: []u64) -> (changed: bool) {
	carry := u64(0)
	for i in 0 ..< len(words) {
		p := dom[i]
		g := words[i] | (carry & p & 1)
		g |= p & (g << 1)
		q := p & (p << 1)
		g |= q & (g << 2)
		q &= q << 2
		g |= q & (g << 4)
		q &= q << 4
		g |= q & (g << 8)
		q &= q << 8
		g |= q & (g << 16)
		q &= q << 16
		g |= q & (g << 32)
		if g != words[i] {changed = true}
		words[i] = g
		carry = g >> 63
	}
	return
}

// spread_down: spread_up toward lower x.
@(private)
spread_down :: proc(words, dom: []u64) -> (changed: bool) {
	carry := u64(0)
	for i := len(words) - 1; i >= 0; i -= 1 {
		p := dom[i]
		g := words[i] | (carry & p & (1 << 63))
		g |= p & (g >> 1)
		q := p & (p >> 1)
		g |= q & (g >> 2)
		q &= q >> 2
		g |= q & (g >> 4)
		q &= q >> 4
		g |= q & (g >> 8)
		q &= q >> 8
		g |= q & (g >> 16)
		q &= q >> 16
		g |= q & (g >> 32)
		if g != words[i] {changed = true}
		words[i] = g
		carry = g << 63
	}
	return
}

// grow: words gains the bits of moved that dom allows; whether it gained any.
@(private)
grow :: #force_inline proc(words, dom, moved: []u64) -> (grew: bool) {
	for &w, i in words {
		n := moved[i] & dom[i] &~ w
		if n != 0 {
			w |= n
			grew = true
		}
	}
	return
}

// Layers: a breadth-first spread a step at a time: the cells reached, the last step's
// (frontier) and the next's, and the rows each of those two holds.
@(private)
Layers :: struct {
	spread:                   Spread, // (its offsets; queued marks the rows of next_rows)
	visited, frontier, next:  Mask,
	frontier_rows, next_rows: [dynamic]i32,
}

@(private)
layers_make :: proc(sources, domain, element: Mask, allocator := context.allocator) -> Layers {
	l := Layers {
		spread        = spread_make(domain.bounds, element, allocator),
		visited       = mask_make(domain.bounds, allocator),
		frontier      = mask_make(domain.bounds, allocator),
		next          = mask_make(domain.bounds, allocator),
		frontier_rows = make([dynamic]i32, allocator),
		next_rows     = make([dynamic]i32, allocator),
	}
	unite(&l.visited, sources)
	intersect(&l.visited, domain)
	mask_copy(&l.frontier, l.visited)
	for row in 0 ..< rows_of(domain) {
		for w in row_words(l.frontier, row) {if w != 0 {append(&l.frontier_rows, i32(row)); break}}
	}
	return l
}

@(private)
layers_destroy :: proc(l: ^Layers, allocator := context.allocator) {
	spread_destroy(&l.spread, allocator)
	mask_destroy(&l.visited, allocator)
	mask_destroy(&l.frontier, allocator)
	mask_destroy(&l.next, allocator)
	delete(l.frontier_rows)
	delete(l.next_rows)
}

// layers_step: next becomes the cells of domain one move from the frontier and not yet
// visited. False when the budget ran out first: next is left empty.
@(private)
layers_step :: proc(l: ^Layers, domain: Mask, left: ^int) -> bool {
	sz := int(domain.bounds.hi.z - domain.bounds.lo.z)
	cost := max(int(domain.bounds.hi.x - domain.bounds.lo.x), 1)
	buf: [MAX_STRIDE]u64
	moved := buf[:domain.stride]
	for row in l.frontier_rows {
		if left^ < cost {
			for t in l.next_rows {
				for &w in row_words(l.next, int(t)) {w = 0}
				flag_off(l.spread.queued, int(t))
			}
			clear(&l.next_rows)
			return false
		}
		left^ -= cost
		words := row_words(l.frontier, int(row))
		y, z := domain.bounds.lo.y + i32(int(row) / sz), domain.bounds.lo.z + i32(int(row) % sz)
		for o in l.spread.offsets {
			t := row_at(domain, y + o.y, z + o.z) or_continue
			bits_at(words, -int(o.x), moved)
			for &m, i in moved {m &~= l.visited.words[t * domain.stride + i]}
			if grow(row_words(l.next, t), row_words(domain, t), moved) &&
			   !flag_get(l.spread.queued, t) {
				flag_on(l.spread.queued, t)
				append(&l.next_rows, i32(t))
			}
		}
	}
	return true
}

// layers_advance: next is visited and becomes the frontier.
@(private)
layers_advance :: proc(l: ^Layers) {
	for t in l.next_rows {
		for w, i in row_words(l.next, int(t)) {l.visited.words[int(t) * l.visited.stride + i] |= w}
		flag_off(l.spread.queued, int(t))
	}
	for row in l.frontier_rows {
		for &w in row_words(l.frontier, int(row)) {w = 0}
	}
	l.frontier, l.next = l.next, l.frontier
	l.frontier_rows, l.next_rows = l.next_rows, l.frontier_rows
	clear(&l.next_rows)
}

// write_row: the field's cells of row that m holds get value.
@(private)
write_row :: proc(f: ^Field, m: Mask, row: int, value: i32) {
	base := row * int(f.bounds.hi.x - f.bounds.lo.x)
	for w, i in row_words(m, row) {
		for rest := w; rest != 0; rest &= rest - 1 {
			f.values[base + i * 64 + int(bits.count_trailing_zeros(rest))] = value
		}
	}
}

@(private)
rows_of :: #force_inline proc(m: Mask) -> int {
	s := bounds_size(m.bounds)
	return int(s.y) * int(s.z)
}

@(private)
flag_get :: #force_inline proc(set: []u64, i: int) -> bool {return(
		set[i >> 6] & (1 << uint(i & 63)) !=
		0 \
	)}

@(private)
flag_on :: #force_inline proc(set: []u64, i: int) {set[i >> 6] |= 1 << uint(i & 63)}

@(private)
flag_off :: #force_inline proc(set: []u64, i: int) {set[i >> 6] &~= 1 << uint(i & 63)}
