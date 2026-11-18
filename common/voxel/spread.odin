package voxel

import "core:math/bits"

// Reachability: a set spreading through a domain, each step to the cells one offset of
// element away. A flood fill is the spread run until it stops (`fill`), and the connected
// parts of a set are what it reaches from each cell not yet reached (`components`); what
// each step costs is cost.odin. The element's offsets (the origin aside) are the moves:
// the 6 neighbours, the 4 of the plane, a fall and the 4 sides, any mask of offsets.
//
// The work is a row at a time: a row that grew is queued, and taking it spreads it along
// x within the row and then to the rows its offsets reach. The budget counts cells: each
// row taken costs its length, taken from the budget the caller gives (what is left stays
// there, for the next spread to share).

// fill: reached (the seed) becomes the cells of domain the seed reaches: the least set
// that holds the seed's cells in domain and every cell of domain one offset of element
// from a cell it holds; added is how many cells joined (0: nothing changed). reached and
// domain share their bounds. Exhausted (the budget spent first): reached holds part of
// that set, the seed's cells among it, and nothing outside it.
fill :: proc(
	reached: ^Mask,
	domain: Mask,
	element: Mask,
	budget: ^int,
	allocator := context.allocator,
) -> (
	added: int,
	exhausted: bool,
) {
	assert(reached.bounds == domain.bounds, "voxel: fill of masks with different bounds")
	intersect(reached, domain)
	s := spread_make(domain.bounds, element, allocator)
	defer spread_destroy(&s, allocator)
	for row in 0 ..< rows_of(domain) {
		for w in row_words(reached^, row) {if w != 0 {spread_push(&s, row); break}}
	}
	done: bool
	added, done = spread_close(reached, domain, &s, budget)
	return added, !done
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
	budget: ^int,
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
	for row in 0 ..< rows_of(m) {
		for i in 0 ..< m.stride {
			for remaining.words[row * m.stride + i] != 0 {
				w := remaining.words[row * m.stride + i]
				reached.words[row * m.stride + i] = w & (~w + 1) // (the part's first cell)
				spread_push(&s, row)
				if _, done := spread_close(&reached, remaining, &s, budget); !done {
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

// spread_close: takes queued rows until none is left (done) or the budget is spent,
// spreading reached through domain; added is how many cells joined.
@(private)
spread_close :: proc(
	reached: ^Mask,
	domain: Mask,
	s: ^Spread,
	left: ^int,
) -> (
	added: int,
	done: bool,
) {
	sz := int(domain.bounds.hi.z - domain.bounds.lo.z)
	cost := max(int(domain.bounds.hi.x - domain.bounds.lo.x), 1)
	buf: [MAX_STRIDE]u64
	moved := buf[:domain.stride]
	for s.waiting > 0 {
		if left^ < cost {return}
		left^ -= cost
		row := int(s.queue[s.head])
		s.head = (s.head + 1) % len(s.queue)
		s.waiting -= 1
		flag_off(s.queued, row)
		words := row_words(reached^, row)
		added += spread_row(words, row_words(domain, row), s)
		y, z := domain.bounds.lo.y + i32(row / sz), domain.bounds.lo.z + i32(row % sz)
		for o in s.offsets {
			if o.y == 0 && o.z == 0 {continue}
			t := row_at(domain, y + o.y, z + o.z) or_continue
			bits_at(words, -int(o.x), moved)
			if n := grow(row_words(reached^, t), row_words(domain, t), moved); n > 0 {
				added += n
				spread_push(s, t)
			}
		}
	}
	return added, true
}

// spread_row: words (a row of the spread) becomes what it reaches within its row through
// dom by the element's moves along x; added is how many cells joined.
@(private)
spread_row :: proc(words, dom: []u64, s: ^Spread) -> (added: int) {
	buf: [MAX_STRIDE]u64
	moved := buf[:len(words)]
	for {
		n := 0
		if s.up {n += spread_up(words, dom)}
		if s.down {n += spread_down(words, dom)}
		along := false
		for o in s.offsets {
			if o.y != 0 || o.z != 0 || abs(o.x) == 1 {continue}
			along = true
			bits_at(words, -int(o.x), moved)
			n += grow(words, dom, moved)
		}
		added += n
		if !along || n == 0 {return}
	}
}

// spread_up: each run of dom's bits holding a bit of words fills from that bit toward
// higher x: a word at a time, the carry crossing from word to word, and within a word by
// doubling (the bits reached 1, 2, 4 ... 32 cells on).
@(private)
spread_up :: proc(words, dom: []u64) -> (added: int) {
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
		added += int(bits.count_ones(g &~ words[i]))
		words[i] = g
		carry = g >> 63
	}
	return
}

// spread_down: spread_up toward lower x.
@(private)
spread_down :: proc(words, dom: []u64) -> (added: int) {
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
		added += int(bits.count_ones(g &~ words[i]))
		words[i] = g
		carry = g << 63
	}
	return
}

// grow: words gains the bits of moved that dom allows; how many it gained.
@(private)
grow :: #force_inline proc(words, dom, moved: []u64) -> (added: int) {
	for &w, i in words {
		n := moved[i] & dom[i] &~ w
		if n != 0 {
			w |= n
			added += int(bits.count_ones(n))
		}
	}
	return
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
