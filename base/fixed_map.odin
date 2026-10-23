package base

import "base:runtime"
import "core:mem"

// map_make_fixed makes a map that holds up to n entries without ever
// growing. Odin maps grow when they are MAP_LOAD_FACTOR% full, so
// make(map, n) alone regrows somewhere past 3/4 n entries, which in an arena
// leaks the old table each time.
map_make_fixed :: proc(
	$M: typeid/map[$K]$V,
	n: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	m: M,
	err: mem.Allocator_Error,
) {
	return make(M, map_capacity_for(n), allocator, loc)
}

// map_capacity_for is the capacity to reserve for n entries.
map_capacity_for :: proc(n: int) -> int {
	return n * 100 / runtime.MAP_LOAD_FACTOR + 1
}
