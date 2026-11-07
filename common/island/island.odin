// Package island is the world's simulation islands: the set of chunks within a radius of one
// or more observers (players, later observer-mode viewers). Overlapping islands merge into
// one and an island splits when its observers part (docs/world.md, "Simulation islands").
//
// Chunks are compared on the horizontal plane (x and z; a column of chunks is one place).
// Two observers are in one island when their discs overlap, taken as: their chunks are within
// twice the radius of each other, and the relation is closed over chains of observers.
// Nothing is stored per chunk: whether a chunk is in an island is asked of the observers
// (`island_of`), so a recompute costs the observers, not the chunks.
package island

import "core:slice"

Chunk :: [3]i32

Observer :: struct {
	id:    u32, // the caller's (a player's id); unique among the observers
	chunk: Chunk,
}

Island_Id :: distinct u32 // 0: none

Event_Kind :: enum {
	Opened, // a new island: `chunks` entered detail
	Merged, // `from` joined `island`: no chunk changed by this alone
	Split, // `island` parted: `from` is the part that kept the id, `island` the new one
	Closed, // the island's last observer left: `chunks` left detail
}

Event :: struct {
	kind:   Event_Kind,
	island: Island_Id,
	from:   Island_Id, // Merged: the island that joined; Split: the island that parted
	chunks: []Chunk, // Opened: entered, Closed: left (the temp allocator)
}

Member :: struct {
	observer: Observer,
	island:   Island_Id,
}

Islands :: struct {
	radius:  i32, // chunks
	members: [dynamic]Member, // sorted by observer id
	next_id: Island_Id,
}

// Update_Result: what one `update` changed. All slices live in the temp allocator.
Update_Result :: struct {
	events:  []Event,
	entered: []Chunk, // chunks that came into detail (in no island before, in one now)
	left:    []Chunk, // chunks that went out of detail
}

destroy :: proc(i: ^Islands) {
	delete(i.members)
	i^ = {}
}

@(private)
within :: #force_inline proc(a, b: Chunk, r: i64) -> bool {
	dx, dz := i64(a.x) - i64(b.x), i64(a.z) - i64(b.z)
	return dx * dx + dz * dz <= r * r
}

// island_of: the island holding the chunk, 0 when it is in none.
island_of :: proc(i: ^Islands, c: Chunk) -> Island_Id {
	for m in i.members {
		if within(m.observer.chunk, c, i64(i.radius)) {return m.island}
	}
	return 0
}

// observers_of: the ids of an island's observers.
observers_of :: proc(i: ^Islands, id: Island_Id, allocator := context.temp_allocator) -> []u32 {
	out := make([dynamic]u32, allocator)
	for m in i.members {if m.island == id {append(&out, m.observer.id)}}
	return out[:]
}

// island_ids: the islands that exist, ascending.
island_ids :: proc(i: ^Islands, allocator := context.temp_allocator) -> []Island_Id {
	out := make([dynamic]Island_Id, allocator)
	for m in i.members {
		if !slice.contains(out[:], m.island) {append(&out, m.island)}
	}
	slice.sort(out[:])
	return out[:]
}

// island_chunks: every chunk of an island, once (columns at y 0).
island_chunks :: proc(i: ^Islands, id: Island_Id, allocator := context.temp_allocator) -> []Chunk {
	seen := make(map[[2]i32]struct{}, allocator)
	out := make([dynamic]Chunk, allocator)
	r := i.radius
	for m in i.members {
		if m.island != id {continue}
		o := m.observer.chunk
		for dz in -r ..= r {
			for dx in -r ..= r {
				if i64(dx) * i64(dx) + i64(dz) * i64(dz) > i64(r) * i64(r) {continue}
				k := [2]i32{o.x + dx, o.z + dz}
				if k in seen {continue}
				seen[k] = {}
				append(&out, Chunk{k.x, 0, k.y})
			}
		}
	}
	return out[:]
}

// island_size: how many chunks an island holds.
island_size :: proc(i: ^Islands, id: Island_Id) -> int {
	return len(island_chunks(i, id))
}

@(private)
covered :: proc(members: []Member, c: Chunk, r: i64) -> bool {
	for m in members {if within(m.observer.chunk, c, r) {return true}}
	return false
}

// update: set the islands for the observers now. Cheap when no observer moved to another
// chunk (one pass over the list), which is nearly every tick. radius is in chunks (>= 1).
// Island ids are kept: a merge keeps the lowest id, a split leaves the id with the part
// that holds most of the observers (ties: the part of the lowest observer id).
update :: proc(i: ^Islands, radius: i32, observers: []Observer) -> Update_Result {
	assert(radius >= 1)
	if i.next_id == 0 {i.next_id = 1}
	if i.radius == radius && len(observers) == len(i.members) {
		same := true
		sorted := true
		for o, n in observers {
			m := i.members[n].observer
			if m.id != o.id {sorted = false; break}
			if m.chunk != o.chunk {same = false}
		}
		if sorted && same {return {}}
	}
	obs := slice.clone(observers, context.temp_allocator)
	slice.sort_by(obs, proc(a, b: Observer) -> bool {return a.id < b.id})
	for n in 1 ..< len(obs) {assert(obs[n].id != obs[n - 1].id, "observer ids are unique")}

	old := slice.clone(i.members[:], context.temp_allocator)
	old_radius := i.radius if i.radius > 0 else radius
	r := i64(radius)

	// Components of the new observers (union by discs overlapping).
	n := len(obs)
	comp := make([]int, n, context.temp_allocator)
	for k in 0 ..< n {comp[k] = k}
	find :: proc(comp: []int, k: int) -> int {
		k := k
		for comp[k] != k {comp[k] = comp[comp[k]]; k = comp[k]}
		return k
	}
	for a in 0 ..< n {
		for b in a + 1 ..< n {
			if within(obs[a].chunk, obs[b].chunk, 2 * r) {
				ra, rb := find(comp, a), find(comp, b)
				if ra != rb {comp[max(ra, rb)] = min(ra, rb)}
			}
		}
	}
	// The components in order of their lowest observer index.
	roots := make([dynamic]int, context.temp_allocator)
	for k in 0 ..< n {if find(comp, k) == k {append(&roots, k)}}

	old_of :: proc(old: []Member, id: u32) -> (Island_Id, bool) {
		for m in old {if m.observer.id == id {return m.island, true}}
		return 0, false
	}
	// How many of each old island's surviving observers each component holds.
	old_ids := make([dynamic]Island_Id, context.temp_allocator)
	for m in old {if !slice.contains(old_ids[:], m.island) {append(&old_ids, m.island)}}
	slice.sort(old_ids[:])
	share := make([][]int, len(old_ids), context.temp_allocator) // [old island][root index]
	for &row in share {row = make([]int, len(roots), context.temp_allocator)}
	for k in 0 ..< n {
		id, was := old_of(old, obs[k].id)
		if !was {continue}
		oi, _ := slice.binary_search(old_ids[:], id)
		ri, _ := slice.linear_search(roots[:], find(comp, k))
		share[oi][ri] += 1
	}
	// The heir of an old island: the component with most of its observers.
	heir := make([]int, len(old_ids), context.temp_allocator) // root index, -1: none
	for row, oi in share {
		heir[oi] = -1
		best := 0
		for cnt, ri in row {if cnt > best {best = cnt; heir[oi] = ri}}
	}
	// Each component's id: the lowest old id it is heir of, else a fresh one.
	ids := make([]Island_Id, len(roots), context.temp_allocator)
	for oi in 0 ..< len(old_ids) {
		ri := heir[oi]
		if ri >= 0 && ids[ri] == 0 {ids[ri] = old_ids[oi]} 	// (old_ids ascending: the lowest)
	}
	events := make([dynamic]Event, context.temp_allocator)
	fresh := make([]bool, len(roots), context.temp_allocator)
	for ri in 0 ..< len(roots) {
		if ids[ri] != 0 {continue}
		ids[ri] = i.next_id
		i.next_id += 1
		fresh[ri] = true
	}
	// Events. Merged: old islands whose heir is a component that carries another id.
	for oi in 0 ..< len(old_ids) {
		ri := heir[oi]
		if ri >= 0 && ids[ri] != old_ids[oi] {
			append(&events, Event{kind = .Merged, island = ids[ri], from = old_ids[oi]})
		}
	}
	// Split: an old island with observers in more than one component.
	for row, oi in share {
		for cnt, ri in row {
			if cnt > 0 && ri != heir[oi] {
				append(&events, Event{kind = .Split, island = ids[ri], from = old_ids[oi]})
			}
		}
	}

	// The members now.
	clear(&i.members)
	for k in 0 ..< n {
		ri, _ := slice.linear_search(roots[:], find(comp, k))
		append(&i.members, Member{obs[k], ids[ri]})
	}
	i.radius = radius

	// Chunks that entered and left detail: only around observers that arrived, left or
	// moved can a chunk change, so those discs are the candidates.
	entered := make([dynamic]Chunk, context.temp_allocator)
	left := make([dynamic]Chunk, context.temp_allocator)
	seen := make(map[[2]i32]struct{}, context.temp_allocator)
	changed := make([dynamic]Chunk, context.temp_allocator)
	for m in old {
		cur, there := observer_chunk(obs, m.observer.id)
		if !there ||
		   cur != m.observer.chunk ||
		   old_radius != radius {append(&changed, m.observer.chunk)}
	}
	for o in obs {
		oc, was := observer_chunk(old, o.id)
		if !was || oc != o.chunk || old_radius != radius {append(&changed, o.chunk)}
	}
	// (old discs use the old radius, new discs the new one: take the larger as the reach)
	reach := max(i64(old_radius), r)
	for o in changed {
		for dz in -reach ..= reach {
			for dx in -reach ..= reach {
				if dx * dx + dz * dz > reach * reach {continue}
				k := [2]i32{o.x + i32(dx), o.z + i32(dz)}
				if k in seen {continue}
				seen[k] = {}
				c := Chunk{k.x, 0, k.y}
				was := covered(old, c, i64(old_radius))
				now := covered(i.members[:], c, r)
				if now && !was {append(&entered, c)} else if was && !now {append(&left, c)}
			}
		}
	}
	slice.sort_by(entered[:], chunk_less)
	slice.sort_by(left[:], chunk_less)

	// Opened and Closed carry their chunks.
	for ri in 0 ..< len(roots) {
		if !fresh[ri] {continue}
		// A fresh id is Opened when none of its observers were in an island before.
		fromold := false
		for k in 0 ..< n {
			if find(comp, k) != roots[ri] {continue}
			if _, was := old_of(old, obs[k].id); was {fromold = true}
		}
		if fromold {continue} 	// a Split part
		mine := make([dynamic]Chunk, context.temp_allocator)
		for c in entered {if island_of(i, c) == ids[ri] {append(&mine, c)}}
		append(&events, Event{kind = .Opened, island = ids[ri], chunks = mine[:]})
	}
	for oi in 0 ..< len(old_ids) {
		if heir[oi] >= 0 {continue}
		mine := make([dynamic]Chunk, context.temp_allocator)
		for c in left {
			for m in old {
				if m.island == old_ids[oi] && within(m.observer.chunk, c, i64(old_radius)) {
					append(&mine, c)
					break
				}
			}
		}
		append(&events, Event{kind = .Closed, island = old_ids[oi], chunks = mine[:]})
	}
	return {events[:], entered[:], left[:]}
}

@(private)
observer_chunk :: proc(list: []$T, id: u32) -> (Chunk, bool) {
	for e in list {
		when T == Observer {
			if e.id == id {return e.chunk, true}
		} else {
			if e.observer.id == id {return e.observer.chunk, true}
		}
	}
	return {}, false
}

@(private)
chunk_less :: proc(a, b: Chunk) -> bool {
	if a.x != b.x {return a.x < b.x}
	if a.z != b.z {return a.z < b.z}
	return a.y < b.y
}
