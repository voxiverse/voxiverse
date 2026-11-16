package game

import "core:slice"

// Block entities: the data a block keeps beyond its state, a chest's
// stacks. A type says it has one (`"entity": {"kind": "container", "slots": 25}`);
// the kinds are the engine's. A chunk holds its entities sorted by `local`
// (the index of the block in the chunk), found by binary search.
//
// A machine (`"entity": {"kind": "machine", "slots": n}`) is a game's block: its
// record (`data`, the game's own type as bytes, at most MAX_MACHINE_DATA), what
// players are shown of it (`shown`, at most MAX_MACHINE_SHOWN: sent to those who
// have its chunk), its first `slots` slots (its inventory) and the server's age
// (its persistent tick) at which it thinks next (`due`; 0: asleep). All of it is
// saved with the chunk.

MAX_MACHINE_DATA :: 64
MAX_MACHINE_SHOWN :: 16

Block_Entity :: struct {
	local: u16, // local_index of its block
	kind:  Block_Entity_Kind,
	slots: [CHEST_SLOTS]Stack, // a container's; a machine's first Type_Def.slots
	data:  [MAX_MACHINE_DATA]u8, // a machine's record (the game's type)
	shown: [MAX_MACHINE_SHOWN]u8, // what a machine shows (the game's type)
	due:   u64, // a machine's next think, in server age (0: none)
	lane:  Lane, // a belt's items (belt.odin)
}

// (a game's record is read in place as its type: aligned as any plain type may need)
#assert(offset_of(Block_Entity, data) % 8 == 0 && offset_of(Block_Entity, shown) % 8 == 0)

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
// then a container's or a machine's non-empty slots as slot, item number and
// count; a machine's then its record and what it shows (each a varint length
// and the bytes up to the last that is not zero) and its due age (varint
// split in two halves). The item number is the registry's; a region file maps
// it by name (save.odin).
write_block_entity_value :: proc(w: ^Writer, e: ^Block_Entity) {
	write_u8(w, u8(e.kind))
	switch e.kind {
	case .None:
	case .Container, .Machine:
		n := 0
		for st in e.slots {if !stack_empty(st) {n += 1}}
		write_varint(w, u32(n))
		for st, i in e.slots {
			if stack_empty(st) {continue}
			write_u8(w, u8(i))
			write_varint(w, u32(st.item))
			write_varint(w, u32(st.count))
		}
		if e.kind != .Machine {break}
		trimmed :: proc(b: []u8) -> []u8 {
			n := len(b)
			for n > 0 && b[n - 1] == 0 {n -= 1}
			return b[:n]
		}
		for bytes in ([2][]u8{trimmed(e.data[:]), trimmed(e.shown[:])}) {
			write_varint(w, u32(len(bytes)))
			for x in bytes {write_u8(w, x)}
		}
		write_varint(w, u32(e.due & 0xFFFF_FFFF))
		write_varint(w, u32(e.due >> 32))
	case .Belt:
		write_varint(w, u32(e.lane.count))
		for it in e.lane.items[:e.lane.count] {
			write_varint(w, u32(it.item))
			write_u16(w, it.at)
		}
	}
}

// read_block_entity_value reads what write_block_entity_value wrote. Item
// numbers are checked by the reader's item map (a region's own table) or its
// registry; a bad value fails the reader.
read_block_entity_value :: proc(r: ^Reader, e: ^Block_Entity) {
	kind := read_u8(r)
	if kind == 0 || kind > u8(max(Block_Entity_Kind)) {
		reader_fail(r)
		return
	}
	e.kind = Block_Entity_Kind(kind)
	if e.kind == .Belt {
		read_lane(r, &e.lane)
		return
	}
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
		e.slots[slot] = {item, int(count), 0, 0}
	}
	if e.kind != .Machine {return}
	for into in ([2][]u8{e.data[:], e.shown[:]}) {
		size := read_varint(r)
		if !r.ok || int(size) > len(into) {
			reader_fail(r)
			return
		}
		for i in 0 ..< int(size) {into[i] = read_u8(r)}
	}
	low := read_varint(r)
	high := read_varint(r)
	e.due = u64(high) << 32 | u64(low)
}

// read_lane reads a belt's items: at most LANE_ITEMS, each an item here, front first (each
// no further along than the one before it).
@(private = "file")
read_lane :: proc(r: ^Reader, l: ^Lane) {
	n := read_varint(r)
	if !r.ok || n > LANE_ITEMS {
		reader_fail(r)
		return
	}
	last := u32(LANE_END)
	for i in 0 ..< int(n) {
		number := read_varint(r)
		at := read_u16(r)
		item, valid := reader_item(r, u16(min(number, 0xFFFF)))
		if !r.ok || number > 0xFFFF || !valid || item == NO_ITEM || u32(at) > last {
			reader_fail(r)
			return
		}
		l.items[i] = {item, at}
		last = u32(at)
	}
	l.count = u8(n)
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

// Saved_Update: a scheduled update waiting in a saved chunk: the cell and how many ticks
// from the save it was due, so the simulation goes on across a save and load.
Saved_Update :: struct {
	local: u16, // the cell's local_index
	delta: u32, // ticks until due (0: due now)
}

// write_chunk_payload: a chunk as saved: its blocks, its entities, then its waiting updates
// (varint n, then per update varint local and varint delta, in the order given).
write_chunk_payload :: proc(
	w: ^Writer,
	c: ^Chunk_Blocks,
	entities: []Block_Entity,
	updates: []Saved_Update = nil,
	layers: []Saved_Channel = nil,
) {
	write_chunk_blocks(w, c)
	write_block_entities(w, entities)
	write_varint(w, u32(len(updates)))
	for u in updates {
		write_varint(w, u32(u.local))
		write_varint(w, u.delta)
	}
	write_layers(w, layers)
}

// read_chunk_payload reads what write_chunk_payload wrote (blocks as read_chunk_blocks;
// entities appended to out; updates appended to updates if given, else read and dropped).
read_chunk_payload :: proc(
	r: ^Reader,
	dst: ^Block_Array,
	out: ^[dynamic]Block_Entity,
	updates: ^[dynamic]Saved_Update = nil,
	layers: ^[dynamic]Saved_Channel = nil,
	unknown: ^[dynamic]string = nil,
) -> (
	uniform: Block,
	is_uniform: bool,
) {
	uniform, is_uniform = read_chunk_blocks(r, dst)
	read_block_entities(r, out)
	n := read_varint(r)
	if !r.ok {return}
	if n > CHUNK_VOLUME {
		reader_fail(r)
		return
	}
	for _ in 0 ..< n {
		local := read_varint(r)
		delta := read_varint(r)
		if !r.ok {return}
		if local >= CHUNK_VOLUME {
			reader_fail(r)
			return
		}
		if updates != nil {append(updates, Saved_Update{u16(local), delta})}
	}
	if layers != nil {
		read_layers(r, layers, unknown)
	} else {
		sink := make([dynamic]Saved_Channel, context.temp_allocator)
		read_layers(r, &sink, unknown)
	}
	return
}

// block_entity_pack: a value that reads back under any registry, for the
// journal: a table of the item ids its slots hold, then the value with
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
	number :: proc(table: ^[dynamic]Item, item: Item) -> Item {
		for x, k in table {if x == item {return Item(k + 1)}}
		append(table, item)
		return Item(len(table)) // (0 is no item: a stack of it is empty)
	}
	for st, i in e.slots {
		if stack_empty(st) {continue}
		packed.slots[i].item = number(&table, st.item)
	}
	for &it in packed.lane.items[:packed.lane.count] {it.item = number(&table, it.item)}
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
