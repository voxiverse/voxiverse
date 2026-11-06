package game

import "base:intrinsics"
import "core:math"
import "core:slice"

// The spatial query service (docs/design.md, entities v2): a grid of
// chunk-sized cells holding entries (id, box, kind, flags), so "who is near"
// is a walk over a few cells and not over every entity. An entry sits in the
// cell of its box's bottom centre; insert, move and remove are O(1). Every
// query appends ids in ascending order, so no result depends on insertion
// order or on the map, which is only ever looked up (docs/determinism.md).

// SPATIAL_MAX_EXTENT: the largest side of a box that is not Large. Queries
// widen the cells they search by it.
SPATIAL_MAX_EXTENT :: 4

Spatial_Flag :: enum u8 {
	Hittable,
	Player,
	Item,
	Natural,
	Saved,
	Frozen,
	Large, // bigger than SPATIAL_MAX_EXTENT: on a list every query scans
}

Spatial_Flags :: bit_set[Spatial_Flag;u16]

Spatial_Entry :: struct {
	id:     Entity_Id,
	lo, hi: [3]f64,
	kind:   u16,
	flags:  Spatial_Flags,
}

Spatial_Filter :: struct {
	kind:    u16, // 0: any
	all:     Spatial_Flags, // every one of these
	none:    Spatial_Flags, // none of these
	exclude: Entity_Id, // 0: none
}

// Spatial_Handle names an entry for move and remove: its index + 1, 0 none.
Spatial_Handle :: distinct u32

@(private = "file")
Slot :: struct {
	entry:      Spatial_Entry,
	next, prev: u32, // + 1; 0 ends the list
	cell:       Chunk_Pos,
	pos:        u32, // in its cell's items
	large:      bool,
	used:       bool,
}

// Item mirrors what a Sphere or Cylinder query reads of an entry (its bottom
// centre, id, kind and flags), packed per cell: a walk over a cell's items
// reads memory in order, where the list chases a slot per entry.
@(private = "file")
Item :: struct {
	at:    [3]f64,
	id:    Entity_Id,
	slot:  u32,
	kind:  u16,
	flags: Spatial_Flags,
}

@(private = "file")
Cell :: struct {
	head:  u32, // head slot + 1
	items: [dynamic]Item,
}

Spatial :: struct {
	cells:            map[Chunk_Pos]Cell,
	slots:            [dynamic]Slot,
	free:             [dynamic]u32,
	large:            u32, // head of the Large list, + 1
	// The cells ever used, as a box (it only grows): queries do not look up
	// cells outside it, which costs a hash each.
	seen_lo, seen_hi: Chunk_Pos,
	seen:             bool,
	count:            int,
	scratch:          [dynamic]Entity_Id,
	sorted:           [dynamic]Entity_Id, // sort_ids' second buffer
	bits:             [dynamic]u64, // sort_ids' bitset, all zero between sorts
}

spatial_init :: proc(sp: ^Spatial, allocator := context.allocator) {
	sp.cells = make(map[Chunk_Pos]Cell, allocator)
	sp.slots = make([dynamic]Slot, allocator)
	sp.free = make([dynamic]u32, allocator)
	sp.scratch = make([dynamic]Entity_Id, allocator)
	sp.sorted = make([dynamic]Entity_Id, allocator)
	sp.bits = make([dynamic]u64, allocator)
}

spatial_destroy :: proc(sp: ^Spatial) {
	for _, &c in sp.cells {delete(c.items)}
	delete(sp.cells)
	delete(sp.slots)
	delete(sp.free)
	delete(sp.scratch)
	delete(sp.sorted)
	delete(sp.bits)
	sp^ = {}
}

spatial_count_entries :: proc(sp: ^Spatial) -> int {
	return sp.count
}

// spatial_committed_bytes: what the service holds; flat once its high-water
// mark is reached.
spatial_committed_bytes :: proc(sp: ^Spatial) -> int {
	return(
		cap(sp.slots) * size_of(Slot) +
		cap(sp.free) * size_of(u32) +
		cap(sp.cells) * (size_of(Chunk_Pos) + size_of(Cell)) \
	)
}

cell_of :: proc(lo, hi: [3]f64) -> Chunk_Pos {
	return {
		i32(math.floor((lo.x + hi.x) / 2 / CHUNK_SIZE)),
		i32(math.floor(lo.y / CHUNK_SIZE)),
		i32(math.floor((lo.z + hi.z) / 2 / CHUNK_SIZE)),
	}
}

@(private = "file")
too_large :: proc(lo, hi: [3]f64) -> bool {
	d := hi - lo
	return d.x > SPATIAL_MAX_EXTENT || d.y > SPATIAL_MAX_EXTENT || d.z > SPATIAL_MAX_EXTENT
}

@(private = "file")
link :: proc(sp: ^Spatial, i: u32) {
	s := &sp.slots[i]
	head: ^u32
	if s.large {
		head = &sp.large
	} else {
		if s.cell not_in sp.cells {sp.cells[s.cell] = {}}
		if sp.seen {
			sp.seen_lo = {
				min(sp.seen_lo.x, s.cell.x),
				min(sp.seen_lo.y, s.cell.y),
				min(sp.seen_lo.z, s.cell.z),
			}
			sp.seen_hi = {
				max(sp.seen_hi.x, s.cell.x),
				max(sp.seen_hi.y, s.cell.y),
				max(sp.seen_hi.z, s.cell.z),
			}
		} else {
			sp.seen_lo, sp.seen_hi, sp.seen = s.cell, s.cell, true
		}
		cell := &sp.cells[s.cell]
		s.pos = u32(len(cell.items))
		e := &s.entry
		append(
			&cell.items,
			Item{at = bottom_centre(e), id = e.id, slot = i, kind = e.kind, flags = e.flags},
		)
		head = &cell.head
	}
	s.prev, s.next = 0, head^
	if head^ != 0 {sp.slots[head^ - 1].prev = i + 1}
	head^ = i + 1
}

@(private = "file")
unlink :: proc(sp: ^Spatial, i: u32) {
	s := &sp.slots[i]
	empty := false
	if !s.large {
		cell := &sp.cells[s.cell]
		last := pop(&cell.items)
		if s.pos < u32(len(cell.items)) {
			cell.items[s.pos] = last
			sp.slots[last.slot].pos = s.pos
		}
		empty = len(cell.items) == 0
		if s.prev == 0 {cell.head = s.next}
	}
	if s.prev != 0 {
		sp.slots[s.prev - 1].next = s.next
	} else if s.large {
		sp.large = s.next
	}
	if s.next != 0 {sp.slots[s.next - 1].prev = s.prev}
	if empty {
		cell := &sp.cells[s.cell]
		delete(cell.items)
		delete_key(&sp.cells, s.cell)
	}
	s.next, s.prev = 0, 0
}

// spatial_insert adds an entry; a box over SPATIAL_MAX_EXTENT without Large
// is refused (false).
spatial_insert :: proc(sp: ^Spatial, e: Spatial_Entry) -> (Spatial_Handle, bool) {
	if .Large not_in e.flags && too_large(e.lo, e.hi) {return 0, false}
	i: u32
	if len(sp.free) > 0 {
		i = pop(&sp.free)
	} else {
		i = u32(len(sp.slots))
		append(&sp.slots, Slot{})
	}
	sp.slots[i] = {
		entry = e,
		cell  = cell_of(e.lo, e.hi),
		large = .Large in e.flags,
		used  = true,
	}
	link(sp, i)
	sp.count += 1
	return Spatial_Handle(i + 1), true
}

// spatial_move gives the entry a new box, re-bucketing only when its cell
// changes. A move that would make a non-Large box too large is refused.
spatial_move :: proc(sp: ^Spatial, h: Spatial_Handle, lo, hi: [3]f64) -> bool {
	i := u32(h) - 1
	s := &sp.slots[i]
	assert(s.used)
	if !s.large && too_large(lo, hi) {return false}
	cell := cell_of(lo, hi)
	s.entry.lo, s.entry.hi = lo, hi
	if !s.large && cell != s.cell {
		unlink(sp, i)
		s.cell = cell
		link(sp, i)
	} else if !s.large {
		sp.cells[s.cell].items[s.pos].at = bottom_centre(&s.entry)
	}
	return true
}

spatial_set_flags :: proc(sp: ^Spatial, h: Spatial_Handle, flags: Spatial_Flags) {
	s := &sp.slots[u32(h) - 1]
	assert(s.used && (.Large in flags) == s.large, "Large cannot change")
	s.entry.flags = flags
	if !s.large {sp.cells[s.cell].items[s.pos].flags = flags}
}

spatial_remove :: proc(sp: ^Spatial, h: Spatial_Handle) {
	i := u32(h) - 1
	assert(sp.slots[i].used)
	unlink(sp, i)
	sp.slots[i].used = false
	append(&sp.free, i)
	sp.count -= 1
}

spatial_get :: proc(sp: ^Spatial, h: Spatial_Handle) -> Spatial_Entry {
	return sp.slots[u32(h) - 1].entry
}

passes :: #force_inline proc(e: ^Spatial_Entry, f: Spatial_Filter) -> bool {
	return(
		(f.kind == 0 || e.kind == f.kind) &&
		f.all <= e.flags &&
		f.none & e.flags == {} &&
		(f.exclude == 0 || e.id != f.exclude) \
	)
}

bottom_centre :: #force_inline proc(e: ^Spatial_Entry) -> [3]f64 {
	return {(e.lo.x + e.hi.x) / 2, e.lo.y, (e.lo.z + e.hi.z) / 2}
}

// visit calls f for every used entry in the cells overlapping [lo, hi] (blocks)
// widened by margin blocks, and in the Large list.
@(private = "file")
visit :: proc(
	sp: ^Spatial,
	lo, hi: [3]f64,
	margin: f64,
	data: rawptr,
	f: proc(data: rawptr, e: ^Spatial_Entry),
) {
	cl, ch: Chunk_Pos
	for a in 0 ..< 3 {
		cl[a] = i32(math.floor((lo[a] - margin) / CHUNK_SIZE))
		ch[a] = i32(math.floor((hi[a] + margin) / CHUNK_SIZE))
	}
	for y in cl.y ..= ch.y {
		for z in cl.z ..= ch.z {
			for x in cl.x ..= ch.x {
				visit_cell(sp, {x, y, z}, data, f)
			}
		}
	}
	for i := sp.large; i != 0; i = sp.slots[i - 1].next {
		f(data, &sp.slots[i - 1].entry)
	}
}

@(private = "file")
visit_cell :: proc(
	sp: ^Spatial,
	c: Chunk_Pos,
	data: rawptr,
	f: proc(data: rawptr, e: ^Spatial_Entry),
) {
	head := (sp.cells[c].head if c in sp.cells else 0)
	for i := head; i != 0; i = sp.slots[i - 1].next {
		f(data, &sp.slots[i - 1].entry)
	}
}

@(private = "file")
Collect :: struct {
	sp:     ^Spatial,
	filter: Spatial_Filter,
	// shape
	shape:  enum {
		Sphere,
		Cylinder,
		Box,
	},
	center: [3]f64,
	radius: f64,
	half_h: f64,
	lo, hi: [3]f64,
}

@(private = "file")
matches :: #force_inline proc(c: ^Collect, e: ^Spatial_Entry) -> bool {
	if !passes(e, c.filter) {return false}
	switch c.shape {
	case .Sphere:
		d := bottom_centre(e) - c.center
		return d.x * d.x + d.y * d.y + d.z * d.z <= c.radius * c.radius
	case .Cylinder:
		d := bottom_centre(e) - c.center
		return d.x * d.x + d.z * d.z <= c.radius * c.radius && abs(d.y) <= c.half_h
	case .Box:
		return(
			e.lo.x < c.hi.x &&
			c.lo.x < e.hi.x &&
			e.lo.y < c.hi.y &&
			c.lo.y < e.hi.y &&
			e.lo.z < c.hi.z &&
			c.lo.z < e.hi.z \
		)
	}
	return false
}

@(private = "file")
collect_into :: proc(data: rawptr, e: ^Spatial_Entry) {
	c := (^Collect)(data)
	if matches(c, e) {append(&c.sp.scratch, e.id)}
}

// SORT_BITSET_IDS: ids below this are sorted through a bitset.
@(private = "file")
SORT_BITSET_IDS :: 1 << 16

// sort_ids puts the scratch ids in ascending order: insertion for a few,
// else a least-significant-byte radix sort (generic sorts cost most of a
// query that finds a hundred entries).
@(private = "file")
sort_ids :: proc(sp: ^Spatial) {
	a := sp.scratch[:]
	if len(a) <= 24 {
		for i in 1 ..< len(a) {
			v := a[i]
			j := i
			for j > 0 && a[j - 1] > v {a[j] = a[j - 1]; j -= 1}
			a[j] = v
		}
		return
	}
	top: u32
	for v in a {top |= u32(v)}
	if top < SORT_BITSET_IDS {
		// small ids: mark them in a bitset and read it back in order
		words := int(top >> 6) + 1
		if len(sp.bits) < words {resize(&sp.bits, words)}
		for v in a {sp.bits[u32(v) >> 6] |= 1 << (u32(v) & 63)}
		n := 0
		for w in 0 ..< words {
			b := sp.bits[w]
			sp.bits[w] = 0
			for b != 0 {
				a[n] = Entity_Id(u32(w) << 6 | u32(intrinsics.count_trailing_zeros(b)))
				n += 1
				b &= b - 1
			}
		}
		return
	}
	resize(&sp.sorted, len(a))
	from, to := a, sp.sorted[:]
	for shift: uint = 0; shift < 32 && (top >> shift) != 0; shift += 8 {
		counts: [257]int
		for v in from {counts[int((u32(v) >> shift) & 0xff) + 1] += 1}
		if counts[int((u32(from[0]) >> shift) & 0xff) + 1] == len(from) {continue} 	// (one bucket: this byte is the same)
		for i in 1 ..< 257 {counts[i] += counts[i - 1]}
		for v in from {
			k := int((u32(v) >> shift) & 0xff)
			to[counts[k]] = v
			counts[k] += 1
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(a) {copy(a, from)}
}

// cell_reachable: false when no point of the cell (where an entry's bottom
// centre lies) can be inside a Sphere or Cylinder query, so its lookup and
// walk are skipped; the corner cells of a query box are mostly such.
@(private = "file")
cell_reachable :: #force_inline proc(c: ^Collect, cell: Chunk_Pos) -> bool {
	if c.shape == .Box {return true}
	d: [3]f64
	for a in 0 ..< 3 {
		lo := f64(cell[a]) * CHUNK_SIZE
		d[a] = max(lo - c.center[a], 0, c.center[a] - (lo + CHUNK_SIZE))
	}
	if c.shape == .Cylinder {
		return d.x * d.x + d.z * d.z <= c.radius * c.radius && d.y <= c.half_h
	}
	return d.x * d.x + d.y * d.y + d.z * d.z <= c.radius * c.radius
}

@(private = "file")
run :: proc(c: ^Collect, margin: f64, lo, hi: [3]f64, out: ^[dynamic]Entity_Id) {
	clear(&c.sp.scratch)
	sp := c.sp
	cl, ch: Chunk_Pos
	for a in 0 ..< 3 {
		cl[a] = i32(math.floor((lo[a] - margin) / CHUNK_SIZE))
		ch[a] = i32(math.floor((hi[a] + margin) / CHUNK_SIZE))
	}
	if sp.seen {
		cl = {max(cl.x, sp.seen_lo.x), max(cl.y, sp.seen_lo.y), max(cl.z, sp.seen_lo.z)}
		ch = {min(ch.x, sp.seen_hi.x), min(ch.y, sp.seen_hi.y), min(ch.z, sp.seen_hi.z)}
	}
	// (the cells are walked here, not through visit's callback: a call per entry
	// is most of what a query costs)
	// (a sphere's and cylinder's test reads the cell's packed items instead:
	// the distance first, since the filter rarely rejects what is near)
	sphere := c.shape == .Sphere
	cylinder := c.shape == .Cylinder
	r2 := c.radius * c.radius
	for y in cl.y ..= ch.y {
		for z in cl.z ..= ch.z {
			for x in cl.x ..= ch.x {
				if !cell_reachable(c, {x, y, z}) {continue}
				if sphere || cylinder {
					cell, ok := &sp.cells[{x, y, z}]
					if !ok {continue}
					for &it in cell.items {
						dx := it.at.x - c.center.x
						dy := it.at.y - c.center.y
						dz := it.at.z - c.center.z
						near :=
							dx * dx + dy * dy + dz * dz <= r2 if sphere else dx * dx + dz * dz <= r2 && abs(dy) <= c.half_h
						if near &&
						   (c.filter.kind == 0 || it.kind == c.filter.kind) &&
						   c.filter.all <= it.flags &&
						   c.filter.none & it.flags == {} &&
						   (c.filter.exclude == 0 || it.id != c.filter.exclude) {
							append(&sp.scratch, it.id)
						}
					}
					continue
				}
				for i := (sp.cells[{x, y, z}].head if {x, y, z} in sp.cells else 0);
				    i != 0;
				    i = sp.slots[i - 1].next {
					if matches(
						c,
						&sp.slots[i - 1].entry,
					) {append(&sp.scratch, sp.slots[i - 1].entry.id)}
				}
			}
		}
	}
	for i := sp.large; i != 0; i = sp.slots[i - 1].next {
		collect_into(c, &sp.slots[i - 1].entry)
	}
	sort_ids(c.sp)
	append(out, ..c.sp.scratch[:])
}

// spatial_sphere: entries whose bottom centre is within radius of center.
spatial_sphere :: proc(
	sp: ^Spatial,
	center: [3]f64,
	radius: f64,
	filter: Spatial_Filter,
	out: ^[dynamic]Entity_Id,
) {
	c := Collect {
		sp     = sp,
		filter = filter,
		shape  = .Sphere,
		center = center,
		radius = radius,
	}
	run(&c, 0, center - radius, center + radius, out)
}

// spatial_cylinder: horizontal distance within radius, vertical within
// half_height (the spawn cap's and ENTITY_VIEW's shape).
spatial_cylinder :: proc(
	sp: ^Spatial,
	center: [3]f64,
	radius, half_height: f64,
	filter: Spatial_Filter,
	out: ^[dynamic]Entity_Id,
) {
	c := Collect {
		sp     = sp,
		filter = filter,
		shape  = .Cylinder,
		center = center,
		radius = radius,
		half_h = half_height,
	}
	run(&c, 0, center - {radius, half_height, radius}, center + {radius, half_height, radius}, out)
}

// spatial_box: entries whose boxes overlap [lo, hi].
spatial_box :: proc(
	sp: ^Spatial,
	lo, hi: [3]f64,
	filter: Spatial_Filter,
	out: ^[dynamic]Entity_Id,
) {
	c := Collect {
		sp     = sp,
		filter = filter,
		shape  = .Box,
		lo     = lo,
		hi     = hi,
	}
	run(&c, SPATIAL_MAX_EXTENT, lo, hi, out)
}

@(private = "file")
Nearest :: struct {
	using c: Collect,
	best:    Entity_Id,
	dist:    f64,
	found:   bool,
}

@(private = "file")
nearest_visit :: proc(data: rawptr, e: ^Spatial_Entry) {
	n := (^Nearest)(data)
	if !matches(&n.c, e) {return}
	d := bottom_centre(e) - n.center
	d2 := d.x * d.x + d.y * d.y + d.z * d.z
	if !n.found || d2 < n.dist || (d2 == n.dist && e.id < n.best) {
		n.best, n.dist, n.found = e.id, d2, true
	}
}

// spatial_nearest: the entry whose bottom centre is nearest center within
// radius (the lowest id on a tie), and its distance.
spatial_nearest :: proc(
	sp: ^Spatial,
	center: [3]f64,
	radius: f64,
	filter: Spatial_Filter,
) -> (
	Entity_Id,
	f64,
	bool,
) {
	n := Nearest {
		c = {sp = sp, filter = filter, shape = .Sphere, center = center, radius = radius},
	}
	visit(sp, center - radius, center + radius, 0, &n, nearest_visit)
	return n.best, math.sqrt(n.dist), n.found
}

@(private = "file")
count_visit :: proc(data: rawptr, e: ^Spatial_Entry) {
	c := (^Collect)(data)
	if matches(c, e) {append(&c.sp.scratch, 0)}
}

spatial_count :: proc(sp: ^Spatial, center: [3]f64, radius: f64, filter: Spatial_Filter) -> int {
	c := Collect {
		sp     = sp,
		filter = filter,
		shape  = .Sphere,
		center = center,
		radius = radius,
	}
	clear(&sp.scratch)
	visit(sp, center - radius, center + radius, 0, &c, count_visit)
	return len(sp.scratch)
}

@(private = "file")
Cast :: struct {
	sp:     ^Spatial,
	filter: Spatial_Filter,
	origin: [3]f64,
	dir:    [3]f64,
	max:    f64,
	half:   f64,
	best:   Entity_Id,
	dist:   f64,
	found:  bool,
}

@(private = "file")
cast_entry :: proc(k: ^Cast, e: ^Spatial_Entry) {
	if !passes(e, k.filter) {return}
	h := [3]f64{k.half, k.half, k.half}
	d, hit := ray_box(k.origin, k.dir, e.lo - h, e.hi + h, k.max)
	if !hit {return}
	if !k.found || d < k.dist || (d == k.dist && e.id < k.best) {
		k.best, k.dist, k.found = e.id, d, true
	}
}

@(private = "file")
cast_visit :: proc(data: rawptr, e: ^Spatial_Entry) {
	cast_entry((^Cast)(data), e)
}

// spatial_cast: the nearest entry box that a ray from origin along dir
// (unit), or a box of half size half moving along it, enters within max, and
// the distance. A 3D DDA over the cells along the ray; each cell's
// neighbours within the box extent are searched too.
spatial_cast :: proc(
	sp: ^Spatial,
	origin, dir: [3]f64,
	max, half: f64,
	filter: Spatial_Filter,
) -> (
	Entity_Id,
	f64,
	bool,
) {
	k := Cast {
		sp     = sp,
		filter = filter,
		origin = origin,
		dir    = dir,
		max    = max,
		half   = half,
	}
	// The cells an entry can be bucketed in and still be hit: within
	// SPATIAL_MAX_EXTENT + half blocks of the ray; that is one cell more
	// on every side of the cells the ray passes through.
	cell: [3]i32
	step: [3]i32
	t_max, t_delta: [3]f64
	for a in 0 ..< 3 {
		cell[a] = i32(math.floor(origin[a] / CHUNK_SIZE))
		switch {
		case dir[a] > 0:
			step[a] = 1
			t_max[a] = (f64(cell[a] + 1) * CHUNK_SIZE - origin[a]) / dir[a]
			t_delta[a] = CHUNK_SIZE / dir[a]
		case dir[a] < 0:
			step[a] = -1
			t_max[a] = (f64(cell[a]) * CHUNK_SIZE - origin[a]) / dir[a]
			t_delta[a] = -CHUNK_SIZE / dir[a]
		case:
			t_max[a] = math.inf_f64(1)
			t_delta[a] = math.inf_f64(1)
		}
	}
	reach := i32(math.ceil((SPATIAL_MAX_EXTENT + half) / CHUNK_SIZE))
	for {
		for y in cell.y - reach ..= cell.y + reach {
			for z in cell.z - reach ..= cell.z + reach {
				for x in cell.x - reach ..= cell.x + reach {
					head := (sp.cells[{x, y, z}].head if {x, y, z} in sp.cells else 0)
					for i := head; i != 0; i = sp.slots[i - 1].next {
						cast_entry(&k, &sp.slots[i - 1].entry)
					}
				}
			}
		}
		a := 0
		if t_max.y < t_max[a] {a = 1}
		if t_max.z < t_max[a] {a = 2}
		if t_max[a] > max {break}
		cell[a] += step[a]
		t_max[a] += t_delta[a]
	}
	for i := sp.large; i != 0; i = sp.slots[i - 1].next {
		cast_entry(&k, &sp.slots[i - 1].entry)
	}
	return k.best, k.dist, k.found
}

// spatial_chunk appends the ids bucketed in chunk pos, ascending.
spatial_chunk :: proc(sp: ^Spatial, pos: Chunk_Pos, out: ^[dynamic]Entity_Id) {
	start := len(out)
	head := (sp.cells[pos].head if pos in sp.cells else 0)
	for i := head; i != 0; i = sp.slots[i - 1].next {
		append(out, sp.slots[i - 1].entry.id)
	}
	slice.sort(out[start:])
}

// cells_find appends to out, in (y, z, x) order, every loaded block position
// in lo ..< hi whose block m has. It returns how many it appended, or -1
// (appending nothing) when the box holds more than max_volume cells.
cells_find :: proc(
	q: Block_Query,
	lo, hi: Block_Pos,
	m: ^Matcher,
	out: ^[dynamic]Block_Pos,
	max_volume := 32_768,
) -> int {
	if hi.x <= lo.x || hi.y <= lo.y || hi.z <= lo.z {return 0}
	volume := int(hi.x - lo.x) * int(hi.y - lo.y) * int(hi.z - lo.z)
	if volume > max_volume {return -1}
	n := 0
	for y in lo.y ..< hi.y {
		for z in lo.z ..< hi.z {
			for x in lo.x ..< hi.x {
				b, loaded := q.get(q.data, {x, y, z})
				if loaded && rule_matcher_has(m, b) {
					append(out, Block_Pos{x, y, z})
					n += 1
				}
			}
		}
	}
	return n
}

// cells_nearest: the matching loaded cell whose centre is nearest to center,
// within radius; ties go to the first in (y, z, x) order. ok is false when
// there is none (or the radius needs more cells than cells_find allows).
cells_nearest :: proc(
	q: Block_Query,
	center: [3]f64,
	radius: f64,
	m: ^Matcher,
) -> (
	pos: Block_Pos,
	ok: bool,
) {
	lo := Block_Pos {
		i32(math.floor(center.x - radius)),
		i32(math.floor(center.y - radius)),
		i32(math.floor(center.z - radius)),
	}
	hi := Block_Pos {
		i32(math.floor(center.x + radius)) + 1,
		i32(math.floor(center.y + radius)) + 1,
		i32(math.floor(center.z + radius)) + 1,
	}
	found := make([dynamic]Block_Pos, 0, 0, context.temp_allocator)
	if cells_find(q, lo, hi, m, &found) < 0 {return}
	best := radius * radius
	for p in found {
		d := [3]f64{f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5} - center
		d2 := d.x * d.x + d.y * d.y + d.z * d.z
		if d2 <= best && (!ok || d2 < best) {best, pos, ok = d2, p, true}
	}
	return
}
