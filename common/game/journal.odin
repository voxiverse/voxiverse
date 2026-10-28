package game

import "core:hash"

// The edit journal's shared half (docs/journal.md): who and what changed a
// block (an actor and a system), the entries and actions the server keeps,
// and the segment file format, with its readers so tools can read journals.
// The server's side is server/journal.odin.

Actor_Kind :: enum u8 {
	World, // the world itself (natural water, random ticks, gates, grazing)
	Character, // a character, by name
	Script, // reserved for the sandbox (M52): a <pack>:<script> id
}

// Edit_System: the mechanism of a change. Append-only: values are written to disk.
Edit_System :: enum u8 {
	Hand, // break, place
	Till, // the hoe, and the moist farmland after it
	Command, // /fill, /replace, /sphere, /setblock
	Structure, // paste
	Explosion,
	Liquid,
	Random_Tick,
	Support, // a plant lost its footing
	Gate,
	Graze,
	Rollback,
	Undo,
	Redo,
}

MAX_ACTION_COMMAND :: 256 // bytes of the command text an action records
MAX_ACTOR_NAME :: 64
MAX_CHANGES_PER_RECORD :: 4096 // one chunk's blocks

// Action: one cause, with the actor and the system. id counts from 1 per
// world across restarts (0 is "none"); actor indexes the journal's actor
// table (0: the world); bypass: the actor may edit protected regions.
Journal_Action :: struct {
	id:      u32,
	age:     u64,
	actor:   u32,
	system:  Edit_System,
	bypass:  bool,
	command: string, // the full command text (Command, Structure, Rollback, Undo, Redo)
}

// Journal_Entry: one block changed. how is the mechanism of this change, which
// differs from its action's system for consequences (water poured by a
// /setblock flows as Liquid under the Command action).
Journal_Entry :: struct {
	pos:    Block_Pos,
	old:    Block,
	new:    Block,
	action: u32,
	how:    Edit_System,
	_:      [3]u8,
	age:    u64,
}
#assert(size_of(Journal_Entry) == 32)

// The segment file format (little-endian, varints as game.Writer):
//
//	header:  "VXJN" u32 format u32 seq u64 first_age u8 flags u32 crc32(header)
//	records: u8 type, varint length, payload, u32 crc32(type, length, payload)
JOURNAL_MAGIC :: "VXJN"
JOURNAL_FORMAT :: 1
JOURNAL_HEADER_SIZE :: 4 + 4 + 4 + 8 + 1 + 4
JOURNAL_COMPACTED :: u8(1) // header flag bit 0

Journal_Header :: struct {
	seq:       u32,
	first_age: u64,
	flags:     u8,
}

Journal_Record_Type :: enum u8 {
	Tick    = 1,
	Actor   = 2,
	Action  = 3,
	Changes = 4,
	Save    = 5,
	Params  = 6,
}

Journal_Tick :: struct {
	age:     u64,
	unix_ms: i64, // the wall clock: for people, never state
}

Journal_Actor :: struct {
	index: u32,
	kind:  Actor_Kind,
	name:  string,
}

// Journal_Change: one entry of a Changes record (its chunk is the record's).
Journal_Change :: struct {
	index:  u16, // local index in the chunk
	old:    Block,
	new:    Block,
	action: u32,
	how:    Edit_System,
}

Journal_Changes :: struct {
	chunk:   Chunk_Pos,
	changes: []Journal_Change,
}

Journal_Save :: struct {
	age: u64, // the world was saved here
}

Journal_Params :: struct {
	age: u64, // generator parameters changed here
}


Journal_Record :: union {
	Journal_Tick,
	Journal_Actor,
	Journal_Action,
	Journal_Changes,
	Journal_Save,
	Journal_Params,
}

journal_write_header :: proc(w: ^Writer, h: Journal_Header) {
	start := len(w.buf)
	append(&w.buf, JOURNAL_MAGIC)
	write_u32(w, JOURNAL_FORMAT)
	write_u32(w, h.seq)
	write_fixed64(w, h.first_age)
	write_u8(w, h.flags)
	write_u32(w, hash.crc32(w.buf[start:]))
}

write_fixed64 :: proc(w: ^Writer, v: u64) {
	write_u32(w, u32(v))
	write_u32(w, u32(v >> 32))
}

read_fixed64 :: proc(r: ^Reader) -> u64 {
	lo := u64(read_u32(r))
	return lo | u64(read_u32(r)) << 32
}

// journal_write_record appends one record. It returns false (nothing
// appended) for a value that would not read back: a name or command over its
// cap, a Changes record with none or too many.
journal_write_record :: proc(w: ^Writer, rec: Journal_Record) -> bool {
	payload := Writer {
		buf = make([dynamic]u8, 0, 64, context.temp_allocator),
	}
	type: Journal_Record_Type
	switch v in rec {
	case Journal_Tick:
		type = .Tick
		write_varint64(&payload, v.age)
		write_svarint64(&payload, v.unix_ms)
	case Journal_Actor:
		if len(v.name) > MAX_ACTOR_NAME {return false}
		type = .Actor
		write_varint(&payload, v.index)
		write_u8(&payload, u8(v.kind))
		write_string(&payload, v.name)
	case Journal_Action:
		if len(v.command) > MAX_ACTION_COMMAND {return false}
		type = .Action
		write_varint(&payload, v.id)
		write_varint(&payload, v.actor)
		write_u8(&payload, u8(v.system))
		write_varint64(&payload, v.age)
		write_u8(&payload, u8(v.bypass))
		write_string(&payload, v.command)
	case Journal_Changes:
		if len(v.changes) < 1 || len(v.changes) > MAX_CHANGES_PER_RECORD {return false}
		type = .Changes
		write_svarint(&payload, v.chunk.x)
		write_svarint(&payload, v.chunk.y)
		write_svarint(&payload, v.chunk.z)
		write_varint(&payload, u32(len(v.changes)))
		previous := i64(0)
		for c in v.changes {
			write_varint(&payload, u32(c.index))
			write_varint(&payload, u32(c.old))
			write_varint(&payload, u32(c.new))
			write_svarint64(&payload, i64(c.action) - previous)
			previous = i64(c.action)
			write_u8(&payload, u8(c.how))
		}
	case Journal_Save:
		type = .Save
		write_varint64(&payload, v.age)
	case Journal_Params:
		type = .Params
		write_varint64(&payload, v.age)
	}
	start := len(w.buf)
	write_u8(w, u8(type))
	write_varint(w, u32(len(payload.buf)))
	append(&w.buf, ..payload.buf[:])
	write_u32(w, hash.crc32(w.buf[start:]))
	return true
}

Segment_Status :: enum u8 {
	Whole, // every byte was a good record
	Torn, // stopped at valid_bytes: a short or damaged record
	Bad_Header, // not a segment (or from a newer format)
}

Segment_Read :: struct {
	header:      Journal_Header,
	valid_bytes: int, // the header and the good records
	status:      Segment_Status,
	records:     int,
}

// journal_read_segment checks the header and every record's CRC, calls visit
// with each good record, and stops at the first bad or short one (a torn
// tail). Strings and slices in a record are valid during the call only.
journal_read_segment :: proc(
	reg: ^Registry,
	data: []u8,
	visit: proc(user: rawptr, rec: Journal_Record),
	user: rawptr = nil,
) -> (
	result: Segment_Read,
) {
	if len(data) < JOURNAL_HEADER_SIZE || string(data[:4]) != JOURNAL_MAGIC {
		result.status = .Bad_Header
		return
	}
	hr := reader_make(data[4:JOURNAL_HEADER_SIZE])
	if read_u32(&hr) != JOURNAL_FORMAT {
		result.status = .Bad_Header
		return
	}
	result.header.seq = read_u32(&hr)
	result.header.first_age = read_fixed64(&hr)
	result.header.flags = read_u8(&hr)
	if read_u32(&hr) != hash.crc32(data[:JOURNAL_HEADER_SIZE - 4]) || !hr.ok {
		result = {
			status = .Bad_Header,
		}
		return
	}
	at := JOURNAL_HEADER_SIZE
	result.valid_bytes = at
	for at < len(data) {
		rest := Reader {
			data = data[at:],
			ok   = true,
		}
		type := read_u8(&rest)
		length := read_varint(&rest)
		if !rest.ok || int(length) > len(data) - at {break}
		body_at := rest.pos
		total := body_at + int(length) + 4
		if total > len(data) - at {break}
		record := data[at:][:body_at + int(length)]
		crc :=
			u32(data[at + total - 4]) |
			u32(data[at + total - 3]) << 8 |
			u32(data[at + total - 2]) << 16 |
			u32(data[at + total - 1]) << 24
		if hash.crc32(record) != crc {break}
		rec, ok := decode_record(reg, Journal_Record_Type(type), record[body_at:])
		if !ok {break}
		if visit != nil {visit(user, rec)}
		at += total
		result.valid_bytes = at
		result.records += 1
	}
	if result.valid_bytes != len(data) {result.status = .Torn}
	return
}

@(private = "file")
decode_record :: proc(
	reg: ^Registry,
	type: Journal_Record_Type,
	payload: []u8,
) -> (
	rec: Journal_Record,
	ok: bool,
) {
	r := reader_make(payload, reg)
	switch type {
	case .Tick:
		v: Journal_Tick
		v.age = read_varint64(&r)
		v.unix_ms = read_svarint64(&r)
		rec = v
	case .Actor:
		v: Journal_Actor
		v.index = read_varint(&r)
		kind := read_u8(&r)
		if kind >= len(Actor_Kind) {return}
		v.kind = Actor_Kind(kind)
		v.name = read_string(&r, MAX_ACTOR_NAME)
		rec = v
	case .Action:
		v: Journal_Action
		v.id = read_varint(&r)
		v.actor = read_varint(&r)
		system := read_u8(&r)
		if system >= len(Edit_System) {return}
		v.system = Edit_System(system)
		v.age = read_varint64(&r)
		bypass := read_u8(&r)
		if bypass > 1 {return}
		v.bypass = bypass == 1
		v.command = read_string(&r, MAX_ACTION_COMMAND)
		rec = v
	case .Changes:
		v: Journal_Changes
		v.chunk.x = read_svarint(&r)
		v.chunk.y = read_svarint(&r)
		v.chunk.z = read_svarint(&r)
		count := read_varint(&r)
		if !r.ok || count < 1 || count > MAX_CHANGES_PER_RECORD {return}
		v.changes = make([]Journal_Change, count, context.temp_allocator)
		previous := i64(0)
		for &c in v.changes {
			index := read_varint(&r)
			old, new := read_varint(&r), read_varint(&r)
			action := previous + read_svarint64(&r)
			how := read_u8(&r)
			if !r.ok ||
			   index >= CHUNK_VOLUME ||
			   old > 0xffff ||
			   new > 0xffff ||
			   !block_valid(&reg.blocks, u16(old)) ||
			   !block_valid(&reg.blocks, u16(new)) ||
			   action < 0 ||
			   action > i64(max(u32)) ||
			   how >= len(Edit_System) {return}
			previous = action
			c = {u16(index), Block(old), Block(new), u32(action), Edit_System(how)}
		}
		rec = v
	case .Save:
		rec = Journal_Save{read_varint64(&r)}
	case .Params:
		rec = Journal_Params{read_varint64(&r)}
	case:
		return
	}
	return rec, reader_finish(&r)
}

// entry_hash folds an entry into h (the journal's section of the state hash).
entry_hash :: proc "contextless" (h: ^Hasher, e: Journal_Entry) {
	hasher_mix(h, u64(u32(e.pos.x)) | u64(u32(e.pos.y)) << 32)
	hasher_mix(h, u64(u32(e.pos.z)) | u64(e.old) << 32 | u64(e.new) << 48)
	hasher_mix(h, u64(e.action) | u64(e.how) << 32)
	hasher_mix(h, e.age)
}
