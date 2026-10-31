package base


import "core:slice"

// Range_Allocator divides a fixed space of capacity units (e.g. vertices in
// one big GPU buffer) into ranges: first fit over a free list sorted by
// offset, merging neighbours on free so space doesn't fragment into slivers.
// It only does bookkeeping; the space itself lives elsewhere.

Range :: struct {
	offset, size: u32,
}

Range_Allocator :: struct {
	free:     [dynamic]Range, // sorted by offset, never adjacent
	capacity: u32,
	used:     u32,
}

range_init :: proc(
	a: ^Range_Allocator,
	capacity: u32,
	allocator := context.allocator,
	loc := #caller_location,
) {
	a^ = {
		capacity = capacity,
	}
	a.free = make([dynamic]Range, 0, 64, allocator, loc)
	if capacity > 0 {append(&a.free, Range{0, capacity})}
}

range_destroy :: proc(a: ^Range_Allocator) {
	delete(a.free)
	a^ = {}
}

// range_alloc returns size units; ok is false when no free range is large
// enough.
range_alloc :: proc(a: ^Range_Allocator, size: u32) -> (r: Range, ok: bool) {
	assert(size > 0)
	for &f, i in a.free {
		if f.size < size {continue}
		r = {f.offset, size}
		f.offset += size
		f.size -= size
		if f.size == 0 {ordered_remove(&a.free, i)}
		a.used += size
		return r, true
	}
	return {}, false
}

range_free :: proc(a: ^Range_Allocator, r: Range) {
	assert(r.size > 0 && r.offset + r.size <= a.capacity)
	// First free range after r.
	i, _ := slice.binary_search_by(
		a.free[:],
		r.offset,
		proc(f: Range, offset: u32) -> slice.Ordering {
			return slice.Ordering.Less if f.offset < offset else .Greater
		},
	)
	assert(
		i == len(a.free) || r.offset + r.size <= a.free[i].offset,
		"range freed twice or overlapping",
	)
	assert(
		i == 0 || a.free[i - 1].offset + a.free[i - 1].size <= r.offset,
		"range freed twice or overlapping",
	)
	a.used -= r.size
	merge_prev := i > 0 && a.free[i - 1].offset + a.free[i - 1].size == r.offset
	merge_next := i < len(a.free) && r.offset + r.size == a.free[i].offset
	switch {
	case merge_prev && merge_next:
		a.free[i - 1].size += r.size + a.free[i].size
		ordered_remove(&a.free, i)
	case merge_prev:
		a.free[i - 1].size += r.size
	case merge_next:
		a.free[i].offset = r.offset
		a.free[i].size += r.size
	case:
		inject_at(&a.free, i, r)
	}
}

// range_largest_free is the biggest allocation that would succeed now.
range_largest_free :: proc(a: ^Range_Allocator) -> u32 {
	largest: u32
	for f in a.free {largest = max(largest, f.size)}
	return largest
}
