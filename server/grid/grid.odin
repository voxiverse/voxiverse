package grid

import "base:runtime"
import "core:slice"

import "common:base"
import "common:game"

// Networks over blocks (power lines, pipes): blocks of the kinds a grid names and the machines
// they reach form connected parts, kept as blocks change, a block at a time: a block added
// joins the parts it touches (merging them), one removed splits its part again only where it
// held it together (a search over that part alone). The game reads each part's members and
// nodes to balance what its generators give against what its machines ask.
//
// A conductor (a cable, a pole: reach 0 joins only what touches its faces; reach r, at most
// MAX_REACH, anything within r blocks each way) carries; a node (a machine) joins whatever
// conductor reaches it, and never another node. Parts are numbered; a part keeps its number
// while it only grows, and the largest piece keeps it when it splits.

MAX_REACH :: 8
@(private = "file")
BUCKET :: 8 // blocks a side of the index's buckets (MAX_REACH: a reach spans two at most)

Kind :: struct {
	type:  game.Block_Type,
	reach: i32, // a conductor's (0: its faces)
	node:  bool, // a machine: joins a conductor that reaches it
}

Member :: struct {
	reach: i32,
	node:  bool,
	part:  u32,
}

Part :: struct {
	id:      u32,
	members: [dynamic]game.Block_Pos, // conductors and nodes, in no order (heap)
}

Grid :: struct {
	kinds:   map[game.Block_Type]Kind, // (heap)
	members: map[game.Block_Pos]Member, // (heap)
	buckets: map[game.Block_Pos][dynamic]game.Block_Pos, // the members by BUCKET cube (heap)
	parts:   map[u32]Part, // (heap)
	next:    u32, // the next part's number
	changes: u64, // members added or removed (the game may redo what it balanced)
}

grid_make :: proc(kinds: []Kind) -> (g: Grid) {
	alloc := runtime.heap_allocator()
	g.kinds = make(map[game.Block_Type]Kind, alloc)
	g.members = make(map[game.Block_Pos]Member, alloc)
	g.buckets = make(map[game.Block_Pos][dynamic]game.Block_Pos, alloc)
	g.parts = make(map[u32]Part, alloc)
	g.next = 1
	for k in kinds {g.kinds[k.type] = {k.type, clamp(k.reach, 0, MAX_REACH), k.node}}
	return
}

grid_destroy :: proc(g: ^Grid) {
	for _, list in g.buckets {delete(list)}
	for _, part in g.parts {delete(part.members)}
	delete(g.kinds)
	delete(g.members)
	delete(g.buckets)
	delete(g.parts)
	g^ = {}
}

@(private = "file")
bucket_of :: proc(p: game.Block_Pos) -> game.Block_Pos {
	return {base.floor_div(p.x, BUCKET), base.floor_div(p.y, BUCKET), base.floor_div(p.z, BUCKET)}
}

// connected: a and b join: neither is a node, or one is a conductor that reaches the other.
@(private = "file")
connected :: proc(pa: game.Block_Pos, a: Member, pb: game.Block_Pos, b: Member) -> bool {
	if a.node && b.node {return false}
	d := pa - pb
	d = {abs(d.x), abs(d.y), abs(d.z)}
	if d.x + d.y + d.z == 1 {return true}
	reach := max(0 if a.node else a.reach, 0 if b.node else b.reach)
	return reach > 0 && max(d.x, d.y, d.z) <= reach
}

// neighbours: the members joined to the member at p (temp).
@(private = "file")
neighbours :: proc(g: ^Grid, p: game.Block_Pos, m: Member) -> [dynamic]game.Block_Pos {
	out := make([dynamic]game.Block_Pos, context.temp_allocator)
	lo, hi := bucket_of(p - MAX_REACH), bucket_of(p + MAX_REACH)
	for by in lo.y ..= hi.y {
		for bz in lo.z ..= hi.z {
			for bx in lo.x ..= hi.x {
				list, has := g.buckets[{bx, by, bz}]
				if !has {continue}
				for q in list {
					if q != p && connected(p, m, q, g.members[q]) {append(&out, q)}
				}
			}
		}
	}
	return out
}

// grid_block: the block at p went from old to new: the grid follows (a member gone, a
// member come, or both for a member of one kind turned into another).
grid_block :: proc(g: ^Grid, t: ^game.Block_Table, p: game.Block_Pos, old, new: game.Block) {
	was, had := g.kinds[t.type_of[old]]
	now, has := g.kinds[t.type_of[new]]
	if had && has && was == now {return}
	if had {grid_remove(g, p)}
	if has {grid_add(g, p, now)}
}

// grid_add: a member of kind k at p.
grid_add :: proc(g: ^Grid, p: game.Block_Pos, k: Kind) {
	if p in g.members {grid_remove(g, p)}
	m := Member{k.reach, k.node, 0}
	near := neighbours(g, p, m)
	// It joins the largest part it touches; the others merge into it.
	keep: u32
	for q in near {
		id := g.members[q].part
		if keep == 0 ||
		   len(g.parts[id].members) > len(g.parts[keep].members) ||
		   (len(g.parts[id].members) == len(g.parts[keep].members) && id < keep) {keep = id}
	}
	if keep == 0 {
		keep = g.next
		g.next += 1
		g.parts[keep] = {keep, make([dynamic]game.Block_Pos, runtime.heap_allocator())}
	}
	for q in near {
		id := g.members[q].part
		if id == keep {continue}
		other := g.parts[id]
		into, _ := &g.parts[keep]
		for r in other.members {
			append(&into.members, r)
			(&g.members[r]).part = keep
		}
		delete(other.members)
		delete_key(&g.parts, id)
	}
	m.part = keep
	g.members[p] = m
	into, _ := &g.parts[keep]
	append(&into.members, p)
	bucket, _ := &g.buckets[bucket_of(p)]
	if bucket == nil {
		g.buckets[bucket_of(p)] = make([dynamic]game.Block_Pos, runtime.heap_allocator())
		bucket = &g.buckets[bucket_of(p)]
	}
	append(bucket, p)
	g.changes += 1
}

// grid_remove: the member at p is gone; its part splits where it held it together.
grid_remove :: proc(g: ^Grid, p: game.Block_Pos) {
	m, had := g.members[p]
	if !had {return}
	delete_key(&g.members, p)
	if bucket, _ := &g.buckets[bucket_of(p)]; bucket != nil {
		if i, found := slice.linear_search(bucket[:], p); found {unordered_remove(bucket, i)}
	}
	g.changes += 1
	part := g.parts[m.part]
	delete_key(&g.parts, m.part)
	defer delete(part.members)
	// The rest of the part, searched again: each piece a part, the largest keeping its number.
	left := make([dynamic]game.Block_Pos, context.temp_allocator)
	for q in part.members {if q != p {append(&left, q)}}
	slice.sort_by(left[:], game.block_pos_less)
	seen := make(map[game.Block_Pos]u32, context.temp_allocator)
	pieces := make([dynamic][dynamic]game.Block_Pos, context.temp_allocator)
	for start in left {
		if start in seen {continue}
		piece := make([dynamic]game.Block_Pos, runtime.heap_allocator())
		seen[start] = u32(len(pieces))
		todo := make([dynamic]game.Block_Pos, context.temp_allocator)
		append(&todo, start)
		for len(todo) > 0 {
			q := pop(&todo)
			append(&piece, q)
			for r in neighbours(g, q, g.members[q]) {
				if r in seen {continue}
				seen[r] = u32(len(pieces))
				append(&todo, r)
			}
		}
		append(&pieces, piece)
	}
	largest := -1
	for piece, i in pieces {if largest < 0 || len(piece) > len(pieces[largest]) {largest = i}}
	for piece, i in pieces {
		id := m.part if i == largest else g.next
		if i != largest {g.next += 1}
		g.parts[id] = {id, piece}
		for q in piece {(&g.members[q]).part = id}
	}
}

// grid_part_of: the part of the member at p (false: no member there).
grid_part_of :: proc(g: ^Grid, p: game.Block_Pos) -> (u32, bool) {
	m, has := g.members[p]
	return m.part, has
}

// grid_parts: every part, by number (temp).
grid_parts :: proc(g: ^Grid) -> []^Part {
	out := make([dynamic]^Part, 0, len(g.parts), context.temp_allocator)
	for _, &part in g.parts {append(&out, &part)}
	slice.sort_by(out[:], proc(a, b: ^Part) -> bool {return a.id < b.id})
	return out[:]
}

// grid_is_node: the member at p is a node (a machine), not a conductor.
grid_is_node :: proc(g: ^Grid, p: game.Block_Pos) -> bool {
	m, has := g.members[p]
	return has && m.node
}
