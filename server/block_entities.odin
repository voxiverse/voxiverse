package server

import "base:runtime"
import "core:log"
import "core:slice"

import "../base"
import "../common/game"

// Block entities (M48b, common/game/block_entity.odin): the data a block
// keeps beyond its state, held by its chunk. One point decides when they
// exist: entity_lifecycle, called wherever a block changes (set_block, bulk
// edits), compares the kind the old state has with the new one's.

// ENTITY_UNDO_MAX: how many removed entities' values the journal keeps for
// rollback (the oldest go first).
ENTITY_UNDO_MAX :: 4096

// Entity_Undo_Key names the journal entry that removed an entity.
Entity_Undo_Key :: struct {
	pos:    game.Block_Pos,
	action: u32,
	age:    u64,
}

// Pending_Entity: a removed entity's value, not encoded yet.
Pending_Entity :: struct {
	key:   Entity_Undo_Key,
	value: []u8, // (heap)
}

// Entity_At: a block entity and where it is (temp).
Entity_At :: struct {
	pos: game.Block_Pos,
	e:   ^game.Block_Entity,
}

@(private = "file")
heap :: proc() -> runtime.Allocator {return runtime.heap_allocator()}

// block_entity_at: the entity of the block at p, nil if it has none.
block_entity_at :: proc(w: ^World, p: game.Block_Pos) -> ^game.Block_Entity {
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil || c.state != .Ready {return nil}
	at, found := game.block_entity_find(
		c.block_entities[:],
		u16(game.local_index(game.local_of(p))),
	)
	if !found {return nil}
	return &c.block_entities[at]
}

// block_entity_touch: the chunk's entities are about to change (or did): kept
// for a running save, saved with the chunk.
block_entity_touch :: proc(w: ^World, p: game.Block_Pos) {
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil || c.state != .Ready {return}
	chunk_cow(&w.chunks, c)
	c.modified = true
	mark_edited(w, c.pos)
}

// block_entities_all: every entity of the world's loaded chunks (temp), in no
// order.
block_entities_all :: proc(w: ^World) -> []Entity_At {
	out := make([dynamic]Entity_At, context.temp_allocator)
	it: base.Pool_Iterator
	for c in base.pool_next(&w.chunks.chunks, &it) {
		if c.state != .Ready {continue}
		origin := game.chunk_origin(c.pos)
		for &e in c.block_entities {
			append(&out, Entity_At{origin + game.local_from_index(int(e.local)), &e})
		}
	}
	return out[:]
}

// entity_lifecycle: the block at p went from old to new, by cause: an entity
// the new state has and the old one lacked is made, one the new state lacks
// is removed (a container's stacks spill, those looking in are closed).
entity_lifecycle :: proc(w: ^World, p: game.Block_Pos, old, new: game.Block, cause: Act) {
	t := &w.server.registry.blocks
	was, now := game.block_entity_kind(t, old), game.block_entity_kind(t, new)
	if was == now {return}
	if was != .None {entity_removed(w, p, cause)}
	if now != .None {entity_made(w, p, now)}
}

@(private = "file")
entity_made :: proc(w: ^World, p: game.Block_Pos, kind: game.Block_Entity_Kind) {
	c := chunks_get(&w.chunks, game.chunk_of(p))
	if c == nil || c.state != .Ready {return}
	block_entity_touch(w, p)
	if c.block_entities.allocator.procedure == nil {c.block_entities.allocator = heap()}
	game.block_entity_insert(
		&c.block_entities,
		game.Block_Entity{local = u16(game.local_index(game.local_of(p))), kind = kind},
	)
}

@(private = "file")
entity_removed :: proc(w: ^World, p: game.Block_Pos, cause: Act) {
	e := block_entity_at(w, p)
	if e == nil {return}
	value := e^
	// The value stays with the journal, for undo and rollback.
	journal_entity(w, {p, u32(cause.action), age_of(w.server)}, &value)
	block_entity_touch(w, p)
	c := chunks_get(&w.chunks, game.chunk_of(p))
	at, _ := game.block_entity_find(c.block_entities[:], value.local)
	ordered_remove(&c.block_entities, at)
	if value.kind == .Container {container_gone(w, p, &value, cause)}
}

// journal_entity keeps the value of an entity a journal entry removed: in
// memory (the newest ENTITY_UNDO_MAX) and, with a save directory, in the
// segment files as an Entity record (journal_encode writes it).
@(private = "file")
journal_entity :: proc(w: ^World, key: Entity_Undo_Key, entity: ^game.Block_Entity) {
	j := &w.journal
	value := game.block_entity_pack(w.server.registry, entity, context.temp_allocator)
	if w.dir != "" {append(&j.pending_entities, Pending_Entity{key, slice.clone(value, heap())})}
	if j.entities == nil {j.entities = make(map[Entity_Undo_Key][]u8, heap())}
	if old, had := j.entities[key]; had {delete(old, heap())}
	j.entities[key] = slice.clone(value, heap())
	append(&j.entity_order, key)
	for len(j.entity_order) > ENTITY_UNDO_MAX {
		oldest := j.entity_order[0]
		ordered_remove(&j.entity_order, 0)
		if bytes, had := j.entities[oldest]; had {
			delete(bytes, heap())
			delete_key(&j.entities, oldest)
		}
	}
}

// journal_entity_value: what the entry (pos, action, age) removed.
journal_entity_value :: proc(w: ^World, key: Entity_Undo_Key) -> (value: []u8, ok: bool) {
	value, ok = w.journal.entities[key]
	return
}

journal_entities_free :: proc(j: ^Journal) {
	for p in j.pending_entities {delete(p.value, heap())}
	delete(j.pending_entities)
	for _, bytes in j.entities {delete(bytes, heap())}
	delete(j.entities)
	delete(j.entity_order)
}

// entities_reconcile: after a chunk came from its save, the one point where
// its entities and blocks are made to agree (entity_lifecycle keeps them so
// while the game runs; a damaged file or a pack that changed a block's entity
// kind can break it). An entity whose block's kind differs from its own is
// dropped and logged, what it held going out of the ledger as Orphaned (it was
// counted in by the chunk's Scope_In just before); a block whose kind needs an
// entity and has none gets an empty one.
entities_reconcile :: proc(w: ^World, c: ^Chunk) {
	s := w.server
	t := &s.registry.blocks
	origin := game.chunk_origin(c.pos)
	for i := len(c.block_entities) - 1; i >= 0; i -= 1 {
		e := &c.block_entities[i]
		b := game.chunk_get(&c.blocks, game.local_from_index(int(e.local)))
		if game.block_entity_kind(t, b) == e.kind {continue}
		p := origin + game.local_from_index(int(e.local))
		held := 0
		for st in e.slots {
			if game.stack_empty(st) {continue}
			held += st.count
			ledger_stack(s, w, .Orphaned, st, -1)
		}
		log.errorf(
			"server block entity without its block dropped pos=%v kind=%v items=%d",
			p,
			e.kind,
			held,
		)
		ordered_remove(&c.block_entities, i)
	}
	if c.blocks.array == nil && game.block_entity_kind(t, c.blocks.uniform) == .None {return}
	for local in 0 ..< game.CHUNK_VOLUME {
		b := game.chunk_get(&c.blocks, game.local_from_index(local))
		kind := game.block_entity_kind(t, b)
		if kind == .None {continue}
		if _, has := game.block_entity_find(c.block_entities[:], u16(local)); has {continue}
		if c.block_entities.allocator.procedure == nil {c.block_entities.allocator = heap()}
		game.block_entity_insert(
			&c.block_entities,
			game.Block_Entity{local = u16(local), kind = kind},
		)
		log.warnf(
			"server block entity made for its block pos=%v kind=%v",
			origin + game.local_from_index(local),
			kind,
		)
	}
}

// ledger_entities: what the entities hold comes into memory or leaves it.
ledger_entities :: proc(w: ^World, list: []game.Block_Entity, reason: game.Reason) {
	sign := 1 if reason == .Scope_In else -1
	for e in list {
		for st in e.slots {ledger_stack(w.server, w, reason, st, sign)}
	}
}

// RESTORE_REACH: how far from a broken container its spilled stacks are looked
// for when a rollback puts it back.
@(private = "file")
RESTORE_REACH :: 3.0

// entity_restore: a rollback put a block with an entity back at p, and its
// removal is the journal entry `from`: the entity gets what it held. What it
// spilled is on the ground still (the stacks carry the action that spilled
// them), and is taken back into it; what someone picked up meanwhile is theirs
// and stays so: items are moved, never made. Without a value (the journal
// forgot it, or the block never held one) the entity stays as made, empty.
entity_restore :: proc(
	w: ^World,
	p: game.Block_Pos,
	from: Entity_Undo_Key,
	disk: map[Entity_Undo_Key][]u8,
) {
	e := block_entity_at(w, p)
	if e == nil {return}
	bytes, found := journal_entity_value(w, from)
	if !found {bytes, found = disk[from]} 	// (what a rollback read from the segments)
	if !found {return}
	value: game.Block_Entity
	if !game.block_entity_unpack(w.server.registry, bytes, &value) || value.kind != e.kind {return}
	// What lies about of it: this action's stacks near p, per item.
	here := [3]f64{f64(p.x) + 0.5, f64(p.y) + 0.5, f64(p.z) + 0.5}
	lying := make(map[game.Item]int, context.temp_allocator)
	near :: proc(ent: ^Entity, here: [3]f64, action: u32) -> bool {
		d := ent.body.position - here
		return(
			ent.kind == .Item &&
			ent.action == action &&
			d.x * d.x + d.y * d.y + d.z * d.z <= RESTORE_REACH * RESTORE_REACH \
		)
	}
	for &ent in w.entities.list {
		if near(&ent, here, from.action) {lying[ent.stack.item] += ent.stack.count}
	}
	block_entity_touch(w, p)
	taken := make(map[game.Item]int, context.temp_allocator)
	for st, i in value.slots {
		if game.stack_empty(st) {continue}
		n := min(st.count, lying[st.item])
		lying[st.item] -= n
		taken[st.item] += n
		if n > 0 {e.slots[i] = {st.item, n}}
	}
	for i := len(w.entities.list) - 1; i >= 0; i -= 1 {
		ent := &w.entities.list[i]
		if !near(ent, here, from.action) {continue}
		n := min(ent.stack.count, taken[ent.stack.item])
		if n == 0 {continue}
		taken[ent.stack.item] -= n
		ent.stack.count -= n
		if ent.stack.count == 0 {entity_gone(w, i)}
	}
}
