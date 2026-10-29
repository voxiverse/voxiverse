package base

import "base:intrinsics"
import "core:mem"

// Pool is fixed-capacity storage for one kind of object, addressed by
// generational handles. Capacity is set at init and never grows, so pointers
// returned by pool_get stay valid until that object is removed; a handle to a
// removed object stops resolving (pool_get returns nil) instead of aliasing
// whatever reuses its slot.
//
// H is the handle type, a distinct u32 per pool kind so handles of different
// kinds can't be mixed up:
//
//	Entity :: distinct u32
//	entities: base.Pool(Entity_Data, Entity)
//
// A handle packs a 20-bit slot index (slot 0 is reserved, so the zero handle
// is always invalid and zero-initialised handle fields mean "none") and a
// 12-bit generation, bumped each time a slot is freed. A stale handle could
// only resolve again after its slot is reused 4096 times.
Pool :: struct($T: typeid, $H: typeid) where intrinsics.type_core_type(H) == u32 {
	items:     []T,
	gens:      []u16,
	alive:     []bool,
	free:      []u32, // stack of freed slot indices
	free_len:  int,
	high:      u32, // slots handed out so far, including the reserved slot 0
	count:     int,
	allocator: mem.Allocator,
}

POOL_INDEX_BITS :: 20
POOL_MAX_CAPACITY :: 1 << POOL_INDEX_BITS - 1
POOL_GEN_MASK :: 1 << (32 - POOL_INDEX_BITS) - 1

// pool_init allocates room for capacity objects. Free everything at once by
// freeing the allocator (a session arena), or call pool_destroy.
pool_init :: proc(
	p: ^Pool($T, $H),
	capacity: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> mem.Allocator_Error {
	assert(capacity > 0 && capacity <= POOL_MAX_CAPACITY, "pool capacity out of range", loc)
	slots := capacity + 1 // slot 0 is reserved
	p^ = {}
	p.allocator = allocator
	p.items = make([]T, slots, allocator, loc) or_return
	p.gens = make([]u16, slots, allocator, loc) or_return
	p.alive = make([]bool, slots, allocator, loc) or_return
	p.free = make([]u32, capacity, allocator, loc) or_return
	p.high = 1
	return nil
}

pool_destroy :: proc(p: ^Pool($T, $H), loc := #caller_location) {
	delete(p.items, p.allocator, loc)
	delete(p.gens, p.allocator, loc)
	delete(p.alive, p.allocator, loc)
	delete(p.free, p.allocator, loc)
	p^ = {}
}

// pool_add stores value and returns its handle and a pointer to the stored
// copy; ok is false when the pool is full.
pool_add :: proc(p: ^Pool($T, $H), value: T) -> (handle: H, item: ^T, ok: bool) {
	index: u32
	if p.free_len > 0 {
		p.free_len -= 1
		index = p.free[p.free_len]
	} else if int(p.high) < len(p.items) {
		index = p.high
		p.high += 1
	} else {
		return
	}
	p.items[index] = value
	p.alive[index] = true
	p.count += 1
	return pool_make_handle(H, index, p.gens[index]), &p.items[index], true
}

// pool_get resolves a handle, returning nil for the zero handle, a removed
// object or a handle from a different generation.
pool_get :: proc(p: ^Pool($T, $H), handle: H) -> ^T {
	index, gen := pool_split_handle(handle)
	if index == 0 || int(index) >= int(p.high) || !p.alive[index] || p.gens[index] != gen {
		return nil
	}
	return &p.items[index]
}

// pool_remove frees the handle's slot; false if the handle was already stale.
pool_remove :: proc(p: ^Pool($T, $H), handle: H) -> bool {
	if pool_get(p, handle) == nil {return false}
	index, _ := pool_split_handle(handle)
	p.alive[index] = false
	p.items[index] = {}
	p.gens[index] = (p.gens[index] + 1) & POOL_GEN_MASK
	p.free[p.free_len] = index
	p.free_len += 1
	p.count -= 1
	return true
}

// Pool_Iterator walks live objects in slot order:
//
//	it: base.Pool_Iterator
//	for item, handle in base.pool_next(&pool, &it) { ... }
//
// Removing the current object while iterating is allowed; adding is not.
Pool_Iterator :: struct {
	index: u32,
}

pool_next :: proc(p: ^Pool($T, $H), it: ^Pool_Iterator) -> (item: ^T, handle: H, ok: bool) {
	if it.index == 0 {it.index = 1}
	for it.index < p.high {
		index := it.index
		it.index += 1
		if p.alive[index] {
			return &p.items[index], pool_make_handle(H, index, p.gens[index]), true
		}
	}
	return
}

@(private)
pool_make_handle :: #force_inline proc($H: typeid, index: u32, gen: u16) -> H {
	return H(u32(gen) << POOL_INDEX_BITS | index)
}

@(private)
pool_split_handle :: #force_inline proc(handle: $H) -> (index: u32, gen: u16) {
	raw := u32(handle)
	return raw & POOL_MAX_CAPACITY, u16(raw >> POOL_INDEX_BITS)
}
