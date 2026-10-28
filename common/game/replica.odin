package game

import "core:mem"
import "core:slice"

// Replicas and the wire of the state model (M39). A Replica holds records of a
// schema's kinds, sorted by key. A Sender keeps what one receiver has been
// told and turns what the game puts this tick into State messages (the
// reliable lane: deltas against the last value sent) and Snapshot messages
// (the snapshot lane: deltas against the newest snapshot the receiver
// acknowledged, a ring of SNAPSHOT_RING). A Receiver decodes both into
// records and events. Nothing here knows a game type.

SNAPSHOT_RING :: 32 // snapshots kept as baselines (just over a second at 30 Hz)
SNAPSHOT_PARTS :: 8 // a snapshot is at most this many unreliable packets
SNAPSHOT_PART_BYTES :: 1150 // each at most this long (netcode.FRAGMENT_SIZE is 1176)
STATE_MESSAGE_BYTES :: MAX_MESSAGE_SIZE - 64
GROUP_HEADER_MAX :: 10

STATE_MESSAGE :: u8(36) // Server_Kind.State
SNAPSHOT_MESSAGE :: u8(37) // Server_Kind.Snapshot

// Key: an id in a, or a Block_Pos in a, b, c.
Key :: struct {
	a, b, c: i32,
}

Op :: enum u8 {
	Change, // wire op 0
	Create, // 1
	Remove, // 2
	Event, // (not on the wire as an op)
}

Record :: struct {
	key:     Key,
	value:   rawptr,
	waiting: u32, // snapshot lane: ticks a changed record has gone unsent
	touched: bool, // put since the last flush
}

Table :: struct {
	records: [dynamic]Record, // sorted by key (a loose table: in the order put)
}

Replica :: struct {
	schema:    ^Schema,
	tables:    []Table, // per state kind
	allocator: mem.Allocator,
}

key_block :: proc(k: Key) -> Block_Pos {return {k.a, k.b, k.c}}

key_of_block :: proc(p: Block_Pos) -> Key {return {p.x, p.y, p.z}}

chunk_less_xyz :: proc(a, b: Chunk_Pos) -> bool {
	if a.x != b.x {return a.x < b.x}
	if a.y != b.y {return a.y < b.y}
	return a.z < b.z
}

// key_less: the order records are sorted and written in. Blocks: by chunk,
// then local index (so a chunk's changes are together).
key_less :: proc(t: Key_Type, a, b: Key) -> bool {
	if t == .Block {
		pa, pb := key_block(a), key_block(b)
		ca, cb := chunk_of(pa), chunk_of(pb)
		if ca != cb {return chunk_less_xyz(ca, cb)}
		return local_index(local_of(pa)) < local_index(local_of(pb))
	}
	return u32(a.a) < u32(b.a)
}

replica_init :: proc(r: ^Replica, schema: ^Schema, allocator := context.allocator) {
	r.schema, r.allocator = schema, allocator
	r.tables = make([]Table, schema.n_states, allocator)
	for &t in r.tables {t.records = make([dynamic]Record, allocator)}
}

@(private)
value_alloc :: proc(k: ^Schema_Kind, allocator: mem.Allocator) -> rawptr {
	p, _ := mem.alloc(max(k.size, 8), 8, allocator)
	return p
}

@(private)
record_free :: proc(r: ^Replica, kind: int, rec: Record) {
	k := &r.schema.kinds[kind]
	value_free(k, rec.value)
	mem.free(rec.value, r.allocator)
}

replica_clear_kind :: proc(r: ^Replica, kind: int) {
	for rec in r.tables[kind].records {record_free(r, kind, rec)}
	clear(&r.tables[kind].records)
}

replica_clear :: proc(r: ^Replica) {
	for i in 0 ..< len(r.tables) {replica_clear_kind(r, i)}
}

replica_destroy :: proc(r: ^Replica) {
	if r.schema == nil {return}
	replica_clear(r)
	for &t in r.tables {delete(t.records)}
	delete(r.tables, r.allocator)
	r^ = {}
}

// replica_find: where the key is, or would be inserted.
replica_find :: proc(r: ^Replica, kind: int, key: Key) -> (index: int, found: bool) {
	k := &r.schema.kinds[kind]
	recs := r.tables[kind].records[:]
	lo, hi := 0, len(recs)
	for lo < hi {
		mid := (lo + hi) / 2
		if key_less(k.key, recs[mid].key, key) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(recs) && recs[lo].key == key
}

// replica_get: the record's value, or nil.
replica_get :: proc(r: ^Replica, kind: int, key: Key) -> rawptr {
	i, found := replica_find(r, kind, key)
	return r.tables[kind].records[i].value if found else nil
}

// replica_upsert sets the record's value to a copy of value.
replica_upsert :: proc(r: ^Replica, kind: int, key: Key, value: rawptr) -> ^Record {
	k := &r.schema.kinds[kind]
	i, found := replica_find(r, kind, key)
	if found {
		rec := &r.tables[kind].records[i]
		value_copy(k, rec.value, value)
		return rec
	}
	v := value_alloc(k, r.allocator)
	value_copy(k, v, value)
	inject_at(&r.tables[kind].records, i, Record{key = key, value = v})
	return &r.tables[kind].records[i]
}

// replica_insert adds a record holding a zeroed value (the caller fills it).
@(private)
replica_insert :: proc(r: ^Replica, kind: int, at: int, key: Key) -> ^Record {
	v := value_alloc(&r.schema.kinds[kind], r.allocator)
	inject_at(&r.tables[kind].records, at, Record{key = key, value = v})
	return &r.tables[kind].records[at]
}

replica_remove_at :: proc(r: ^Replica, kind: int, index: int) {
	record_free(r, kind, r.tables[kind].records[index])
	ordered_remove(&r.tables[kind].records, index)
}

// replica_copy_lane copies every record of the snapshot-lane kinds of src.
@(private)
replica_copy_snapshot :: proc(dst, src: ^Replica) {
	for kind in 0 ..< src.schema.n_states {
		if src.schema.kinds[kind].lane != .Snapshot {continue}
		for rec in src.tables[kind].records {
			replica_upsert(dst, kind, rec.key, rec.value)
		}
	}
}

// Ring_Entry: a snapshot as the receiver holds it once complete.
Ring_Entry :: struct {
	tick:  u32,
	valid: bool,
	data:  Replica,
}

Snapshot_Ring :: struct {
	slots: [SNAPSHOT_RING]Ring_Entry,
}

ring_destroy :: proc(ring: ^Snapshot_Ring) {
	for &s in ring.slots {
		replica_destroy(&s.data)
		s = {}
	}
}

ring_find :: proc(ring: ^Snapshot_Ring, tick: u32) -> ^Ring_Entry {
	s := &ring.slots[tick % SNAPSHOT_RING]
	return s if s.valid && s.tick == tick else nil
}

// ring_put stores a replica (taking it over) as snapshot tick.
@(private)
ring_put :: proc(ring: ^Snapshot_Ring, tick: u32, data: Replica) {
	s := &ring.slots[tick % SNAPSHOT_RING]
	replica_destroy(&s.data)
	s^ = {tick, true, data}
}

// ---- the wire ----

@(private)
write_key :: proc(w: ^Writer, t: Key_Type, key: Key, has_prev: bool, prev: Key) {
	switch t {
	case .None:
	case .Player, .Entity:
		base := u64(u32(prev.a)) if has_prev else 0
		write_varint64(w, u64(u32(key.a)) - base)
	case .Block:
		p := key_block(key)
		c := chunk_of(p)
		index := local_index(local_of(p))
		if has_prev && chunk_of(key_block(prev)) == c {
			write_varint(w, u32(index + 1))
		} else {
			write_varint(w, 0)
			write_svarint(w, c.x)
			write_svarint(w, c.y)
			write_svarint(w, c.z)
			write_varint(w, u32(index))
		}
	}
}

@(private)
read_key :: proc(r: ^Reader, t: Key_Type, has_prev: bool, prev: Key) -> (key: Key) {
	switch t {
	case .None:
	case .Player, .Entity:
		d := read_varint64(r)
		base := u64(u32(prev.a)) if has_prev else 0
		if has_prev && d == 0 {r.ok = false}
		v := base + d
		limit := u64(MAX_PLAYERS) if t == .Player else u64(max(u32)) + 1
		if v >= limit {r.ok = false}
		key.a = i32(u32(v))
	case .Block:
		head := read_varint(r)
		c: Chunk_Pos
		index: u32
		if head != 0 {
			if !has_prev {r.ok = false; return}
			c = chunk_of(key_block(prev))
			index = head - 1
			if has_prev && index <= u32(local_index(local_of(key_block(prev)))) {r.ok = false}
		} else {
			c = {read_svarint(r), read_svarint(r), read_svarint(r)}
			index = read_varint(r)
			if has_prev {
				pc := chunk_of(key_block(prev))
				if c == pc || !chunk_less_xyz(pc, c) {r.ok = false}
			}
			if !in_world(c) {r.ok = false}
		}
		if index >= CHUNK_VOLUME {r.ok = false}
		if r.ok {
			p := chunk_origin(c) + local_from_index(int(index))
			key = key_of_block(p)
		}
	}
	return
}

@(private)
write_entry :: proc(
	w: ^Writer,
	k: ^Schema_Kind,
	op: Op,
	mask: u64,
	key: Key,
	value, base: rawptr,
	has_prev: bool,
	prev: Key,
) {
	if op == .Event {
		for &f in k.fields {leaf_write(w, &f, leaf_at(&f, value))}
		return
	}
	head := u64(op)
	if op == .Change {head |= mask << 2}
	write_varint64(w, head)
	write_key(w, k.key, key, has_prev, prev)
	switch op {
	case .Create:
		for &f in k.fields {leaf_write(w, &f, leaf_at(&f, value))}
	case .Change:
		for &f, i in k.fields {
			if mask & (1 << uint(i)) !=
			   0 {leaf_write_delta(w, &f, leaf_at(&f, value), leaf_at(&f, base))}
		}
	case .Remove, .Event:
	}
}

// Group_Writer builds message bodies out of groups of entries, splitting at
// entry boundaries when a body would pass its limit.
@(private)
Group_Writer :: struct {
	schema:    ^Schema,
	limit:     int,
	bodies:    [dynamic][]u8,
	cur:       Writer,
	group:     Writer,
	id:        int, // the open group's kind (-1: none)
	section:   int,
	count:     int,
	prev:      Key,
	has_prev:  bool,
	allocator: mem.Allocator,
}

@(private)
gw_init :: proc(gw: ^Group_Writer, schema: ^Schema, limit: int, allocator: mem.Allocator) {
	gw^ = {
		schema    = schema,
		limit     = limit,
		bodies    = make([dynamic][]u8, allocator),
		id        = -1,
		allocator = allocator,
	}
	writer_init(&gw.cur, allocator, limit)
	writer_init(&gw.group, allocator, 256)
}

@(private)
gw_close_group :: proc(gw: ^Group_Writer) {
	if gw.id >= 0 && gw.count > 0 {
		write_varint(&gw.cur, u32(gw.id))
		write_varint(&gw.cur, u32(gw.count))
		append(&gw.cur.buf, ..gw.group.buf[:])
	}
	clear(&gw.group.buf)
	gw.id, gw.count, gw.has_prev = -1, 0, false
}

@(private)
gw_roll :: proc(gw: ^Group_Writer) {
	id, section := gw.id, gw.section
	gw_close_group(gw)
	body := make([]u8, len(gw.cur.buf), gw.allocator)
	copy(body, gw.cur.buf[:])
	append(&gw.bodies, body)
	clear(&gw.cur.buf)
	gw.id, gw.section = id, section
}

@(private)
gw_entry :: proc(
	gw: ^Group_Writer,
	id: int,
	section: int,
	op: Op,
	mask: u64,
	key: Key,
	value, base: rawptr,
) {
	k := &gw.schema.kinds[id]
	if gw.id != id || gw.section != section {
		gw_close_group(gw)
		gw.id, gw.section = id, section
	}
	ent: Writer
	writer_init(&ent, context.temp_allocator, 64)
	for attempt in 0 ..< 2 {
		clear(&ent.buf)
		write_entry(&ent, k, op, mask, key, value, base, gw.has_prev, gw.prev)
		fits := len(gw.cur.buf) + len(gw.group.buf) + len(ent.buf) + GROUP_HEADER_MAX <= gw.limit
		if fits || attempt == 1 || (len(gw.cur.buf) == 0 && gw.count == 0) {break}
		gw_roll(gw)
	}
	append(&gw.group.buf, ..ent.buf[:])
	gw.count += 1
	gw.prev, gw.has_prev = key, true
}

// gw_finish closes the open group and the last body; the bodies are the
// caller's (allocated with the writer's allocator).
@(private)
gw_finish :: proc(gw: ^Group_Writer) -> [dynamic][]u8 {
	gw_close_group(gw)
	if len(gw.cur.buf) > 0 {
		body := make([]u8, len(gw.cur.buf), gw.allocator)
		copy(body, gw.cur.buf[:])
		append(&gw.bodies, body)
	}
	delete(gw.cur.buf)
	delete(gw.group.buf)
	return gw.bodies
}

// ---- the sender ----

Pending_Event :: struct {
	kind:  int,
	value: rawptr,
}

Pending_Remove :: struct {
	kind: int,
	key:  Key,
}

Outgoing :: struct {
	data:     []u8,
	snapshot: bool, // else a State message (reliable)
}

// Sender: what one receiver has been told, and what the game has put since.
Sender :: struct {
	schema:  ^Schema,
	sent:    Replica, // reliable kinds: the values last sent
	cur:     Replica, // the game's puts (snapshot kinds keep theirs between ticks)
	removes: [dynamic]Pending_Remove,
	events:  [dynamic]Pending_Event,
	ring:    Snapshot_Ring, // snapshots as the receiver will hold them
	acked:   u32, // the newest snapshot the receiver says it holds (0: none)
}

sender_init :: proc(s: ^Sender, schema: ^Schema, allocator := context.allocator) {
	s^ = {
		schema  = schema,
		removes = make([dynamic]Pending_Remove, allocator),
		events  = make([dynamic]Pending_Event, allocator),
	}
	replica_init(&s.sent, schema, allocator)
	replica_init(&s.cur, schema, allocator)
}

sender_destroy :: proc(s: ^Sender) {
	if s.schema == nil {return}
	replica_destroy(&s.sent)
	replica_destroy(&s.cur)
	ring_destroy(&s.ring)
	delete(s.removes)
	for e in s.events {event_free(s.schema, e)}
	delete(s.events)
	s^ = {}
}

@(private)
event_free :: proc(schema: ^Schema, e: Pending_Event) {
	value_free(&schema.kinds[e.kind], e.value)
	mem.free(e.value)
}

// sender_reset forgets the keyed records the receiver holds (a new world:
// entity ids are per world): no removals are sent, and the next snapshot has no
// baseline. Singletons stay.
sender_reset :: proc(s: ^Sender) {
	for kind in 0 ..< s.schema.n_states {
		if s.schema.kinds[kind].key == .None {continue} 	// (a singleton persists)
		replica_clear_kind(&s.sent, kind)
		replica_clear_kind(&s.cur, kind)
	}
	clear(&s.removes)
	ring_destroy(&s.ring)
	s.acked = 0
}

// sender_put sets a record's value for this tick (the last put of a tick
// wins). A kind with keys is a view: a record not put in a tick is removed.
sender_put :: proc(s: ^Sender, kind: int, key: Key, value: rawptr) {
	k := &s.schema.kinds[kind]
	if k.write_through {
		v := value_alloc(k, s.cur.allocator)
		value_copy(k, v, value)
		append(&s.cur.tables[kind].records, Record{key = key, value = v, touched = true})
		return
	}
	rec := replica_upsert(&s.cur, kind, key, value)
	rec.touched = true
}

sender_remove :: proc(s: ^Sender, kind: int, key: Key) {
	append(&s.removes, Pending_Remove{kind, key})
}

sender_event :: proc(s: ^Sender, kind: int, value: rawptr) {
	k := &s.schema.kinds[kind]
	v := value_alloc(k, context.allocator)
	value_copy(k, v, value)
	append(&s.events, Pending_Event{kind, v})
}

// sender_seed gives the sender's copy of a reliable singleton a value the
// receiver already has by other means (so only changes travel).
sender_seed :: proc(s: ^Sender, kind: int, value: rawptr) {
	replica_upsert(&s.sent, kind, {}, value)
}

// receiver_seed gives the receiver's record the same value.
receiver_seed :: proc(rx: ^Receiver, kind: int, value: rawptr) {
	replica_upsert(&rx.live, kind, {}, value)
}

// sender_ack: the receiver holds snapshot tick (the highest wins).
sender_ack :: proc(s: ^Sender, tick: u32) {
	s.acked = max(s.acked, tick)
}

@(private)
Candidate :: struct {
	kind:     int,
	key:      Key,
	op:       Op,
	mask:     u64,
	waiting:  u32,
	priority: u8,
	distance: i64,
	index:    int, // in cur's table
	selected: bool,
	sent:     bool,
}

// sender_flush turns this tick's puts, events and removals into messages
// (appended to out, allocated with allocator): State messages for the reliable
// lane, Snapshot messages for the snapshot lane. origin: the receiver's
// position in whole blocks (nearer records go first when a snapshot is full).
sender_flush :: proc(
	s: ^Sender,
	tick: u32,
	origin: [3]i32,
	out: ^[dynamic]Outgoing,
	allocator := context.temp_allocator,
) {
	flush_reliable(s, tick, out, allocator)
	flush_snapshot(s, tick, origin, out, allocator)
	for &t in s.cur.tables {
		for &rec in t.records {rec.touched = false}
	}
}

@(private)
flush_reliable :: proc(s: ^Sender, tick: u32, out: ^[dynamic]Outgoing, allocator: mem.Allocator) {
	schema := s.schema
	gw: Group_Writer
	gw_init(&gw, schema, STATE_MESSAGE_BYTES - 16, allocator)
	removed := make([dynamic]Pending_Remove, context.temp_allocator)
	for kind in 0 ..< schema.n_states {
		k := &schema.kinds[kind]
		if k.lane != .Reliable {continue}
		table := &s.cur.tables[kind]
		if k.write_through {
			sort_loose(table.records[:], k.key)
			last := len(table.records) - 1
			for rec, i in table.records {
				if i < last && table.records[i + 1].key == rec.key {continue} 	// the last put wins
				gw_entry(&gw, kind, 0, .Create, value_all(k), rec.key, rec.value, nil)
			}
			for rec in table.records {
				value_free(k, rec.value)
				mem.free(rec.value, s.cur.allocator)
			}
			clear(&table.records)
			continue
		}
		for rec in table.records {
			if !rec.touched {continue}
			i, found := replica_find(&s.sent, kind, rec.key)
			if !found {
				gw_entry(&gw, kind, 0, .Create, value_all(k), rec.key, rec.value, nil)
				sr := replica_insert(&s.sent, kind, i, rec.key)
				value_copy(k, sr.value, rec.value)
				continue
			}
			sr := &s.sent.tables[kind].records[i]
			mask := value_diff(k, rec.value, sr.value)
			if mask == 0 {continue}
			gw_entry(&gw, kind, 0, .Change, mask, rec.key, rec.value, sr.value)
			value_copy(k, sr.value, rec.value)
		}
		// removals: a keyed kind's records not put, and what was removed by hand
		if k.key != .None {
			sent := &s.sent.tables[kind]
			for i := len(sent.records) - 1; i >= 0; i -= 1 {
				key := sent.records[i].key
				ci, in_cur := replica_find(&s.cur, kind, key)
				if in_cur && table.records[ci].touched {continue}
				inject_at(&removed, 0, Pending_Remove{kind, key})
				replica_remove_at(&s.sent, kind, i)
			}
		}
	}
	for rm in s.removes {
		k := &schema.kinds[rm.kind]
		if k.lane != .Reliable {continue}
		i, found := replica_find(&s.sent, rm.kind, rm.key)
		if !found {continue}
		replica_remove_at(&s.sent, rm.kind, i)
		append(&removed, rm)
	}
	sort_removes(schema, removed[:])
	for e in s.events {
		gw_entry(&gw, e.kind, 1, .Event, 0, {}, e.value, nil)
	}
	for rm in removed {
		gw_entry(&gw, rm.kind, 2, .Remove, 0, rm.key, nil, nil)
	}
	// keyed records not put are gone from the view; the rest wait for the next put
	for kind in 0 ..< schema.n_states {
		k := &schema.kinds[kind]
		if k.lane != .Reliable || k.key == .None {continue}
		recs := &s.cur.tables[kind].records
		for i := len(recs) - 1; i >= 0; i -= 1 {
			if !recs[i].touched {replica_remove_at(&s.cur, kind, i)}
		}
	}
	for e in s.events {event_free(schema, e)}
	clear(&s.events)
	// removes aimed at the snapshot lane are handled there
	bodies := gw_finish(&gw)
	for body in bodies {
		w: Writer
		writer_init(&w, allocator, len(body) + 8)
		write_u8(&w, STATE_MESSAGE)
		write_varint(&w, tick)
		append(&w.buf, ..body)
		append(out, Outgoing{w.buf[:], false})
	}
}

@(private)
sort_loose :: proc(recs: []Record, t: Key_Type) {
	// a stable insertion/merge sort by key (the order puts came in breaks ties)
	if len(recs) < 2 {return}
	tmp := make([]Record, len(recs), context.temp_allocator)
	merge_sort(recs, tmp, t)
}

@(private)
merge_sort :: proc(a, tmp: []Record, t: Key_Type) {
	n := len(a)
	if n < 2 {return}
	mid := n / 2
	merge_sort(a[:mid], tmp[:mid], t)
	merge_sort(a[mid:], tmp[mid:], t)
	i, j, k := 0, mid, 0
	for i < mid && j < n {
		if key_less(t, a[j].key, a[i].key) {
			tmp[k] = a[j]
			j += 1
		} else {
			tmp[k] = a[i]
			i += 1
		}
		k += 1
	}
	for i < mid {
		tmp[k] = a[i]
		i += 1
		k += 1
	}
	for j < n {
		tmp[k] = a[j]
		j += 1
		k += 1
	}
	copy(a, tmp[:n])
}

@(private)
sort_removes :: proc(schema: ^Schema, rms: []Pending_Remove) {
	// insertion sort by (kind, key): a handful at a time
	for i in 1 ..< len(rms) {
		j := i
		for j > 0 &&
		    (rms[j].kind < rms[j - 1].kind ||
				    (rms[j].kind == rms[j - 1].kind &&
						    key_less(schema.kinds[rms[j].kind].key, rms[j].key, rms[j - 1].key))) {
			rms[j], rms[j - 1] = rms[j - 1], rms[j]
			j -= 1
		}
	}
}

@(private)
flush_snapshot :: proc(
	s: ^Sender,
	tick: u32,
	origin: [3]i32,
	out: ^[dynamic]Outgoing,
	allocator: mem.Allocator,
) {
	schema := s.schema
	for rm in s.removes {
		if schema.kinds[rm.kind].lane != .Snapshot {continue}
		if i, found := replica_find(&s.cur, rm.kind, rm.key);
		   found {replica_remove_at(&s.cur, rm.kind, i)}
	}
	clear(&s.removes)
	for kind in 0 ..< schema.n_states {
		k := &schema.kinds[kind]
		if k.lane != .Snapshot || k.key == .None {continue}
		recs := &s.cur.tables[kind].records
		for i := len(recs) - 1; i >= 0; i -= 1 {
			if !recs[i].touched {replica_remove_at(&s.cur, kind, i)}
		}
	}
	base := ring_find(&s.ring, s.acked) if s.acked != 0 && s.acked < tick else nil
	back := tick - s.acked if base != nil else 0

	cands := make([dynamic]Candidate, context.temp_allocator)
	removed := make([dynamic]Pending_Remove, context.temp_allocator)
	for kind in 0 ..< schema.n_states {
		k := &schema.kinds[kind]
		if k.lane != .Snapshot {continue}
		for &rec, i in s.cur.tables[kind].records {
			c := Candidate {
				kind     = kind,
				key      = rec.key,
				op       = .Create,
				mask     = value_all(k),
				waiting  = rec.waiting,
				priority = k.priority,
				index    = i,
			}
			if base != nil {
				if bv := replica_get(&base.data, kind, rec.key); bv != nil {
					c.mask = value_diff(k, rec.value, bv)
					c.op = .Change
					if c.mask == 0 {
						rec.waiting = 0
						continue
					}
				}
			}
			if k.locate != nil {
				p := k.locate(rec.value)
				d := [3]i64{i64(p.x - origin.x), i64(p.y - origin.y), i64(p.z - origin.z)}
				c.distance = d.x * d.x + d.y * d.y + d.z * d.z
			}
			append(&cands, c)
		}
		if base != nil {
			for brec in base.data.tables[kind].records {
				if _, found := replica_find(&s.cur, kind, brec.key); !found {
					append(&removed, Pending_Remove{kind, brec.key})
				}
			}
		}
	}
	if len(cands) == 0 && len(removed) == 0 {return}

	// by priority: longest waiting, then kind priority, then nearest, then key
	order := make([]int, len(cands), context.temp_allocator)
	for i in 0 ..< len(order) {order[i] = i}
	cs := cands[:]
	sort_by_priority(schema, cs, order)
	budget := SNAPSHOT_PARTS * (SNAPSHOT_PART_BYTES - 200) - len(removed) * 12
	for oi in order {
		c := &cs[oi]
		k := &schema.kinds[c.kind]
		rec := &s.cur.tables[c.kind].records[c.index]
		est := estimate_entry(k, c.op, c.mask, rec.value)
		if est > budget {continue}
		budget -= est
		c.selected = true
	}

	// write the selected entries, grouped by kind in key order, into parts
	gw: Group_Writer
	gw_init(&gw, schema, SNAPSHOT_PART_BYTES - 16, allocator)
	next := 0
	for kind in 0 ..< schema.n_states {
		k := &schema.kinds[kind]
		if k.lane != .Snapshot {continue}
		for ; next < len(cs) && cs[next].kind == kind; next += 1 {
			c := &cs[next]
			if !c.selected {continue}
			rec := &s.cur.tables[kind].records[c.index]
			base_value: rawptr
			if c.op == .Change {base_value = replica_get(&base.data, kind, c.key)}
			gw_entry(&gw, kind, 0, c.op, c.mask, c.key, rec.value, base_value)
			c.sent = true
		}
	}
	for rm in removed {
		gw_entry(&gw, rm.kind, 2, .Remove, 0, rm.key, nil, nil)
	}
	bodies := gw_finish(&gw)
	assert(len(bodies) <= SNAPSHOT_PARTS, "a snapshot outgrew its parts")
	// what the receiver will hold if every part arrives
	fresh: Replica
	replica_init(&fresh, schema, context.allocator)
	if base != nil {replica_copy_snapshot(&fresh, &base.data)}
	for c in cs {
		rec := &s.cur.tables[c.kind].records[c.index]
		if c.sent {
			replica_upsert(&fresh, c.kind, c.key, rec.value)
			rec.waiting = 0
		} else {
			rec.waiting += 1
		}
	}
	for rm in removed {
		if i, found := replica_find(&fresh, rm.kind, rm.key); found {
			replica_remove_at(&fresh, rm.kind, i)
		}
	}
	ring_put(&s.ring, tick, fresh)
	for body, i in bodies {
		w: Writer
		writer_init(&w, allocator, len(body) + 16)
		write_u8(&w, SNAPSHOT_MESSAGE)
		write_varint(&w, tick)
		write_varint(&w, back)
		write_u8(&w, u8(i))
		write_u8(&w, u8(len(bodies)))
		append(&w.buf, ..body)
		append(out, Outgoing{w.buf[:], true})
	}
}

@(private)
sort_by_priority :: proc(schema: ^Schema, cs: []Candidate, order: []int) {
	// cs stays in (kind, key) order; order is sorted by priority
	Ctx :: struct {
		cs:     []Candidate,
		schema: ^Schema,
	}
	ctx := Ctx{cs, schema}
	context.user_ptr = &ctx
	slice.sort_by(order, proc(a, b: int) -> bool {
		ctx := (^Ctx)(context.user_ptr)
		x, y := ctx.cs[a], ctx.cs[b]
		if x.waiting != y.waiting {return x.waiting > y.waiting}
		if x.priority != y.priority {return x.priority < y.priority}
		if x.distance != y.distance {return x.distance < y.distance}
		if x.kind != y.kind {return x.kind < y.kind}
		return key_less(ctx.schema.kinds[x.kind].key, x.key, y.key)
	})
}

// estimate_entry: an upper bound of an entry's size.
@(private)
estimate_entry :: proc(k: ^Schema_Kind, op: Op, mask: u64, value: rawptr) -> int {
	w: Writer
	writer_init(&w, context.temp_allocator, 64)
	write_entry(&w, k, op, mask, {max(i32), max(i32), max(i32)}, value, value, false, {})
	return len(w.buf) + 5
}

// ---- the receiver ----

Received :: struct {
	kind:  int, // schema kind id (state kinds, then event kinds)
	op:    Op,
	key:   Key,
	value: rawptr, // valid until the next receive (nil for a removal)
	mask:  u64, // the fields a change names
}

@(private)
Gather :: struct {
	active: bool,
	tick:   u32,
	back:   u32,
	parts:  u8,
	seen:   u8,
	work:   Replica, // the baseline with this snapshot's parts applied
}

Receiver :: struct {
	schema:  ^Schema,
	live:    Replica, // reliable kinds
	ring:    Snapshot_Ring,
	ack:     u32, // the newest complete snapshot (0: none)
	newest:  u32, // the newest tick any part of was applied
	tick:    u32, // the last message's tick
	dropped: int, // snapshots whose baseline we lacked
	gather:  Gather,
	blobs:   [dynamic]rawptr,
	reg:     ^Registry, // what ids in values must be known to (blocks, items)
}

receiver_init :: proc(
	rx: ^Receiver,
	schema: ^Schema,
	reg: ^Registry,
	allocator := context.allocator,
) {
	rx^ = {
		schema = schema,
		reg    = reg,
		blobs  = make([dynamic]rawptr, allocator),
	}
	replica_init(&rx.live, schema, allocator)
}

receiver_destroy :: proc(rx: ^Receiver) {
	if rx.schema == nil {return}
	blobs_free(rx)
	delete(rx.blobs)
	replica_destroy(&rx.live)
	replica_destroy(&rx.gather.work)
	ring_destroy(&rx.ring)
	rx^ = {}
}

// receiver_reset drops the keyed records held and the snapshots (a new world).
receiver_reset :: proc(rx: ^Receiver) {
	blobs_free(rx)
	for kind in 0 ..< rx.schema.n_states {
		if rx.schema.kinds[kind].key != .None {replica_clear_kind(&rx.live, kind)}
	}
	replica_destroy(&rx.gather.work)
	rx.gather = {}
	ring_destroy(&rx.ring)
	rx.ack, rx.newest = 0, 0
}

@(private)
blobs_free :: proc(rx: ^Receiver) {
	for b in rx.blobs {mem.free(b)}
	clear(&rx.blobs)
}

@(private)
blob_make :: proc(rx: ^Receiver, k: ^Schema_Kind) -> rawptr {
	p := value_alloc(k, context.allocator)
	append(&rx.blobs, p)
	return p
}

@(private)
read_fields :: proc(r: ^Reader, k: ^Schema_Kind, value: rawptr, own: bool) -> bool {
	for &f in k.fields {
		if !leaf_read(r, &f, leaf_at(&f, value), own) {return false}
	}
	return true
}

@(private)
read_changes :: proc(r: ^Reader, k: ^Schema_Kind, mask: u64, value: rawptr, own: bool) -> bool {
	for &f, i in k.fields {
		if mask & (1 << uint(i)) == 0 {continue}
		if !leaf_read_delta(r, &f, leaf_at(&f, value), own) {return false}
	}
	return true
}

@(private)
valid_value :: proc(reg: ^Registry, k: ^Schema_Kind, value: rawptr) -> bool {
	return k.check == nil || k.check(reg, value)
}

// read_head: the op and mask of a record entry.
@(private)
read_head :: proc(r: ^Reader, k: ^Schema_Kind) -> (op: Op, mask: u64) {
	head := read_varint64(r)
	if !r.ok {return}
	switch head & 3 {
	case 0:
		op = .Change
	case 1:
		op = .Create
	case 2:
		op = .Remove
	case:
		r.ok = false
		return
	}
	mask = head >> 2
	if op == .Change {
		if mask == 0 || mask & ~value_all(k) != 0 {r.ok = false}
	} else if mask != 0 {
		r.ok = false
	}
	return
}

// receive_state decodes a State message into out (events and records); false
// if it is malformed (then the replica may be part-applied: drop the
// connection).
receive_state :: proc(rx: ^Receiver, data: []u8, out: ^[dynamic]Received) -> bool {
	blobs_free(rx)
	r := reader_make(data, rx.reg)
	if read_u8(&r) != STATE_MESSAGE {return false}
	rx.tick = read_varint(&r)
	for r.ok && r.pos < len(data) {
		id := int(read_varint(&r))
		count := int(read_varint(&r))
		if !r.ok ||
		   id >= len(rx.schema.kinds) ||
		   count < 1 ||
		   count > len(data) - r.pos {return false}
		k := &rx.schema.kinds[id]
		if k.lane == .Snapshot && !k.is_event {return false}
		prev_key: Key
		have := false
		for _ in 0 ..< count {
			if k.is_event {
				v := blob_make(rx, k)
				if !read_fields(&r, k, v, false) || !valid_value(rx.reg, k, v) {return false}
				append(out, Received{kind = id, op = .Event, value = v})
				continue
			}
			op, mask := read_head(&r, k)
			if !r.ok {return false}
			key := read_key(&r, k.key, have, prev_key)
			if !r.ok {return false}
			prev_key, have = key, true
			if k.write_through {
				if op != .Create {return false}
				v := blob_make(rx, k)
				if !read_fields(&r, k, v, false) || !valid_value(rx.reg, k, v) {return false}
				append(
					out,
					Received{kind = id, op = .Create, key = key, value = v, mask = value_all(k)},
				)
				continue
			}
			i, found := replica_find(&rx.live, id, key)
			switch op {
			case .Create:
				if found || len(rx.live.tables[id].records) >= k.max_records {return false}
				rec := replica_insert(&rx.live, id, i, key)
				if !read_fields(&r, k, rec.value, true) || !valid_value(rx.reg, k, rec.value) {
					replica_remove_at(&rx.live, id, i)
					return false
				}
				append(
					out,
					Received {
						kind = id,
						op = .Create,
						key = key,
						value = rec.value,
						mask = value_all(k),
					},
				)
			case .Change:
				if !found {return false}
				rec := &rx.live.tables[id].records[i]
				if !read_changes(&r, k, mask, rec.value, true) ||
				   !valid_value(rx.reg, k, rec.value) {return false}
				append(
					out,
					Received{kind = id, op = .Change, key = key, value = rec.value, mask = mask},
				)
			case .Remove:
				if !found {return false}
				replica_remove_at(&rx.live, id, i)
				append(out, Received{kind = id, op = .Remove, key = key})
			case .Event:
				return false
			}
		}
	}
	return r.ok
}

// receive_snapshot decodes one part of a Snapshot message into out. A part
// of an older snapshot than one already applied, or of one whose baseline is
// gone (counted in rx.dropped), yields nothing and is not an error.
receive_snapshot :: proc(rx: ^Receiver, data: []u8, out: ^[dynamic]Received) -> bool {
	blobs_free(rx)
	r := reader_make(data, rx.reg)
	if read_u8(&r) != SNAPSHOT_MESSAGE {return false}
	tick := read_varint(&r)
	back := read_varint(&r)
	part := read_u8(&r)
	parts := read_u8(&r)
	if !r.ok || parts < 1 || parts > SNAPSHOT_PARTS || part >= parts || back > tick || tick == 0 {
		return false
	}
	if tick <= rx.ack || tick < rx.newest {return true}
	g := &rx.gather
	if !g.active || g.tick != tick {
		held: ^Ring_Entry
		if back != 0 {
			held = ring_find(&rx.ring, tick - back)
			if held == nil {
				rx.dropped += 1
				return true
			}
		}
		replica_destroy(&g.work)
		replica_init(&g.work, rx.schema, context.allocator)
		if held != nil {replica_copy_snapshot(&g.work, &held.data)}
		g^ = {
			active = true,
			tick   = tick,
			back   = back,
			parts  = parts,
			work   = g.work,
		}
	} else if g.back != back || g.parts != parts {
		return false
	}
	if g.seen & (1 << part) != 0 {return true}
	rx.newest = tick
	for r.ok && r.pos < len(data) {
		id := int(read_varint(&r))
		count := int(read_varint(&r))
		if !r.ok ||
		   id >= rx.schema.n_states ||
		   count < 1 ||
		   count > len(data) - r.pos {return false}
		k := &rx.schema.kinds[id]
		if k.lane != .Snapshot {return false}
		prev_key: Key
		have := false
		for _ in 0 ..< count {
			op, mask := read_head(&r, k)
			if !r.ok {return false}
			key := read_key(&r, k.key, have, prev_key)
			if !r.ok {return false}
			prev_key, have = key, true
			i, found := replica_find(&g.work, id, key)
			switch op {
			case .Create:
				if found || len(g.work.tables[id].records) >= k.max_records {return false}
				rec := replica_insert(&g.work, id, i, key)
				if !read_fields(&r, k, rec.value, true) || !valid_value(rx.reg, k, rec.value) {
					replica_remove_at(&g.work, id, i)
					return false
				}
				append(
					out,
					Received {
						kind = id,
						op = .Create,
						key = key,
						value = rec.value,
						mask = value_all(k),
					},
				)
			case .Change:
				if !found {return false}
				rec := &g.work.tables[id].records[i]
				if !read_changes(&r, k, mask, rec.value, true) ||
				   !valid_value(rx.reg, k, rec.value) {return false}
				append(
					out,
					Received{kind = id, op = .Change, key = key, value = rec.value, mask = mask},
				)
			case .Remove:
				if !found {return false}
				replica_remove_at(&g.work, id, i)
				append(out, Received{kind = id, op = .Remove, key = key})
			case .Event:
				return false
			}
		}
	}
	if !r.ok {return false}
	g.seen |= 1 << part
	if u8(popcnt8(g.seen)) == g.parts {
		ring_put(&rx.ring, tick, g.work)
		g.work = {}
		g.active = false
		rx.ack = tick
	}
	rx.tick = tick
	return true
}

@(private)
popcnt8 :: proc(x: u8) -> int {
	n := 0
	for i in 0 ..< 8 {if x & (1 << uint(i)) != 0 {n += 1}}
	return n
}

// receiver_snapshot_get: the value of a snapshot-lane record as the newest
// snapshot (part-applied, or the last complete one) holds it, or nil.
receiver_snapshot_get :: proc(rx: ^Receiver, kind: int, key: Key) -> rawptr {
	if rx.gather.active {
		if v := replica_get(&rx.gather.work, kind, key); v != nil {return v}
	}
	if e := ring_find(&rx.ring, rx.ack); e != nil {return replica_get(&e.data, kind, key)}
	return nil
}

// scan_state sizes every entry of a State or Snapshot message without a
// replica: masks say which fields are present, so no baseline is needed to
// skip them. bytes and entries are per schema kind id.
scan_state :: proc(schema: ^Schema, data: []u8, bytes, entries: []int) -> bool {
	r := reader_make(data)
	kind := read_u8(&r)
	if kind != STATE_MESSAGE && kind != SNAPSHOT_MESSAGE {return false}
	read_varint(&r)
	if kind == SNAPSHOT_MESSAGE {
		read_varint(&r)
		read_u8(&r)
		read_u8(&r)
	}
	for r.ok && r.pos < len(data) {
		start := r.pos
		id := int(read_varint(&r))
		count := int(read_varint(&r))
		if !r.ok ||
		   id >= len(schema.kinds) ||
		   count < 1 ||
		   count > len(data) - r.pos {return false}
		k := &schema.kinds[id]
		prev_key: Key
		have := false
		for _ in 0 ..< count {
			scratch := value_alloc(k, context.temp_allocator)
			if k.is_event {
				if !read_fields(&r, k, scratch, false) {return false}
				continue
			}
			op, mask := read_head(&r, k)
			if !r.ok {return false}
			key := read_key(&r, k.key, have, prev_key)
			prev_key, have = key, true
			switch op {
			case .Create:
				if !read_fields(&r, k, scratch, false) {return false}
			case .Change:
				if !read_changes(&r, k, mask, scratch, false) {return false}
			case .Remove, .Event:
			}
		}
		if id < len(bytes) {bytes[id] += r.pos - start}
		if id < len(entries) {entries[id] += count}
	}
	return r.ok
}

// schema_kind_of: the kind id of a value type (-1: none).
schema_kind_of :: proc(s: ^Schema, value: typeid, events := false) -> int {
	for k in s.kinds {
		if k.value == value && k.is_event == events {return k.id}
	}
	return -1
}
