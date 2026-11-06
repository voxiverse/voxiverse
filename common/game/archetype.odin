package game

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import "common:base"

// The archetype store (docs/design.md, entities v2): entities grouped by the
// set of components they have, one table per set with a column per component.
// A column is a virtual reservation committed in steps and never shrunk, so
// committed memory stops at the high-water mark; rows move only by
// swap-remove. Structural changes (spawn, despawn, add, remove) are deferred
// into a fixed ring and applied in issue order by store_apply, so a system
// iterating a query never sees a table change under it.
//
// Nothing here iterates a map: archetypes are in creation order, rows in row
// order (docs/determinism.md).

Component :: distinct u8 // 0 ..< 32
Component_Set :: bit_set[0 ..< 32;u32]

// Entity_Id is the id on the wire, in commands, logs and saves: from the
// store's next_id, never reused.
Entity_Id :: distinct u32

// Entity_Handle is a generation-checked handle into the store's slots.
Entity_Handle :: distinct u32

MAX_ARCHETYPES :: 64
MAX_COMPONENT_SIZE :: 64 // a deferred add carries the value in its command
ROWS_STEP :: 64 // rows committed at a time
NO_ARCHETYPE :: u16(max(u16)) // a spawn not applied yet

Component_Info :: struct {
	name:    string,
	type:    typeid,
	size:    int,
	align:   int,
	// release runs once for each value that leaves an entity (removed, the
	// entity despawned, the store destroyed): a component holding a handle
	// into a pool frees it here.
	release: proc(owner: rawptr, value: rawptr),
}

Store_Error :: enum u8 {
	None,
	Stale, // the handle is dead or its entity is already despawning
	Command_Ring_Full,
	Id_Exhausted,
	Pool_Full,
}

Store_Column :: struct {
	region:    []byte, // reserved
	committed: int, // bytes
	size:      int, // of one row
}

Archetype :: struct {
	set:     Component_Set,
	count:   int,
	ids:     Store_Column,
	columns: [32]Store_Column, // those in set
}

Entity_Slot :: struct {
	id:        Entity_Id,
	kind:      Kind_Id, // 0: none (a store used without kinds)
	archetype: u16,
	row:       u32,
	dying:     bool, // a despawn is queued
}

Store_Command_Kind :: enum u8 {
	Spawn,
	Despawn,
	Add,
	Remove,
}

Store_Command :: struct {
	kind:      Store_Command_Kind,
	component: Component,
	handle:    Entity_Handle,
	set:       Component_Set,
	value:     [MAX_COMPONENT_SIZE]u8,
}

Entity_Store :: struct {
	slots:      base.Pool(Entity_Slot, Entity_Handle),
	handles:    []Entity_Handle, // by_id: open addressing, power of two, lookup only
	archetypes: [MAX_ARCHETYPES]Archetype,
	narch:      int,
	by_set:     [MAX_ARCHETYPES * 2]struct {
		set:   Component_Set,
		index: u16, // + 1
	},
	commands:   []Store_Command, // ring
	cmd_head:   int,
	cmd_count:  int,
	next_id:    Entity_Id,
	infos:      []Component_Info,
	owner:      rawptr,
	max:        int,
	refused:    int, // commands apply could not carry out
	allocator:  mem.Allocator,
}

store_init :: proc(
	st: ^Entity_Store,
	infos: []Component_Info,
	owner: rawptr,
	max_entities: int,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	assert(len(infos) <= 32 && max_entities > 0)
	for info in infos {
		assert(info.size > 0 && info.size <= MAX_COMPONENT_SIZE, "component size out of range")
	}
	st^ = {
		infos     = infos,
		owner     = owner,
		max       = max_entities,
		next_id   = 1,
		allocator = allocator,
	}
	base.pool_init(&st.slots, max_entities, allocator) or_return
	table := 8
	for table < max_entities * 2 {table *= 2}
	st.handles = make([]Entity_Handle, table, allocator) or_return
	st.commands = make([]Store_Command, max_entities * 2, allocator) or_return
	return nil
}

store_destroy :: proc(st: ^Entity_Store) {
	for i in 0 ..< st.narch {
		a := &st.archetypes[i]
		for r in 0 ..< a.count {release_row(st, a, r, a.set)}
		release_column(&a.ids)
		for c in a.set {release_column(&a.columns[c])}
	}
	base.pool_destroy(&st.slots)
	delete(st.handles, st.allocator)
	delete(st.commands, st.allocator)
	st^ = {}
}

@(private = "file")
release_column :: proc(c: ^Store_Column) {
	if len(c.region) > 0 {virtual.release(raw_data(c.region), uint(len(c.region)))}
	c^ = {}
}

@(private = "file")
release_row :: proc(st: ^Entity_Store, a: ^Archetype, row: int, which: Component_Set) {
	for c in which {
		rel := st.infos[c].release
		if rel != nil {rel(st.owner, column_at(&a.columns[c], row))}
	}
}

@(private = "file")
column_at :: #force_inline proc(c: ^Store_Column, row: int) -> rawptr {
	return &c.region[row * c.size]
}

// column_grow makes room for `rows` rows, committing in steps of ROWS_STEP
// rows rounded up to whole 64 KiB.
@(private = "file")
column_grow :: proc(c: ^Store_Column, rows: int) -> bool {
	need := rows * c.size
	if need <= c.committed {return true}
	step := max(ROWS_STEP * c.size, need - c.committed)
	step = (step + 65535) &~ 65535
	step = min(step, len(c.region) - c.committed)
	if c.committed + step < need {return false}
	if virtual.commit(&c.region[c.committed], uint(step)) != nil {return false}
	c.committed += step
	return true
}

@(private = "file")
column_make :: proc(c: ^Store_Column, size, max_rows: int) -> bool {
	region, err := virtual.reserve(uint(size * max_rows))
	if err != nil {return false}
	c^ = {
		region = region,
		size   = size,
	}
	return true
}

@(private = "file")
set_hash :: proc(set: Component_Set) -> u32 {
	return transmute(u32)set * 2654435761
}

@(private = "file")
archetype_for :: proc(st: ^Entity_Store, set: Component_Set) -> (u16, bool) {
	n := len(st.by_set)
	h := int(set_hash(set) >> 7) % n
	for {
		e := &st.by_set[h]
		if e.index == 0 {break}
		if e.set == set {return e.index - 1, true}
		h = (h + 1) % n
	}
	if st.narch == MAX_ARCHETYPES {return 0, false}
	a := &st.archetypes[st.narch]
	a.set = set
	ok := column_make(&a.ids, size_of(Entity_Id), st.max)
	for c in set {ok = ok && column_make(&a.columns[c], st.infos[c].size, st.max)}
	if !ok {
		release_column(&a.ids)
		for c in set {release_column(&a.columns[c])}
		a^ = {}
		return 0, false
	}
	st.by_set[h] = {set, u16(st.narch) + 1}
	st.narch += 1
	return u16(st.narch - 1), true
}

// --- id table

@(private = "file")
id_slot :: proc(st: ^Entity_Store, id: Entity_Id) -> int {
	return int((u32(id) * 2654435761) >> 4) & (len(st.handles) - 1)
}

@(private = "file")
id_insert :: proc(st: ^Entity_Store, id: Entity_Id, h: Entity_Handle) {
	i := id_slot(st, id)
	for st.handles[i] != 0 {i = (i + 1) & (len(st.handles) - 1)}
	st.handles[i] = h
}

// id_remove must run while the entity's slot is still in the pool (the
// shift reads the ids of the entries after it).
@(private = "file")
id_remove :: proc(st: ^Entity_Store, id: Entity_Id) {
	mask := len(st.handles) - 1
	i := id_slot(st, id)
	for {
		h := st.handles[i]
		if h == 0 {return}
		if s := base.pool_get(&st.slots, h); s != nil && s.id == id {break}
		i = (i + 1) & mask
	}
	// backward-shift delete
	j := i
	for {
		st.handles[i] = 0
		for {
			j = (j + 1) & mask
			h := st.handles[j]
			if h == 0 {return}
			s := base.pool_get(&st.slots, h)
			home := id_slot(st, s.id)
			// the entry at j stays when its home lies cyclically in (i, j]
			stays := (i < home && home <= j) if i <= j else (i < home || home <= j)
			if !stays {break}
		}
		st.handles[i] = st.handles[j]
		i = j
	}
}

store_find :: proc(st: ^Entity_Store, id: Entity_Id) -> (Entity_Handle, bool) {
	if id == 0 {return 0, false}
	mask := len(st.handles) - 1
	i := id_slot(st, id)
	for {
		h := st.handles[i]
		if h == 0 {return 0, false}
		if s := base.pool_get(&st.slots, h); s != nil && s.id == id {return h, true}
		i = (i + 1) & mask
	}
}

// --- commands

@(private = "file")
push :: proc(st: ^Entity_Store, cmd: Store_Command) -> Store_Error {
	if st.cmd_count == len(st.commands) {return .Command_Ring_Full}
	st.commands[(st.cmd_head + st.cmd_count) % len(st.commands)] = cmd
	st.cmd_count += 1
	return .None
}

store_count :: proc(st: ^Entity_Store) -> int {
	return st.slots.count
}

// store_spawn queues an entity with the components in set, zeroed (queue
// store_add for values). The id and handle are good at once; the entity is
// seen by the first query after store_apply.
store_spawn :: proc(
	st: ^Entity_Store,
	set: Component_Set,
	kind: Kind_Id = 0,
) -> (
	id: Entity_Id,
	h: Entity_Handle,
	err: Store_Error,
) {
	return store_spawn_with_id(st, set, st.next_id, kind)
}

// store_spawn_with_id is a load's spawn (M50f): the id is the saved one and
// next_id moves past it.
store_spawn_with_id :: proc(
	st: ^Entity_Store,
	set: Component_Set,
	want: Entity_Id,
	kind: Kind_Id = 0,
) -> (
	id: Entity_Id,
	h: Entity_Handle,
	err: Store_Error,
) {
	if want == 0 || want == max(Entity_Id) {
		log.warn("entity ids exhausted: not spawning")
		return 0, 0, .Id_Exhausted
	}
	if st.cmd_count == len(st.commands) {return 0, 0, .Command_Ring_Full}
	if _, taken := store_find(st, want); taken {return 0, 0, .Stale}
	handle, _, ok := base.pool_add(
		&st.slots,
		Entity_Slot{id = want, kind = kind, archetype = NO_ARCHETYPE},
	)
	if !ok {return 0, 0, .Pool_Full}
	id_insert(st, want, handle)
	st.next_id = max(st.next_id, want + 1)
	push(st, Store_Command{kind = .Spawn, handle = handle, set = set})
	return want, handle, .None
}

// store_kind is the kind an entity was spawned with (0 when none, or the
// handle is stale).
store_kind :: proc(st: ^Entity_Store, h: Entity_Handle) -> Kind_Id {
	s := base.pool_get(&st.slots, h)
	return s == nil ? 0 : s.kind
}

store_despawn :: proc(st: ^Entity_Store, h: Entity_Handle) -> Store_Error {
	s := base.pool_get(&st.slots, h)
	if s == nil || s.dying {return .Stale}
	if err := push(st, Store_Command{kind = .Despawn, handle = h}); err != .None {return err}
	s.dying = true
	return .None
}

store_add :: proc(st: ^Entity_Store, h: Entity_Handle, c: Component, value: ^$T) -> Store_Error {
	s := base.pool_get(&st.slots, h)
	if s == nil || s.dying {return .Stale}
	info := st.infos[c]
	assert(info.type == T && size_of(T) == info.size, "component type mismatch")
	cmd := Store_Command {
		kind      = .Add,
		component = c,
		handle    = h,
	}
	mem.copy(&cmd.value, value, size_of(T))
	return push(st, cmd)
}

store_remove :: proc(st: ^Entity_Store, h: Entity_Handle, c: Component) -> Store_Error {
	s := base.pool_get(&st.slots, h)
	if s == nil || s.dying {return .Stale}
	return push(st, Store_Command{kind = .Remove, component = c, handle = h})
}

// store_get is the component's value, nil when the entity does not have it
// (or is not applied yet).
store_get :: proc(st: ^Entity_Store, h: Entity_Handle, c: Component, $T: typeid) -> ^T {
	s := base.pool_get(&st.slots, h)
	if s == nil || s.archetype == NO_ARCHETYPE {return nil}
	a := &st.archetypes[s.archetype]
	if int(c) not_in a.set {return nil}
	when ODIN_DEBUG {
		assert(st.infos[c].type == T, "component type mismatch")
	}
	return (^T)(column_at(&a.columns[c], int(s.row)))
}

@(private = "file")
append_row :: proc(st: ^Entity_Store, ai: u16, id: Entity_Id) -> (row: int, ok: bool) {
	a := &st.archetypes[ai]
	row = a.count
	ok = column_grow(&a.ids, row + 1)
	for c in a.set {ok = ok && column_grow(&a.columns[c], row + 1)}
	if !ok {return}
	(^Entity_Id)(column_at(&a.ids, row))^ = id
	for c in a.set {mem.zero(column_at(&a.columns[c], row), a.columns[c].size)}
	a.count += 1
	return
}

// drop_row swap-removes a row, fixing the slot of the entity moved into it.
@(private = "file")
drop_row :: proc(st: ^Entity_Store, ai: u16, row: int) {
	a := &st.archetypes[ai]
	last := a.count - 1
	if row != last {
		moved := (^Entity_Id)(column_at(&a.ids, last))^
		(^Entity_Id)(column_at(&a.ids, row))^ = moved
		for c in a.set {
			col := &a.columns[c]
			mem.copy(column_at(col, row), column_at(col, last), col.size)
		}
		if mh, ok := store_find(st, moved); ok {
			base.pool_get(&st.slots, mh).row = u32(row)
		}
	}
	a.count -= 1
}

// move_entity puts the applied entity into the archetype of `set`, keeping
// the components both have.
@(private = "file")
move_entity :: proc(st: ^Entity_Store, s: ^Entity_Slot, set: Component_Set) -> bool {
	ni, ok := archetype_for(st, set)
	if !ok {return false}
	if ni == s.archetype {return true}
	row, ok2 := append_row(st, ni, s.id)
	if !ok2 {return false}
	old := &st.archetypes[s.archetype]
	nw := &st.archetypes[ni]
	for c in old.set & set {
		mem.copy(
			column_at(&nw.columns[c], row),
			column_at(&old.columns[c], int(s.row)),
			old.columns[c].size,
		)
	}
	oi, orow := s.archetype, int(s.row)
	s.archetype = ni
	s.row = u32(row)
	drop_row(st, oi, orow)
	return true
}

store_apply :: proc(st: ^Entity_Store) {
	for st.cmd_count > 0 {
		cmd := st.commands[st.cmd_head]
		st.cmd_head = (st.cmd_head + 1) % len(st.commands)
		st.cmd_count -= 1
		s := base.pool_get(&st.slots, cmd.handle)
		if s == nil {continue}
		switch cmd.kind {
		case .Spawn:
			ai, ok := archetype_for(st, cmd.set)
			row := 0
			if ok {row, ok = append_row(st, ai, s.id)}
			if !ok {
				log.warnf("entity %d not spawned: archetype or memory limit", s.id)
				st.refused += 1
				id_remove(st, s.id)
				base.pool_remove(&st.slots, cmd.handle)
				continue
			}
			s.archetype = ai
			s.row = u32(row)
		case .Despawn:
			if s.archetype != NO_ARCHETYPE {
				a := &st.archetypes[s.archetype]
				release_row(st, a, int(s.row), a.set)
				drop_row(st, s.archetype, int(s.row))
			}
			id_remove(st, s.id)
			base.pool_remove(&st.slots, cmd.handle)
		case .Add:
			if s.archetype == NO_ARCHETYPE {continue}
			a := &st.archetypes[s.archetype]
			if int(cmd.component) not_in a.set {
				if !move_entity(st, s, a.set + {int(cmd.component)}) {
					log.warnf("component not added to entity %d: limit", s.id)
					st.refused += 1
					continue
				}
			} else {
				rel := st.infos[cmd.component].release
				if rel != nil {rel(st.owner, column_at(&a.columns[cmd.component], int(s.row)))}
			}
			a = &st.archetypes[s.archetype]
			col := &a.columns[cmd.component]
			value := cmd.value
			mem.copy(column_at(col, int(s.row)), &value, col.size)
		case .Remove:
			if s.archetype == NO_ARCHETYPE {continue}
			a := &st.archetypes[s.archetype]
			if int(cmd.component) not_in a.set {continue}
			rel := st.infos[cmd.component].release
			if rel != nil {rel(st.owner, column_at(&a.columns[cmd.component], int(s.row)))}
			if !move_entity(st, s, a.set - {int(cmd.component)}) {
				st.refused += 1
			}
		}
	}
}

// --- queries

Query_Iter :: struct {
	st:    ^Entity_Store,
	all:   Component_Set,
	none:  Component_Set,
	index: int,
}

store_query :: proc(
	st: ^Entity_Store,
	all: Component_Set,
	none: Component_Set = {},
) -> Query_Iter {
	return {st = st, all = all, none = none}
}

// query_next yields the archetypes with all of `all`, none of `none` and at
// least one row, in creation order.
query_next :: proc(it: ^Query_Iter) -> (a: ^Archetype, rows: int, ok: bool) {
	for it.index < it.st.narch {
		a = &it.st.archetypes[it.index]
		it.index += 1
		if a.count > 0 && it.all <= a.set && it.none & a.set == {} {
			return a, a.count, true
		}
	}
	return nil, 0, false
}

column :: proc(a: ^Archetype, c: Component, $T: typeid) -> []T {
	if int(c) not_in a.set {return nil}
	return ([^]T)(raw_data(a.columns[c].region))[:a.count]
}

archetype_ids :: proc(a: ^Archetype) -> []Entity_Id {
	return ([^]Entity_Id)(raw_data(a.ids.region))[:a.count]
}

store_committed_bytes :: proc(st: ^Entity_Store) -> int {
	total := 0
	for i in 0 ..< st.narch {
		a := &st.archetypes[i]
		total += a.ids.committed
		for c in a.set {total += a.columns[c].committed}
	}
	return total
}

// store_fold gives `fold` next_id, then per archetype its set and count, then
// each row's id and components in component order, each under the path
// `entities[archetype 2].<Component name>[5]` (the fold names fields below
// it). Row order is part of the state.
store_fold :: proc(st: ^Entity_Store, k: rawptr, fold: proc(k: rawptr, path: string, v: any)) {
	fold(k, "entities.next_id", st.next_id)
	for i in 0 ..< st.narch {
		a := &st.archetypes[i]
		fold(k, fmt.tprintf("entities[archetype %d].set", i), transmute(u32)a.set)
		fold(k, fmt.tprintf("entities[archetype %d].count", i), a.count)
		for id, r in archetype_ids(a) {
			fold(k, fmt.tprintf("entities[archetype %d].id[%d]", i, r), id)
			for c in a.set {
				info := st.infos[c]
				v := any{column_at(&a.columns[c], r), info.type}
				fold(k, fmt.tprintf("entities[archetype %d].%s[%d]", i, info.name, r), v)
			}
		}
	}
}

store_hash :: proc(st: ^Entity_Store, h: ^Hasher) {
	store_fold(st, h, proc(k: rawptr, path: string, v: any) {
		hash_value((^Hasher)(k), v, path)
	})
}
