package core

import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"

import "common:game"
import "common:protocol"

// Machines: a game's blocks with a mind (common/game/block_entity.odin): a block type of the
// game's pack declared `"entity": {"kind": "machine", "slots": n}` keeps, with its chunk,
// the game's record on it (Game.machine_data), what players are shown of it
// (Game.machine_shown), its first n slots (its inventory) and when it thinks next. Placing
// and breaking one is a block edit like any (the journal keeps a broken one's value for
// undo; what it held spills as a chest's does).
//
// Thinking costs only what is due: a machine sleeps until the game wakes it
// (machine_wake: in so many ticks), and each tick the machines whose time has come are
// handed to the game's machines hook, a batch per block type, lowest position first, in
// one call (tens of thousands of machines cost what the due ones cost). The time is the
// server's age (its persistent tick), saved with the chunk, so a machine thinks on after a
// restart where it left off. What it shows goes to every player who has its chunk, when it
// changes and with the chunk; what it holds is in the item ledger as a chest's is.

MAX_MACHINE_THINKS :: 1 << 15 // in one tick (more wait for the next)

// A factory works wherever its players are: a chunk holding a machine or a belt (a working
// chunk) stays loaded, and so simulated, with nobody near, as world_keep's areas do, and the
// world remembers which chunks they are (world.cfg's `working` lines), so after a restart
// they load and work again before anyone comes. The rule's budget: at most
// MAX_WORKING_CHUNKS a world (the lowest by position); a chunk past it works only while a
// player is near, and pauses when none is (its machines think on when it loads again, as
// due, never catching up on what they missed).
MAX_WORKING_CHUNKS :: 512

Machine_Due :: struct {
	due: u64, // server age
	pos: game.Block_Pos,
}

// Machines: the world's queue of machines waiting to think.
Machines :: struct {
	heap:   [dynamic]Machine_Due, // by (due, pos), earliest at the top (heap)
	queued: map[game.Block_Pos]u64, // the due each waits for: an entry not matching is stale (heap)
	thinks: u64, // run since the world opened (stats)
}

@(private = "file")
heap_alloc :: proc() -> runtime.Allocator {return runtime.heap_allocator()}

machines_destroy :: proc(m: ^Machines) {
	delete(m.heap)
	delete(m.queued)
	m^ = {}
}

@(private = "file")
due_less :: proc(a, b: Machine_Due) -> bool {
	return a.due < b.due || (a.due == b.due && game.block_pos_less(a.pos, b.pos))
}

@(private = "file")
queue_push :: proc(m: ^Machines, p: game.Block_Pos, due: u64) {
	if m.heap.allocator.procedure == nil {
		m.heap.allocator = heap_alloc()
		m.queued.allocator = heap_alloc()
	}
	m.queued[p] = due
	append(&m.heap, Machine_Due{due, p})
	h := m.heap[:]
	i := len(h) - 1
	for i > 0 {
		up := (i - 1) / 2
		if !due_less(h[i], h[up]) {break}
		h[i], h[up] = h[up], h[i]
		i = up
	}
}

@(private = "file")
queue_pop :: proc(m: ^Machines) -> Machine_Due {
	h := m.heap[:]
	top := h[0]
	last := len(h) - 1
	h[0] = h[last]
	pop(&m.heap)
	h = m.heap[:]
	i := 0
	for {
		l, r, least := 2 * i + 1, 2 * i + 2, i
		if l < len(h) && due_less(h[l], h[least]) {least = l}
		if r < len(h) && due_less(h[r], h[least]) {least = r}
		if least == i {break}
		h[i], h[least] = h[least], h[i]
		i = least
	}
	return top
}

// machine_entity: the machine at p (nil: none there, or its chunk not loaded).
@(private)
machine_entity :: proc(w: ^World, p: game.Block_Pos) -> ^game.Block_Entity {
	e := block_entity_at(w, p)
	return e if e != nil && e.kind == .Machine else nil
}

// machine_kind: the block type of the machine at p (false: no machine there).
machine_kind :: proc(w: ^World, p: game.Block_Pos) -> (game.Block_Type, bool) {
	if machine_entity(w, p) == nil {return {}, false}
	b, _ := chunks_block(&w.chunks, p)
	return w.server.registry.blocks.type_of[b], true
}

// machine_data: the game's record on the machine at p, as the type it declared
// (Game.machine_data): zero when the machine is built, saved with its chunk. Nil: no
// machine there. Reading it marks the chunk changed (it is saved again).
machine_data :: proc(w: ^World, p: game.Block_Pos, $T: typeid) -> ^T {
	assert(w.server.config.game.machine_data == T, "not the game's machine_data")
	e := machine_entity(w, p)
	if e == nil {return nil}
	block_entity_touch(w, p)
	return (^T)(&e.data)
}

// machine_slots: the machine's inventory (its type's slots; nil: no machine there). A
// game moves stacks in and out of it as it would its own; what a machine makes or uses up
// it books (items_made, items_used). Marks the chunk changed.
machine_slots :: proc(w: ^World, p: game.Block_Pos) -> []game.Stack {
	e := machine_entity(w, p)
	if e == nil {return nil}
	block_entity_touch(w, p)
	b, _ := chunks_block(&w.chunks, p)
	t := &w.server.registry.blocks
	return e.slots[:t.types[t.type_of[b]].slots]
}

// machine_wake: the machine at p thinks in `ticks` ticks (at least one), unless it is
// already to think sooner. A machine thinks once each time it is woken.
machine_wake :: proc(w: ^World, p: game.Block_Pos, ticks: int) {
	e := machine_entity(w, p)
	if e == nil {return}
	m := &w.machines
	due := age_of(w.server) + u64(max(ticks, 1))
	if e.due != 0 && e.due <= due && m.queued[p] == e.due {return}
	block_entity_touch(w, p)
	e.due = due
	queue_push(m, p, due)
}

// machine_sleep: the machine at p thinks no more until woken.
machine_sleep :: proc(w: ^World, p: game.Block_Pos) {
	e := machine_entity(w, p)
	if e == nil || e.due == 0 {return}
	block_entity_touch(w, p)
	e.due = 0
	delete_key(&w.machines.queued, p)
}

// machine_show: what players are shown of the machine at p (the game's Game.machine_shown
// type: what it makes, its progress, why it stands): sent, when it changes, to every player
// who has its chunk, and with the chunk to those who get it later (engine.machine_shown).
machine_show :: proc(w: ^World, p: game.Block_Pos, value: ^$T) {
	s := w.server
	assert(s.config.game.machine_shown == T, "not the game's machine_shown")
	#assert(size_of(T) <= game.MAX_MACHINE_SHOWN)
	machine_show_bytes(w, p, ([^]u8)(value)[:size_of(T)])
}

@(private = "file")
machine_show_bytes :: proc(w: ^World, p: game.Block_Pos, bytes: []u8) {
	s := w.server
	e := machine_entity(w, p)
	if e == nil {return}
	if mem.compare(e.shown[:len(bytes)], bytes) == 0 {return}
	block_entity_touch(w, p)
	copy(e.shown[:], bytes)
	record := protocol.Machine_Record{e.shown}
	chunk := game.chunk_of(p)
	for &c in s.clients {
		if c.state != .Playing || c.world != w || chunk not_in c.has {continue}
		state_put(s, &c, .Machine, &record, protocol.key_of_block(p))
	}
}

// machines_sent: c was sent chunk whole: what its machines show follows it.
@(private)
machines_sent :: proc(s: ^Server, c: ^Client, chunk: ^Chunk) {
	origin := game.chunk_origin(chunk.pos)
	for &e in chunk.block_entities {
		if e.kind != .Machine || e.shown == {} {continue}
		record := protocol.Machine_Record{e.shown}
		p := origin + game.local_from_index(int(e.local))
		state_put(s, c, .Machine, &record, protocol.key_of_block(p))
	}
}

// machines_loaded: chunk came from its save: its machines that were to think wait again
// (one whose time passed while it was away thinks at once).
@(private)
machines_loaded :: proc(w: ^World, chunk: ^Chunk) {
	origin := game.chunk_origin(chunk.pos)
	for &e in chunk.block_entities {
		if e.kind != .Machine || e.due == 0 {continue}
		queue_push(&w.machines, origin + game.local_from_index(int(e.local)), e.due)
	}
}

// working_note: chunk holds a machine or a belt (holds false: no longer). The chunks kept
// are the lowest MAX_WORKING_CHUNKS by position.
@(private)
working_note :: proc(w: ^World, chunk: game.Chunk_Pos, holds: bool) {
	if (chunk in w.working) == holds {return}
	if w.working == nil {w.working = make(map[game.Chunk_Pos]bool, heap_alloc())}
	if holds {w.working[chunk] = false} else {delete_key(&w.working, chunk)}
	all := make([dynamic]game.Chunk_Pos, 0, len(w.working), context.temp_allocator)
	for pos in w.working {append(&all, pos)}
	slice.sort_by(all[:], game.chunk_pos_less)
	for pos, i in all {w.working[pos] = i < MAX_WORKING_CHUNKS}
	if holds && len(all) == MAX_WORKING_CHUNKS + 1 {
		log.warnf(
			"server more working chunks than kept (%d): those past it work only with a player near",
			MAX_WORKING_CHUNKS,
		)
	}
}

// working_chunk: whether chunk (loaded) holds a machine or a belt.
@(private)
working_chunk :: proc(c: ^Chunk) -> bool {
	for e in c.block_entities {if e.kind == .Machine || e.kind == .Belt {return true}}
	return false
}

// items_made: the game's machines made count of item (a furnace's bar): booked in the item
// ledger as the game's.
items_made :: proc(s: ^Server, w: ^World, item: game.Item, count: int) {
	ledger(s, w, .Game, item, count)
}

// items_used: the game's machines used up count of item (the ore a furnace took): booked in
// the item ledger as the game's.
items_used :: proc(s: ^Server, w: ^World, item: game.Item, count: int) {
	ledger(s, w, .Game, item, -count)
}

// machines_tick: the machines whose time has come think, a batch per block type (the
// game's machines hook), at most MAX_MACHINE_THINKS (the rest wait a tick).
@(private)
machines_tick :: proc(w: ^World) {
	s := w.server
	m := &w.machines
	if len(m.heap) == 0 {return}
	age := age_of(s)
	Due_Machine :: struct {
		kind: game.Block_Type,
		pos:  game.Block_Pos,
	}
	due := make([dynamic]Due_Machine, context.temp_allocator)
	for len(m.heap) > 0 && m.heap[0].due <= age && len(due) < MAX_MACHINE_THINKS {
		top := queue_pop(m)
		if q, waiting := m.queued[top.pos]; !waiting || q != top.due {continue} 	// (stale)
		delete_key(&m.queued, top.pos)
		e := machine_entity(w, top.pos)
		if e == nil || e.due != top.due {continue} 	// (gone, or its chunk away)
		block_entity_touch(w, top.pos)
		e.due = 0
		kind, _ := machine_kind(w, top.pos)
		append(&due, Due_Machine{kind, top.pos})
	}
	if len(due) == 0 || s.config.game.machines == nil {return}
	slice.sort_by(due[:], proc(a, b: Due_Machine) -> bool {
		return a.kind < b.kind || (a.kind == b.kind && game.block_pos_less(a.pos, b.pos))
	})
	at := make([]game.Block_Pos, len(due), context.temp_allocator)
	for d, i in due {at[i] = d.pos}
	m.thinks += u64(len(due))
	for start := 0; start < len(due); {
		end := start + 1
		for end < len(due) && due[end].kind == due[start].kind {end += 1}
		s.config.game.machines(s, w, due[start].kind, at[start:end])
		start = end
	}
}
