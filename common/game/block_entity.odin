package game

import "core:slice"

// Block entities (M48b): the data a block keeps beyond its state, a chest's
// stacks. A type says it has one (`"entity": {"kind": "container", "slots": 25}`);
// the kinds are the engine's. A chunk holds its entities sorted by `local`
// (the index of the block in the chunk), found by binary search.

Block_Entity :: struct {
	local: u16, // local_index of its block
	kind:  Block_Entity_Kind,
	slots: [CHEST_SLOTS]Stack, // a container's
}

// block_entity_kind: the entity kind a block has (None for most).
block_entity_kind :: proc(t: ^Block_Table, b: Block) -> Block_Entity_Kind {
	return t.types[t.type_of[b]].entity
}

// block_entity_find: the index of the entity with this local in a sorted
// list, or where it would go.
block_entity_find :: proc(list: []Block_Entity, local: u16) -> (at: int, found: bool) {
	at, found = slice.binary_search_by(
		list,
		local,
		proc(e: Block_Entity, l: u16) -> slice.Ordering {
			switch {
			case e.local < l:
				return .Less
			case e.local > l:
				return .Greater
			}
			return .Equal
		},
	)
	return
}

// block_entity_insert puts e in its place in a sorted list (replacing one at
// the same local).
block_entity_insert :: proc(list: ^[dynamic]Block_Entity, e: Block_Entity) {
	at, found := block_entity_find(list[:], e.local)
	if found {
		list[at] = e
	} else {
		inject_at(list, at, e)
	}
}

// MAX_BLOCK_ENTITIES: most a chunk may hold (one per block).
MAX_BLOCK_ENTITIES :: CHUNK_VOLUME

// write_block_entity: the value of one entity (without its local): the kind,
// then a container's non-empty slots as slot, item number and count. The item
// number is the registry's; a region file maps it by name (save.odin).
write_block_entity_value :: proc(w: ^Writer, e: ^Block_Entity) {
	write_u8(w, u8(e.kind))
	switch e.kind {
	case .None:
	case .Container:
		n := 0
		for st in e.slots {if !stack_empty(st) {n += 1}}
		write_varint(w, u32(n))
		for st, i in e.slots {
			if stack_empty(st) {continue}
			write_u8(w, u8(i))
			write_varint(w, u32(st.item))
			write_varint(w, u32(st.count))
		}
	}
}

// read_block_entity_value reads what write_block_entity_value wrote. Item
// numbers are checked by the reader's item map (a region's own table) or its
// registry; a bad value fails the reader.
read_block_entity_value :: proc(r: ^Reader, e: ^Block_Entity) {
	kind := read_u8(r)
	if kind == 0 || kind > u8(Block_Entity_Kind.Container) {
		reader_fail(r)
		return
	}
	e.kind = Block_Entity_Kind(kind)
	n := read_varint(r)
	if !r.ok || n > CHEST_SLOTS {
		reader_fail(r)
		return
	}
	last := -1
	for _ in 0 ..< n {
		slot := int(read_u8(r))
		number := read_varint(r)
		count := read_varint(r)
		if !r.ok || slot <= last || slot >= CHEST_SLOTS || number > 0xFFFF || count == 0 {
			reader_fail(r)
			return
		}
		last = slot
		item, valid := reader_item(r, u16(number))
		if !valid || count > 0xFFFF || int(count) > item_stack_size(r.reg, item) {
			reader_fail(r)
			return
		}
		e.slots[slot] = {item, int(count), 0}
	}
}

// reader_item: the item a saved number means here.
reader_item :: proc(r: ^Reader, number: u16) -> (Item, bool) {
	if r.items != nil {
		item, found := r.items[number]
		return item, found
	}
	return Item(number), r.reg != nil && item_valid(r.reg, Item(number))
}

// write_block_entities: a chunk's entities, after its blocks: varint count,
// then per entity u16 local and its value.
write_block_entities :: proc(w: ^Writer, list: []Block_Entity) {
	write_varint(w, u32(len(list)))
	for &e in list {
		write_u16(w, e.local)
		write_block_entity_value(w, &e)
	}
}

// read_block_entities reads what write_block_entities wrote, into out
// (appended). Locals must rise and be in the chunk.
read_block_entities :: proc(r: ^Reader, out: ^[dynamic]Block_Entity) {
	n := read_varint(r)
	if !r.ok || n > MAX_BLOCK_ENTITIES {
		reader_fail(r)
		return
	}
	previous := -1
	for _ in 0 ..< n {
		e: Block_Entity
		e.local = read_u16(r)
		if !r.ok || int(e.local) <= previous || int(e.local) >= CHUNK_VOLUME {
			reader_fail(r)
			return
		}
		previous = int(e.local)
		read_block_entity_value(r, &e)
		if !r.ok {return}
		append(out, e)
	}
}

// write_chunk_payload: a chunk as saved: its blocks, then its entities.
write_chunk_payload :: proc(w: ^Writer, c: ^Chunk_Blocks, entities: []Block_Entity) {
	write_chunk_blocks(w, c)
	write_block_entities(w, entities)
}

// read_chunk_payload reads what write_chunk_payload wrote (blocks as
// read_chunk_blocks; entities appended to out).
read_chunk_payload :: proc(
	r: ^Reader,
	dst: ^Block_Array,
	out: ^[dynamic]Block_Entity,
) -> (
	uniform: Block,
	is_uniform: bool,
) {
	uniform, is_uniform = read_chunk_blocks(r, dst)
	read_block_entities(r, out)
	return
}

// block_entity_pack: a value that reads back under any registry, for the
// journal (M48c): a table of the item ids its slots hold, then the value with
// each item as 1 + its place in the table.
block_entity_pack :: proc(
	reg: ^Registry,
	e: ^Block_Entity,
	allocator := context.allocator,
) -> []u8 {
	w: Writer
	writer_init(&w, allocator)
	table := make([dynamic]Item, context.temp_allocator)
	packed := e^
	for st, i in e.slots {
		if stack_empty(st) {continue}
		at := -1
		for item, k in table {if item == st.item {at = k}}
		if at < 0 {
			at = len(table)
			append(&table, st.item)
		}
		packed.slots[i].item = Item(at + 1) // (0 is no item: a stack of it is empty)
	}
	write_varint(&w, u32(len(table)))
	for item in table {write_string(&w, item_id(reg, item))}
	write_block_entity_value(&w, &packed)
	return w.buf[:]
}

// block_entity_unpack reads what block_entity_pack wrote. False: damaged, or
// it names an item this registry does not have.
block_entity_unpack :: proc(reg: ^Registry, bytes: []u8, e: ^Block_Entity) -> bool {
	r := reader_make(bytes, reg)
	n := read_varint(&r)
	if !r.ok || n > CHEST_SLOTS {return false}
	r.items = make(map[u16]Item, context.temp_allocator)
	for k in 0 ..< n {
		name := read_string(&r, 256)
		item, found := item_by_name(reg, name)
		if !r.ok || !found {return false}
		r.items[u16(k + 1)] = item
	}
	read_block_entity_value(&r, e)
	return reader_finish(&r)
}
