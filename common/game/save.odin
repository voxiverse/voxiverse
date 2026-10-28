package game

import "core:hash"
import "core:slice"

// Region files: the saved part of a world. A world is regenerated from its
// seed, so only chunks that were edited are stored, grouped by region
// (REGION_SIZE x REGION_SIZE chunk columns, the whole height), with the
// column tops edits changed. Chunks use the network encoding (palette +
// runs). Files end in a CRC-32 of everything before it, so damage is
// detected instead of loaded.
//
// Format 3 (older ones are refused: before 1.0 nothing is compatible): a header
// that indexes the chunks, each with its own CRC-32, so that damage to one
// chunk loses only that chunk, and names the blocks: the chunks hold block
// numbers, the header says which block each number was (its id), so a
// registry whose numbers moved (another pack set) still loads them.
//
// "VXRG", u32 format (3), i32 region x, z, varint64 generation (the save that
// wrote it), varint block count b, b x string id (number = position), varint
// chunk count n, the index (n x { i32 x, y, z, u32 offset,
// u32 length, u32 CRC-32 of the payload }, sorted by chunk_pos_less), varint
// top count, the tops (i32 x, z, top), u32 CRC-32 of everything above; then
// the payloads (each chunk's blocks, offset counted from here).

REGION_MAGIC :: "VXRG"
REGION_FORMAT :: 3
REGION_SIZE :: 16 // chunk columns per side
REGION_SHIFT :: 4

Region_Pos :: [2]i32

region_of :: proc(c: Chunk_Pos) -> Region_Pos {
	return {c.x >> REGION_SHIFT, c.z >> REGION_SHIFT}
}

Saved_Chunk :: struct {
	pos:    Chunk_Pos,
	blocks: ^Chunk_Blocks,
}

Saved_Top :: struct {
	x, z, top: i32,
}

// region_encode writes a region's edited chunks and tops into w, as the
// save of generation.
region_encode :: proc(
	reg: ^Registry,
	w: ^Writer,
	region: Region_Pos,
	chunks: []Saved_Chunk,
	tops: []Saved_Top,
	generation: u64 = 0,
) {
	encoded := make([]Encoded_Chunk, len(chunks), context.temp_allocator)
	scratch: Writer
	writer_init(&scratch, context.temp_allocator)
	for c, i in chunks {
		clear(&scratch.buf)
		write_chunk_blocks(&scratch, c.blocks)
		encoded[i] = {c.pos, slice.clone(scratch.buf[:], context.temp_allocator)}
	}
	region_encode_bytes(reg, w, region, encoded, tops, generation)
}

// Encoded_Chunk: a chunk's blocks as write_chunk_blocks wrote them.
Encoded_Chunk :: struct {
	pos:   Chunk_Pos,
	bytes: []u8,
}

// region_encode_bytes is region_encode for chunks already encoded (the save
// slices encode them a few at a time, the worker assembles the file).
region_encode_bytes :: proc(
	reg: ^Registry,
	w: ^Writer,
	region: Region_Pos,
	chunks: []Encoded_Chunk,
	tops: []Saved_Top,
	generation: u64 = 0,
) {
	sorted := make([]Encoded_Chunk, len(chunks), context.temp_allocator)
	copy(sorted, chunks)
	slice.sort_by(sorted, proc(a, b: Encoded_Chunk) -> bool {return chunk_pos_less(a.pos, b.pos)})
	payloads: Writer
	writer_init(&payloads, context.temp_allocator)
	Entry :: struct {
		offset, length, crc: u32,
	}
	entries := make([]Entry, len(sorted), context.temp_allocator)
	for c, i in sorted {
		assert(region_of(c.pos) == region)
		entries[i] = {u32(len(payloads.buf)), u32(len(c.bytes)), hash.crc32(c.bytes)}
		append(&payloads.buf, ..c.bytes)
	}
	clear(&w.buf)
	append(&w.buf, REGION_MAGIC)
	write_u32(w, REGION_FORMAT)
	write_i32(w, region.x)
	write_i32(w, region.y)
	write_varint64(w, generation)
	write_varint(w, u32(reg.blocks.count))
	for i in 0 ..< reg.blocks.count {write_string(w, state_text(reg, Block(i)))}
	write_varint(w, u32(len(sorted)))
	for c, i in sorted {
		for v in c.pos {write_i32(w, v)}
		write_u32(w, entries[i].offset)
		write_u32(w, entries[i].length)
		write_u32(w, entries[i].crc)
	}
	write_varint(w, u32(len(tops)))
	for t in tops {
		write_i32(w, t.x)
		write_i32(w, t.z)
		write_i32(w, t.top)
	}
	write_u32(w, hash.crc32(w.buf[:]))
	append(&w.buf, ..payloads.buf[:])
}

// Region_Reader walks a region file's chunks after region_open checked its
// header.
Region_Reader :: struct {
	reader:     Reader, // (its ok stays true: a damaged chunk is skipped, see dropped)
	region:     Region_Pos,
	generation: u64,
	index:      []Region_Index,
	remap:      []u16, // the saved number's block number here
	identity:   bool, // the numbers are as they were: nothing to remap
	unknown:    [dynamic]string, // saved blocks this registry lacks (temp allocator)
	next:       int,
	payloads:   []u8,
	tops:       [dynamic]Saved_Top, // (temp allocator)
	dropped:    [dynamic]Chunk_Pos, // chunks whose payload failed its check (temp allocator)
}

Region_Index :: struct {
	pos:                 Chunk_Pos,
	offset, length, crc: u32,
}

Region_Error :: enum u8 {
	None,
	Not_A_Region, // wrong magic
	Newer_Format, // written by a newer game
	Older_Format, // format 2 or less: there is no migration
	Damaged, // the header's checksum, truncation, bad values
	Wrong_Region, // the file says it is another region
	Unknown_Blocks, // it names blocks the registry lacks (r.unknown), and they are not to become air
}

// MAX_SAVED_BLOCK_NAME: the longest block id a region file may name.
MAX_SAVED_BLOCK_NAME :: 512

// region_open checks a region file's header (magic, format, checksum, region,
// index, tops). The chunks are checked as they are read.
// unknown_air: blocks the registry lacks become air (else: Unknown_Blocks).
region_open :: proc(
	reg: ^Registry,
	data: []u8,
	expect: Region_Pos,
	unknown_air := false,
) -> (
	r: Region_Reader,
	err: Region_Error,
) {
	if len(data) < 4 || string(data[:4]) != REGION_MAGIC {return {}, .Not_A_Region}
	if len(data) < 8 {return {}, .Damaged}
	r.reader = reader_make(data[4:], reg)
	format := read_u32(&r.reader)
	if format > REGION_FORMAT {return {}, .Newer_Format}
	if format < REGION_FORMAT {return {}, .Older_Format}
	r.region = {read_i32(&r.reader), read_i32(&r.reader)}
	r.generation = read_varint64(&r.reader)
	names := read_varint(&r.reader)
	if !r.reader.ok || names > MAX_BLOCK_STATES {return {}, .Damaged}
	r.remap = make([]u16, names, context.temp_allocator)
	r.unknown = make([dynamic]string, context.temp_allocator)
	r.identity = int(names) == reg.blocks.count
	for i in 0 ..< int(names) {
		name := read_string(&r.reader, MAX_SAVED_BLOCK_NAME)
		b, found := registry_block(reg, name)
		if found {
			r.remap[i] = u16(b)
			if int(b) != i {r.identity = false}
		} else {
			r.remap[i] = u16(Block.Air)
			r.identity = false
			append(&r.unknown, name)
		}
	}
	n := read_varint(&r.reader)
	max_chunks := REGION_SIZE * REGION_SIZE * (CHUNK_MAX_Y - CHUNK_MIN_Y)
	if !r.reader.ok || int(n) > max_chunks {return {}, .Damaged}
	r.index = make([]Region_Index, n, context.temp_allocator)
	for &e in r.index {
		for &v in e.pos {v = read_i32(&r.reader)}
		e.offset, e.length, e.crc = read_u32(&r.reader), read_u32(&r.reader), read_u32(&r.reader)
		if !in_world(e.pos) || region_of(e.pos) != r.region {reader_fail(&r.reader)}
	}
	t := read_varint(&r.reader)
	if !r.reader.ok || int(t) > REGION_SIZE * REGION_SIZE * CHUNK_SIZE * CHUNK_SIZE {
		return {}, .Damaged
	}
	r.tops = make([dynamic]Saved_Top, context.temp_allocator)
	r.dropped = make([dynamic]Chunk_Pos, context.temp_allocator)
	for _ in 0 ..< t {
		top := Saved_Top{read_i32(&r.reader), read_i32(&r.reader), read_i32(&r.reader)}
		if top.top < WORLD_MIN_Y ||
		   top.top >= WORLD_MAX_Y ||
		   region_of({top.x >> CHUNK_SHIFT, 0, top.z >> CHUNK_SHIFT}) != r.region {
			reader_fail(&r.reader)
		}
		append(&r.tops, top)
	}
	crc_at := 4 + r.reader.pos // (the reader began after the magic)
	crc := read_u32(&r.reader)
	if !r.reader.ok || crc != hash.crc32(data[:crc_at]) {return {}, .Damaged}
	r.payloads = data[crc_at + 4:]
	if r.region != expect {return {}, .Wrong_Region}
	r.reader.ok = true
	if len(r.unknown) > 0 && !unknown_air {return r, .Unknown_Blocks}
	return r, .None
}

// region_next_chunk reads the next chunk into dst (uniform chunks leave it
// untouched). A chunk that fails its checksum or does not decode is skipped
// (listed in r.dropped); got is false at the end.
region_next_chunk :: proc(
	r: ^Region_Reader,
	dst: ^Block_Array,
) -> (
	pos: Chunk_Pos,
	uniform: Block,
	is_uniform: bool,
	got: bool,
) {
	for r.next < len(r.index) {
		e := r.index[r.next]
		r.next += 1
		if int(e.offset) + int(e.length) > len(r.payloads) ||
		   int(e.offset) < 0 ||
		   hash.crc32(r.payloads[e.offset:][:e.length]) != e.crc {
			append(&r.dropped, e.pos)
			continue
		}
		cr := reader_make(r.payloads[e.offset:][:e.length])
		cr.block_limit = u32(len(r.remap))
		uniform, is_uniform = read_chunk_blocks(&cr, dst)
		if !reader_finish(&cr) {
			append(&r.dropped, e.pos)
			continue
		}
		if !r.identity {
			if is_uniform {
				uniform = Block(r.remap[uniform])
			} else {
				for &b in dst {b = Block(r.remap[b])}
			}
		}
		return e.pos, uniform, is_uniform, true
	}
	return
}

// region_tops appends the column tops.
region_tops :: proc(r: ^Region_Reader, out: ^[dynamic]Saved_Top) -> bool {
	append(out, ..r.tops[:])
	return true
}
