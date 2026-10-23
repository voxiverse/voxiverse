package game

import "core:math"
import "core:math/rand"
import "core:testing"

@(private = "file")
encode_s :: proc(m: Server_Message, blocks: ^Chunk_Blocks = nil) -> [dynamic]u8 {
	w: Writer
	writer_init(&w, context.temp_allocator)
	encode_server(&w, m, blocks)
	return w.buf
}

@(private = "file")
encode_c :: proc(m: Client_Message) -> [dynamic]u8 {
	w: Writer
	writer_init(&w, context.temp_allocator)
	encode_client(&w, m)
	return w.buf
}

@(test)
test_messages_round_trip :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)

	hello, ok := decode_client(encode_c(Hello{PROTOCOL_VERSION, "Ünïcode name"})[:])
	testing.expect(t, ok)
	testing.expect_value(t, hello.(Hello).name, "Ünïcode name")
	move: Client_Message
	move, ok = decode_client(encode_c(Move{{1.5, -2e6, 3}})[:])
	testing.expect(t, ok && move.(Move).position == {1.5, -2e6, 3})

	welcome := Welcome{PROTOCOL_VERSION, TICK_RATE, {0, 40.5, 0}, 12}
	m: Server_Message
	m, ok = decode_server(encode_s(welcome)[:], scratch)
	testing.expect(t, ok && m.(Welcome) == welcome)
	m, ok = decode_server(encode_s(Reject{"full"})[:], scratch)
	testing.expect(t, ok && m.(Reject).reason == "full")
	m, ok = decode_server(encode_s(Unload_Chunk{{-5, 2, 1 << 20}})[:], scratch)
	testing.expect(t, ok && m.(Unload_Chunk).pos == {-5, 2, 1 << 20})
}

@(test)
test_chunk_round_trip :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	block_arrays_init(&arrays)
	defer block_arrays_destroy(&arrays)
	scratch := new(Block_Array)
	defer free(scratch)

	// Uniform.
	stone := Chunk_Blocks {
		uniform = .Stone,
	}
	m, ok := decode_server(encode_s(Chunk_Message{pos = {1, 2, 3}}, &stone)[:], scratch)
	c := m.(Chunk_Message)
	testing.expect(t, ok && c.is_uniform && c.uniform == .Stone && c.pos == {1, 2, 3})

	// Real terrain, and the worst case: every block differs from the last.
	terrain := Chunk_Blocks{}
	terrain.array, _ = block_arrays_take(&arrays)
	generate(9, {0, 0, 0}, terrain.array)
	worst := Chunk_Blocks{}
	worst.array, _ = block_arrays_take(&arrays)
	for &b, i in worst.array {b = Block(1 + i % (len(Block) - 1))}
	for blocks in ([]^Chunk_Blocks{&terrain, &worst}) {
		bytes := encode_s(Chunk_Message{pos = {0, -1, 0}}, blocks)
		testing.expect(t, len(bytes) <= MAX_MESSAGE_SIZE)
		m, ok = decode_server(bytes[:], scratch)
		c = m.(Chunk_Message)
		testing.expect(t, ok && !c.is_uniform && scratch^ == blocks.array^)
	}
	chunk_release(&terrain, &arrays)
	chunk_release(&worst, &arrays)
}

// Every proper prefix of a valid message is invalid.
@(test)
test_truncated_messages_fail :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)
	arrays: Block_Arrays
	block_arrays_init(&arrays)
	defer block_arrays_destroy(&arrays)
	terrain := Chunk_Blocks{}
	terrain.array, _ = block_arrays_take(&arrays)
	defer chunk_release(&terrain, &arrays)
	generate(9, {0, 0, 0}, terrain.array)

	server := [][dynamic]u8 {
		encode_s(Welcome{PROTOCOL_VERSION, TICK_RATE, {}, 8}),
		encode_s(Reject{"bye"}),
		encode_s(Chunk_Message{}, &terrain),
		encode_s(Unload_Chunk{}),
	}
	for bytes in server {
		for n in 0 ..< len(bytes) {
			_, ok := decode_server(bytes[:n], scratch)
			testing.expectf(t, !ok, "%d-byte prefix of a %d-byte message decoded", n, len(bytes))
		}
		// And one byte too many.
		longer := make([dynamic]u8, context.temp_allocator)
		append(&longer, ..bytes[:])
		append(&longer, 0)
		_, ok := decode_server(longer[:], scratch)
		testing.expect(t, !ok, "trailing byte accepted")
	}
	for bytes in ([][dynamic]u8{encode_c(Hello{1, "abc"}), encode_c(Move{})}) {
		for n in 0 ..< len(bytes) {
			_, ok := decode_client(bytes[:n])
			testing.expect(t, !ok)
		}
	}
}

@(test)
test_invalid_values_fail :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)

	bad_server :: proc(
		t: ^testing.T,
		scratch: ^Block_Array,
		what: string,
		build: proc(w: ^Writer),
	) {
		w: Writer
		writer_init(&w, context.temp_allocator)
		build(&w)
		_, ok := decode_server(w.buf[:], scratch)
		testing.expectf(t, !ok, "accepted: %s", what)
	}
	bad_client :: proc(t: ^testing.T, what: string, build: proc(w: ^Writer)) {
		w: Writer
		writer_init(&w, context.temp_allocator)
		build(&w)
		_, ok := decode_client(w.buf[:])
		testing.expectf(t, !ok, "accepted: %s", what)
	}

	bad_server(t, scratch, "empty message", proc(w: ^Writer) {})
	bad_server(t, scratch, "unknown kind", proc(w: ^Writer) {write_u8(w, 200)})
	bad_server(t, scratch, "kind 0", proc(w: ^Writer) {write_u8(w, 0)})
	bad_server(
		t,
		scratch,
		"chunk pos past the world limit",
		proc(w: ^Writer) {
			write_u8(w, 4) // Unload_Chunk
			write_i32(w, CHUNK_LIMIT)
			write_i32(w, 0)
			write_i32(w, 0)
		},
	)
	bad_server(t, scratch, "view radius too large", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_u32(w, TICK_RATE)
		for _ in 0 ..< 3 {write_f64(w, 0)}
		write_u32(w, MAX_VIEW_RADIUS + 1)
	})

	chunk_header :: proc(w: ^Writer) {
		write_u8(w, 3) // Chunk
		for _ in 0 ..< 3 {write_i32(w, 0)}
	}
	bad_server(t, scratch, "uniform chunk of an unknown block", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 0)
		write_u16(w, len(Block))
	})
	bad_server(t, scratch, "unknown chunk encoding", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 2)
	})
	bad_server(t, scratch, "empty palette", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 1)
		write_varint(w, 0)
	})
	bad_server(t, scratch, "palette of an unknown block", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 1)
		write_varint(w, 1)
		write_u16(w, 999)
		write_varint(w, CHUNK_VOLUME)
		write_varint(w, 0)
	})
	bad_server(t, scratch, "runs past the chunk", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 1)
		write_varint(w, 1)
		write_u16(w, 1)
		write_varint(w, CHUNK_VOLUME + 1)
		write_varint(w, 0)
	})
	bad_server(t, scratch, "runs short of the chunk", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 1)
		write_varint(w, 1)
		write_u16(w, 1)
		write_varint(w, CHUNK_VOLUME - 1)
		write_varint(w, 0)
	})
	bad_server(t, scratch, "zero-length run", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 1)
		write_varint(w, 1)
		write_u16(w, 1)
		write_varint(w, 0)
		write_varint(w, 0)
		write_varint(w, CHUNK_VOLUME)
		write_varint(w, 0)
	})
	bad_server(t, scratch, "palette index out of range", proc(w: ^Writer) {
		chunk_header(w)
		write_u8(w, 1)
		write_varint(w, 1)
		write_u16(w, 1)
		write_varint(w, CHUNK_VOLUME)
		write_varint(w, 1)
	})

	bad_client(t, "name too long", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_string(w, "a name that is far too long for anyone to need")
	})
	bad_client(t, "name not UTF-8", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_string(w, "\xff\xfe")
	})
	bad_client(t, "string length past the message", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_varint(w, 1 << 31)
	})
	bad_client(t, "NaN position", proc(w: ^Writer) {
		write_u8(w, 2)
		write_f64(w, math.nan_f64())
		write_f64(w, 0)
		write_f64(w, 0)
	})
	bad_client(t, "infinite position", proc(w: ^Writer) {
		write_u8(w, 2)
		write_f64(w, 0)
		write_f64(w, math.inf_f64(-1))
		write_f64(w, 0)
	})
	bad_client(t, "position past the world limit", proc(w: ^Writer) {
		write_u8(w, 2)
		write_f64(w, WORLD_LIMIT)
		write_f64(w, 0)
		write_f64(w, 0)
	})
}

@(test)
test_varint :: proc(t: ^testing.T) {
	for v in ([]u32{0, 1, 127, 128, 300, 1 << 21, max(u32)}) {
		w: Writer
		writer_init(&w, context.temp_allocator)
		write_varint(&w, v)
		r := reader_make(w.buf[:])
		testing.expect_value(t, read_varint(&r), v)
		testing.expect(t, reader_finish(&r))
	}
	bad := [][]u8 {
		{0x80, 0x00}, // overlong zero
		{0xff, 0x00}, // overlong 127
		{0xff, 0xff, 0xff, 0xff, 0x1f}, // 33 bits
		{0x80, 0x80, 0x80, 0x80, 0x80, 0x01}, // 6 bytes
		{0x80}, // truncated
	}
	for b in bad {
		r := reader_make(b)
		read_varint(&r)
		testing.expectf(t, !r.ok, "accepted varint %v", b)
	}
}

// Random bytes and random corruptions of valid messages: decoding must never
// crash (bounds checks would panic), whatever it decides.
@(test)
test_decode_fuzz :: proc(t: ^testing.T) {
	scratch := new(Block_Array)
	defer free(scratch)
	arrays: Block_Arrays
	block_arrays_init(&arrays)
	defer block_arrays_destroy(&arrays)
	terrain := Chunk_Blocks{}
	terrain.array, _ = block_arrays_take(&arrays)
	defer chunk_release(&terrain, &arrays)
	generate(3, {0, -1, 0}, terrain.array)
	valid := encode_s(Chunk_Message{}, &terrain)

	buf: [512]u8
	accepted := 0
	for _ in 0 ..< 20_000 {
		n := rand.int_max(len(buf))
		for &b in buf[:n] {b = u8(rand.uint32())}
		buf[0] = u8(rand.int_max(6))
		if _, ok := decode_server(buf[:n], scratch); ok {accepted += 1}
		if _, ok := decode_client(buf[:n]); ok {accepted += 1}
	}
	corrupt := make([]u8, len(valid), context.temp_allocator)
	for _ in 0 ..< 5_000 {
		copy(corrupt, valid[:])
		for _ in 0 ..< 1 + rand.int_max(4) {corrupt[rand.int_max(len(corrupt))] = u8(rand.uint32())}
		decode_server(corrupt, scratch)
	}
	testing.expect(t, accepted < 40_000)
}
