package game

import "core:hash"

// Region format 1, frozen: read only by the migration to format 2
// (server/migrate.odin), and by its tests, which write it with
// region_encode_v1. Never change it (docs/saves.md).
//
// File: "VXRG", u32 1, i32 region x, z, varint chunk count, per chunk (i32 x,
// y, z, then the chunk's blocks), varint top count, per top (i32 x, z, top),
// u32 CRC-32 of everything before it.

// region_encode_v1 writes a region's edited chunks and tops into w.
region_encode_v1 :: proc(w: ^Writer, region: Region_Pos, chunks: []Saved_Chunk, tops: []Saved_Top) {
	clear(&w.buf)
	append(&w.buf, REGION_MAGIC)
	write_u32(w, 1)
	write_i32(w, region.x)
	write_i32(w, region.y)
	write_varint(w, u32(len(chunks)))
	for c in chunks {
		assert(region_of(c.pos) == region)
		for v in c.pos {write_i32(w, v)}
		write_chunk_blocks(w, c.blocks)
	}
	write_varint(w, u32(len(tops)))
	for t in tops {
		write_i32(w, t.x)
		write_i32(w, t.z)
		write_i32(w, t.top)
	}
	write_u32(w, hash.crc32(w.buf[:]))
}

// Region_Reader_V1 walks a region file's contents after region_open_v1 checked it.
Region_Reader_V1 :: struct {
	reader: Reader,
	region: Region_Pos,
	chunks: int, // left to read
	tops:   int,
}


// region_open_v1 checks a region file (magic, format, checksum, region).
region_open_v1 :: proc(data: []u8, expect: Region_Pos) -> (r: Region_Reader_V1, err: Region_Error) {
	if len(data) < 4 || string(data[:4]) != REGION_MAGIC {return {}, .Not_A_Region}
	if len(data) < 8 + 4 {return {}, .Damaged}
	body := data[:len(data) - 4]
	tail := reader_make(data[len(data) - 4:])
	if read_u32(&tail) != hash.crc32(body) {return {}, .Damaged}
	r.reader = reader_make(body[4:])
	format := read_u32(&r.reader)
	if format > 1 {return {}, .Newer_Format}
	r.region = {read_i32(&r.reader), read_i32(&r.reader)}
	if r.region != expect {return {}, .Wrong_Region}
	n := read_varint(&r.reader)
	if !r.reader.ok ||
	   int(n) > REGION_SIZE * REGION_SIZE * (CHUNK_MAX_Y - CHUNK_MIN_Y) {return {}, .Damaged}
	r.chunks = int(n)
	return r, .None
}

// region_next_chunk_v1 reads the next chunk into dst (uniform chunks leave it
// untouched); ok is false at the end or on damage (then r.reader.ok is
// false too).
region_next_chunk_v1 :: proc(
	r: ^Region_Reader_V1,
	dst: ^Block_Array,
) -> (
	pos: Chunk_Pos,
	uniform: Block,
	is_uniform: bool,
	ok: bool,
) {
	if r.chunks == 0 {return}
	r.chunks -= 1
	for &v in pos {v = read_i32(&r.reader)}
	if !in_world(pos) || region_of(pos) != r.region {reader_fail(&r.reader)}
	uniform, is_uniform = read_chunk_blocks(&r.reader, dst)
	return pos, uniform, is_uniform, r.reader.ok
}

// region_tops_v1 reads the column tops (after all chunks); false on damage.
region_tops_v1 :: proc(r: ^Region_Reader_V1, out: ^[dynamic]Saved_Top) -> bool {
	if r.chunks != 0 {return false}
	n := read_varint(&r.reader)
	if !r.reader.ok || int(n) > REGION_SIZE * REGION_SIZE * CHUNK_SIZE * CHUNK_SIZE {return false}
	for _ in 0 ..< n {
		t := Saved_Top{read_i32(&r.reader), read_i32(&r.reader), read_i32(&r.reader)}
		if t.top < WORLD_MIN_Y ||
		   t.top >= WORLD_MAX_Y ||
		   region_of({t.x >> CHUNK_SHIFT, 0, t.z >> CHUNK_SHIFT}) != r.region {
			reader_fail(&r.reader)
		}
		if !r.reader.ok {return false}
		append(out, t)
	}
	return reader_finish(&r.reader)
}
