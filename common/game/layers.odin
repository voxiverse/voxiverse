package game

import "core:mem"
import "core:mem/virtual"

// Voxel layers: a channel is a named per-cell value beside the block (M49),
// `u16` at most. The block channel is Chunk_Blocks (the hot path of physics and
// meshing); the others are palette-compressed here, one Channel a chunk each:
// Uniform (one value), Small (a 16-entry palette and four-bit indices), Large
// (a 256-entry palette and byte indices) or Direct (4096 u16). A page comes from
// a Page_Pool of its class, so memory has a hard ceiling and is flat over churn.

MAX_CHANNELS :: 8
CHANNEL_CELLS :: CHUNK_VOLUME

Channel_Mode :: enum u8 {
	Uniform,
	Small,
	Large,
	Direct,
}

Channel :: struct {
	mode:    Channel_Mode,
	uniform: u16, // the value, in Uniform mode
	page:    rawptr, // Small_Page, Large_Page or Direct_Page, by mode
}

Chunk_Layers :: struct {
	channels: [MAX_CHANNELS]Channel,
}

Small_Page :: struct {
	palette: [16]u16,
	count:   u8,
	index:   [CHANNEL_CELLS / 2]u8, // four bits a cell, the low nibble first
}

Large_Page :: struct {
	palette: [256]u16,
	count:   u16,
	index:   [CHANNEL_CELLS]u8,
}

Direct_Page :: [CHANNEL_CELLS]u16

// Page_Pool hands out pages of one size from a reserved region committed in
// steps of 64 pages (Block_Arrays' scheme, generalised); returned pages are
// reused. Not thread-safe; one per owner.
Page_Pool :: struct {
	region:    []u8,
	committed: int,
	allocated: int,
	free:      []rawptr,
	free_len:  int,
	page_size: int, // a multiple of 64, so a step of 64 pages is whole OS pages
	allocator: mem.Allocator,
}

Layer_Pools :: struct {
	small:  Page_Pool,
	large:  Page_Pool,
	direct: Page_Pool,
}

@(private = "file")
round64 :: proc(n: int) -> int {return (n + 63) &~ 63}

page_pool_init :: proc(
	p: ^Page_Pool,
	capacity: int,
	size: int,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	p^ = {
		allocator = allocator,
		page_size = round64(size),
	}
	if capacity <= 0 {return nil}
	p.region = virtual.reserve(uint(capacity * p.page_size)) or_return
	p.free = make([]rawptr, capacity, allocator) or_return
	return nil
}

page_pool_destroy :: proc(p: ^Page_Pool) {
	if len(p.region) > 0 {virtual.release(raw_data(p.region), len(p.region))}
	delete(p.free, p.allocator)
	p^ = {}
}

page_pool_in_use :: proc(p: ^Page_Pool) -> int {return p.allocated - p.free_len}

page_pool_take :: proc(p: ^Page_Pool) -> (page: rawptr, err: mem.Allocator_Error) {
	if p.free_len > 0 {
		p.free_len -= 1
		return p.free[p.free_len], nil
	}
	if p.allocated == len(p.free) {return nil, .Out_Of_Memory}
	end := (p.allocated + 1) * p.page_size
	if end > p.committed {
		step := min(64 * p.page_size, len(p.region) - p.committed)
		virtual.commit(&p.region[p.committed], uint(step)) or_return
		p.committed += step
	}
	page = &p.region[p.allocated * p.page_size]
	p.allocated += 1
	return page, nil
}

page_pool_give :: proc(p: ^Page_Pool, page: rawptr) {
	assert(p.free_len < len(p.free), "page given back twice")
	p.free[p.free_len] = page
	p.free_len += 1
}

// layer_pools_init: capacity pages of each class (the world's chunk capacity times
// the stored channels declared). Zero capacity: no pool, every take fails.
layer_pools_init :: proc(
	l: ^Layer_Pools,
	capacity: int,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	page_pool_init(&l.small, capacity, size_of(Small_Page), allocator) or_return
	page_pool_init(&l.large, capacity, size_of(Large_Page), allocator) or_return
	page_pool_init(&l.direct, capacity, size_of(Direct_Page), allocator) or_return
	return nil
}

layer_pools_destroy :: proc(l: ^Layer_Pools) {
	page_pool_destroy(&l.small)
	page_pool_destroy(&l.large)
	page_pool_destroy(&l.direct)
}

layer_pools_in_use :: proc(l: ^Layer_Pools) -> int {
	return page_pool_in_use(&l.small) + page_pool_in_use(&l.large) + page_pool_in_use(&l.direct)
}

channel_get :: proc(ch: ^Channel, i: int) -> u16 {
	switch ch.mode {
	case .Uniform:
		return ch.uniform
	case .Small:
		pg := (^Small_Page)(ch.page)
		n := pg.index[i >> 1]
		return pg.palette[(n >> (uint(i & 1) * 4)) & 15]
	case .Large:
		pg := (^Large_Page)(ch.page)
		return pg.palette[pg.index[i]]
	case .Direct:
		return (^Direct_Page)(ch.page)[i]
	}
	return 0
}

@(private = "file")
small_put :: #force_inline proc(pg: ^Small_Page, i: int, n: u8) {
	shift := uint(i & 1) * 4
	b := &pg.index[i >> 1]
	b^ = (b^ & ~(u8(15) << shift)) | (n << shift)
}

@(private = "file")
small_at :: #force_inline proc(pg: ^Small_Page, i: int) -> u8 {
	return (pg.index[i >> 1] >> (uint(i & 1) * 4)) & 15
}

channel_set :: proc(ch: ^Channel, pools: ^Layer_Pools, i: int, v: u16) -> mem.Allocator_Error {
	switch ch.mode {
	case .Uniform:
		if v == ch.uniform {return nil}
		raw := page_pool_take(&pools.small) or_return
		pg := (^Small_Page)(raw)
		pg^ = {}
		pg.palette[0], pg.palette[1], pg.count = ch.uniform, v, 2
		small_put(pg, i, 1)
		ch.mode, ch.page = .Small, pg
	case .Small:
		pg := (^Small_Page)(ch.page)
		for k in 0 ..< int(pg.count) {
			if pg.palette[k] == v {
				small_put(pg, i, u8(k))
				return nil
			}
		}
		if pg.count < 16 {
			pg.palette[pg.count] = v
			small_put(pg, i, pg.count)
			pg.count += 1
			return nil
		}
		raw := page_pool_take(&pools.large) or_return
		big := (^Large_Page)(raw)
		big^ = {}
		for k in 0 ..< 16 {big.palette[k] = pg.palette[k]}
		big.count = 16
		for c in 0 ..< CHANNEL_CELLS {big.index[c] = small_at(pg, c)}
		big.palette[16], big.count = v, 17
		big.index[i] = 16
		page_pool_give(&pools.small, pg)
		ch.mode, ch.page = .Large, big
	case .Large:
		pg := (^Large_Page)(ch.page)
		for k in 0 ..< int(pg.count) {
			if pg.palette[k] == v {
				pg.index[i] = u8(k)
				return nil
			}
		}
		if pg.count < 256 {
			pg.palette[pg.count] = v
			pg.index[i] = u8(pg.count)
			pg.count += 1
			return nil
		}
		raw := page_pool_take(&pools.direct) or_return
		d := (^Direct_Page)(raw)
		for c in 0 ..< CHANNEL_CELLS {d[c] = pg.palette[pg.index[c]]}
		d[i] = v
		page_pool_give(&pools.large, pg)
		ch.mode, ch.page = .Direct, d
	case .Direct:
		(^Direct_Page)(ch.page)[i] = v
	}
	return nil
}

@(private = "file")
channel_release :: proc(ch: ^Channel, pools: ^Layer_Pools) {
	switch ch.mode {
	case .Uniform:
	case .Small:
		page_pool_give(&pools.small, ch.page)
	case .Large:
		page_pool_give(&pools.large, ch.page)
	case .Direct:
		page_pool_give(&pools.direct, ch.page)
	}
	ch^ = {}
}

// channel_compact rebuilds the palette in first-occurrence order of the cells and takes
// the smallest mode that fits (Uniform if one value). Run when a chunk is saved or
// unloaded, never in the middle of a tick, so representation never depends on timing.
// A pool at capacity leaves the channel as it was.
channel_compact :: proc(ch: ^Channel, pools: ^Layer_Pools) -> mem.Allocator_Error {
	if ch.mode == .Uniform {return nil}
	values: [CHANNEL_CELLS]u16
	palette: [257]u16
	count := 0
	for i in 0 ..< CHANNEL_CELLS {
		v := channel_get(ch, i)
		values[i] = v
		if count > 256 {continue}
		found := false
		for k in 0 ..< count {
			if palette[k] == v {found = true; break}
		}
		if !found {palette[count] = v; count += 1}
	}
	old := ch^
	next: Channel
	switch {
	case count == 1:
		next = {
			uniform = values[0],
		}
	case count <= 16:
		pg := (^Small_Page)(page_pool_take(&pools.small) or_return)
		pg^ = {}
		for k in 0 ..< count {pg.palette[k] = palette[k]}
		pg.count = u8(count)
		for i in 0 ..< CHANNEL_CELLS {
			for k in 0 ..< count {
				if palette[k] == values[i] {small_put(pg, i, u8(k)); break}
			}
		}
		next = {
			mode = .Small,
			page = pg,
		}
	case count <= 256:
		pg := (^Large_Page)(page_pool_take(&pools.large) or_return)
		pg^ = {}
		for k in 0 ..< count {pg.palette[k] = palette[k]}
		pg.count = u16(count)
		for i in 0 ..< CHANNEL_CELLS {
			for k in 0 ..< count {
				if palette[k] == values[i] {pg.index[i] = u8(k); break}
			}
		}
		next = {
			mode = .Large,
			page = pg,
		}
	case:
		d := (^Direct_Page)(page_pool_take(&pools.direct) or_return)
		d^ = values
		next = {
			mode = .Direct,
			page = d,
		}
	}
	channel_release(&old, pools)
	ch^ = next
	return nil
}

layers_compact :: proc(l: ^Chunk_Layers, pools: ^Layer_Pools) {
	for &ch in l.channels {channel_compact(&ch, pools)}
}

layers_release :: proc(l: ^Chunk_Layers, pools: ^Layer_Pools) {
	for &ch in l.channels {channel_release(&ch, pools)}
}

// layers_default: every channel in the chunk is Uniform at its default (infos by
// channel id), the case that costs nothing in memory, bytes or hash.
layers_default :: proc(l: ^Chunk_Layers, defaults: []u16) -> bool {
	for ch, i in l.channels {
		d := defaults[i] if i < len(defaults) else 0
		if ch.mode != .Uniform || ch.uniform != d {return false}
	}
	return true
}

// layers_hash_add folds the stored channels of one chunk into the hash h (a chunks_hash_add
// word): each channel not uniform at its default adds its id and its 4096 values, by index
// (values, never the palette or mode, so compaction cannot change a hash). Nothing is
// added for a chunk whose channels are all default.
layers_hash_add :: proc(
	h: u64,
	l: ^Chunk_Layers,
	defaults: []u16,
	which: bit_set[0 ..< MAX_CHANNELS],
) -> u64 {
	h := h
	mix :: #force_inline proc(h: u64, v: u64) -> u64 {return (h ~ v) * 0x100000001b3}
	for &ch, id in l.channels {
		if id not_in which {continue}
		d := defaults[id] if id < len(defaults) else 0
		if ch.mode == .Uniform && ch.uniform == d {continue}
		h = mix(h, u64(id) | 1 << 40)
		for i in 0 ..< CHANNEL_CELLS {h = mix(h, u64(channel_get(&ch, i)))}
	}
	return h
}
