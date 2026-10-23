package game

import "core:math"
import "core:math/rand"
import "core:testing"

import "../base"

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
	input := Player_Input{{0.5, -1}, 1.25, -0.5, {.Jump, .Sprint}}
	move, ok = decode_client(encode_c(Input{42, input})[:])
	got := move.(Input)
	testing.expect(t, ok && got.sequence == 42 && got.input == quantize_input(input))
	tp: Client_Message
	tp, ok = decode_client(encode_c(Teleport{{1.5, -2e6, 3}, 2, 0.5})[:])
	testing.expect(t, ok && tp.(Teleport) == Teleport{{1.5, -2e6, 3}, 2, 0.5})
	edit: Client_Message
	edit, ok = decode_client(encode_c(Edit{5, 9, {-3, WORLD_MIN_Y, 7}, .Sand})[:])
	testing.expect(t, ok && edit.(Edit) == Edit{5, 9, {-3, WORLD_MIN_Y, 7}, .Sand})
	result: Server_Message
	result, ok = decode_server(encode_s(Edit_Result{5, true, {1, 2, 3}, .Air})[:], scratch)
	testing.expect(t, ok && result.(Edit_Result) == Edit_Result{5, true, {1, 2, 3}, .Air})
	changed_block: Server_Message
	changed_block, ok = decode_server(encode_s(Block_Changed{{1, 2, 3}, .Gravel})[:], scratch)
	testing.expect(t, ok && changed_block.(Block_Changed) == Block_Changed{{1, 2, 3}, .Gravel})
	column := Column {
		pos = {-7, 12},
	}
	for &h, i in column.heights {h = i32(i % 37) - 20 if i != 5 else WORLD_MIN_Y}
	col: Server_Message
	col_bytes := encode_s(column)
	col, ok = decode_server(col_bytes[:], scratch)
	testing.expect(t, ok && col.(Column) == column)
	testing.expect(t, len(col_bytes) < 300) // deltas: about a byte per height
	rule: Client_Message
	rule, ok = decode_client(encode_c(Set_Rule{"rules.gravity", "20"})[:])
	testing.expect(
		t,
		ok && rule.(Set_Rule).name == "rules.gravity" && rule.(Set_Rule).value == "20",
	)
	state := Player_State{{1, 2, 3}, {4, -5, 6}, true, false}
	upd: Server_Message
	upd, ok = decode_server(encode_s(Player_Update{9, state, true, 1, -1})[:], scratch)
	testing.expect(t, ok && upd.(Player_Update) == Player_Update{9, state, true, 1, -1})
	changed := RULES_DEFAULTS
	changed.gravity, changed.allow_flying = 12.5, false
	rc: Server_Message
	rc, ok = decode_server(encode_s(Rules_Changed{changed})[:], scratch)
	testing.expect(t, ok && rc.(Rules_Changed).rules == changed)

	welcome := Welcome{PROTOCOL_VERSION, TICK_RATE, {0, 40.5, 0}, 12, 6, RULES_DEFAULTS}
	m: Server_Message
	m, ok = decode_server(encode_s(welcome)[:], scratch)
	testing.expect(t, ok && m.(Welcome) == welcome)
	m, ok = decode_server(encode_s(Reject{"full"})[:], scratch)
	testing.expect(t, ok && m.(Reject).reason == "full")
	ping: Client_Message
	ping, ok = decode_client(encode_c(Ping{77})[:])
	testing.expect(t, ok && ping.(Ping).id == 77)
	m, ok = decode_server(encode_s(Pong{78})[:], scratch)
	testing.expect(t, ok && m.(Pong).id == 78)
	m, ok = decode_server(encode_s(Unload_Chunk{{-5, CHUNK_MIN_Y, 1 << 20}})[:], scratch)
	testing.expect(t, ok && m.(Unload_Chunk).pos == {-5, CHUNK_MIN_Y, 1 << 20})
}

@(test)
test_chunk_round_trip :: proc(t: ^testing.T) {
	arrays: Block_Arrays
	testing.expect(t, block_arrays_init(&arrays, 16) == nil)
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
	testing.expect(t, block_arrays_init(&arrays, 16) == nil)
	defer block_arrays_destroy(&arrays)
	terrain := Chunk_Blocks{}
	terrain.array, _ = block_arrays_take(&arrays)
	defer chunk_release(&terrain, &arrays)
	generate(9, {0, 0, 0}, terrain.array)

	server := [][dynamic]u8 {
		encode_s(Welcome{PROTOCOL_VERSION, TICK_RATE, {}, 8, 4, RULES_DEFAULTS}),
		encode_s(Player_Update{1, {}, false, 0, 0}),
		encode_s(Rules_Changed{RULES_DEFAULTS}),
		encode_s(Edit_Result{1, false, {}, .Stone}),
		encode_s(Block_Changed{{}, .Dirt}),
		encode_s(Column{}),
		encode_s(Reject{"bye"}),
		encode_s(Chunk_Message{}, &terrain),
		encode_s(Unload_Chunk{}),
		encode_s(Pong{1}),
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
	for bytes in ([][dynamic]u8{encode_c(Hello{1, "abc"}), encode_c(Input{}), encode_c(Ping{3}), encode_c(Teleport{}), encode_c(Set_Rule{"a", "b"}), encode_c(Edit{1, 2, {}, .Stone})}) {
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
	bad_server(
		t,
		scratch,
		"chunk above the world",
		proc(w: ^Writer) {
			write_u8(w, 4) // Unload_Chunk
			write_i32(w, 0)
			write_i32(w, CHUNK_MAX_Y)
			write_i32(w, 0)
		},
	)
	bad_server(t, scratch, "view radius too large", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_u32(w, TICK_RATE)
		for _ in 0 ..< 3 {write_f64(w, 0)}
		write_u32(w, MAX_VIEW_RADIUS + 1)
		write_u32(w, 4)
		rules := RULES_DEFAULTS
		write_vars(w, rules_table(), &rules)
	})
	bad_server(t, scratch, "view height zero", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_u32(w, TICK_RATE)
		for _ in 0 ..< 3 {write_f64(w, 0)}
		write_u32(w, 8)
		write_u32(w, 0)
		rules := RULES_DEFAULTS
		write_vars(w, rules_table(), &rules)
	})
	bad_server(t, scratch, "view height too large", proc(w: ^Writer) {
		write_u8(w, 1)
		write_u32(w, PROTOCOL_VERSION)
		write_u32(w, TICK_RATE)
		for _ in 0 ..< 3 {write_f64(w, 0)}
		write_u32(w, 8)
		write_u32(w, MAX_VIEW_HEIGHT + 1)
		rules := RULES_DEFAULTS
		write_vars(w, rules_table(), &rules)
	})

	chunk_header :: proc(w: ^Writer) {
		write_u8(w, 3) // Chunk
		for _ in 0 ..< 3 {write_i32(w, 0)}
	}
	bad_server(
		t,
		scratch,
		"rules out of range",
		proc(w: ^Writer) {
			write_u8(w, 7) // Rules_Changed
			rules := RULES_DEFAULTS
			rules.gravity = 1e6
			for &v in RULES_VARS {
				kind, _ := base.var_kind(rules_table(), &v)
				value := base.var_get_f64(rules_table(), &rules, &v)
				switch kind {
				case .Bool:
					write_u8(w, 1 if value != 0 else 0)
				case .Int:
					write_i32(w, i32(value))
				case .F32:
					write_f32(w, f32(value))
				}
			}
		},
	)
	bad_server(
		t,
		scratch,
		"player speed absurd",
		proc(w: ^Writer) {
			write_u8(w, 6) // Player_Update
			write_u32(w, 1)
			for _ in 0 ..< 3 {write_f64(w, 0)}
			write_f32(w, 0)
			write_f32(w, MAX_SPEED * 2)
			write_f32(w, 0)
			write_u8(w, 0)
			write_u8(w, 0)
			write_f32(w, 0)
			write_f32(w, 0)
		},
	)
	bad_server(
		t,
		scratch,
		"column height above the world",
		proc(w: ^Writer) {
			write_u8(w, 10) // Column
			write_i32(w, 0)
			write_i32(w, 0)
			write_svarint(w, WORLD_MAX_Y)
			for _ in 1 ..< CHUNK_SIZE * CHUNK_SIZE {write_svarint(w, 0)}
		},
	)
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
	bad_client(
		t,
		"unknown input button",
		proc(w: ^Writer) {
			write_u8(w, 2) // Input
			write_u32(w, 1)
			write_u8(w, 0)
			write_u8(w, 0)
			write_f32(w, 0)
			write_f32(w, 0)
			write_u8(w, 0x80)
		},
	)
	bad_client(t, "input looking past straight up", proc(w: ^Writer) {
		write_u8(w, 2)
		write_u32(w, 1)
		write_u8(w, 0)
		write_u8(w, 0)
		write_f32(w, 0)
		write_f32(w, 2)
		write_u8(w, 0)
	})
	bad_client(t, "input with NaN yaw", proc(w: ^Writer) {
		write_u8(w, 2)
		write_u32(w, 1)
		write_u8(w, 0)
		write_u8(w, 0)
		write_f32(w, math.nan_f32())
		write_f32(w, 0)
		write_u8(w, 0)
	})
	bad_client(
		t,
		"edit above the world",
		proc(w: ^Writer) {
			write_u8(w, 6) // Edit
			write_u32(w, 1)
			write_i32(w, 0)
			write_i32(w, WORLD_MAX_Y)
			write_i32(w, 0)
			write_u16(w, u16(Block.Stone))
		},
	)
	bad_client(t, "edit with an unknown block", proc(w: ^Writer) {
		write_u8(w, 6)
		write_u32(w, 1)
		write_u32(w, 0)
		write_i32(w, 0)
		write_i32(w, 0)
		write_i32(w, 0)
		write_u16(w, 999)
	})
	bad_client(
		t,
		"NaN position",
		proc(w: ^Writer) {
			write_u8(w, 4) // Teleport
			write_f64(w, math.nan_f64())
			write_f64(w, 0)
			write_f64(w, 0)
			write_f32(w, 0)
			write_f32(w, 0)
		},
	)
	bad_client(
		t,
		"infinite position",
		proc(w: ^Writer) {
			write_u8(w, 4) // Teleport
			write_f64(w, 0)
			write_f64(w, math.inf_f64(-1))
			write_f64(w, 0)
			write_f32(w, 0)
			write_f32(w, 0)
		},
	)
	bad_client(
		t,
		"position past the world limit",
		proc(w: ^Writer) {
			write_u8(w, 4) // Teleport
			write_f64(w, WORLD_LIMIT)
			write_f64(w, 0)
			write_f64(w, 0)
			write_f32(w, 0)
			write_f32(w, 0)
		},
	)
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
	testing.expect(t, block_arrays_init(&arrays, 16) == nil)
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
