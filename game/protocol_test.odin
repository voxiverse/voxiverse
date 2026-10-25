package game

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
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

	account: Account
	account[0], account[31] = 7, 9
	hello, ok := decode_client(encode_c(Hello{PROTOCOL_VERSION, account, "Ünïcode name"})[:])
	testing.expect(t, ok)
	testing.expect_value(t, hello.(Hello).character, "Ünïcode name")
	testing.expect(t, hello.(Hello).account == account)
	sig: Signature
	sig[63] = 1
	proof: Client_Message
	proof, ok = decode_client(encode_c(Proof{sig})[:])
	testing.expect(t, ok && proof.(Proof).signature == sig)
	nonce: Nonce
	nonce[5] = 3
	challenge: Server_Message
	challenge, ok = decode_server(encode_s(Challenge{nonce})[:], scratch)
	testing.expect(t, ok && challenge.(Challenge).nonce == nonce)
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
	// A long command (bulk edits with far coordinates) fits; longer is invalid.
	long := "replace -2147483000 -2147483000 -2147483000 2147483000 2147483000 2147483000 gravel sand"
	admin: Client_Message
	admin, ok = decode_client(encode_c(Command{long})[:])
	testing.expect(t, ok && admin.(Command).command == long)
	too_long := strings.repeat("x", MAX_ADMIN_TEXT + 1, context.temp_allocator)
	_, ok = decode_client(encode_c(Command{too_long})[:])
	testing.expect(t, !ok)
	said: Client_Message
	said, ok = decode_client(encode_c(Chat{"&chello"})[:])
	testing.expect(t, ok && said.(Chat).text == "&chello")
	_, ok = decode_client(
		encode_c(Chat{strings.repeat("x", MAX_CHAT_TEXT + 1, context.temp_allocator)})[:],
	)
	testing.expect(t, !ok)
	state := Player_State{{1, 2, 3}, {4, -5, 6}, true, false}
	upd: Server_Message
	upd, ok = decode_server(encode_s(Player_Update{9, state, true, 1, -1})[:], scratch)
	testing.expect(t, ok && upd.(Player_Update) == Player_Update{9, state, true, 1, -1})
	changed := RULES_DEFAULTS
	changed.gravity, changed.allow_flying = 12.5, false
	rc: Server_Message
	rc, ok = decode_server(encode_s(Rules_Changed{changed})[:], scratch)
	testing.expect(t, ok && rc.(Rules_Changed).rules == changed)

	welcome := Welcome {
		PROTOCOL_VERSION,
		TICK_RATE,
		3,
		{0, 40.5, 0},
		12,
		6,
		RULES_DEFAULTS,
		address_derive(7),
	}
	moved: Server_Message
	moved, ok = decode_server(
		encode_s(World_Changed{address_derive(8), RULES_DEFAULTS})[:],
		scratch,
	)
	testing.expect(t, ok && moved.(World_Changed).address == address_derive(8))
	_, ok = decode_server(encode_s(World_Changed{{}, RULES_DEFAULTS})[:], scratch)
	testing.expect(t, !ok, "an address with a symbol twice")
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
	m, ok = decode_server(encode_s(Time{12345.678})[:], scratch)
	testing.expect(t, ok && m.(Time).time == 12345.678)
	m, ok = decode_server(encode_s(Player_Joined{7, "bob_the-builder"})[:], scratch)
	testing.expect(t, ok && m.(Player_Joined) == Player_Joined{7, "bob_the-builder"})
	m, ok = decode_server(encode_s(Player_Left{7})[:], scratch)
	testing.expect(t, ok && m.(Player_Left).player == 7)
	players := Players {
		tick  = 123,
		count = 2,
	}
	players.entries[0] = {4, {1.5, -60, 2e6}, 1, -0.5, true}
	players.entries[1] = {9, {0, 0, 0}, -3, 1.2, false}
	m, ok = decode_server(encode_s(players)[:], scratch)
	testing.expect(t, ok && m.(Players) == players)
	m, ok = decode_server(encode_s(Entity_Spawn{77, .Critter, {1, 2, 3}, 0.5, {}})[:], scratch)
	testing.expect(t, ok && m.(Entity_Spawn) == Entity_Spawn{77, .Critter, {1, 2, 3}, 0.5, {}})
	dropped := Entity_Spawn{78, .Item, {1, 2, 3}, 0, {item_of_block(.Sand), 12}}
	m, ok = decode_server(encode_s(dropped)[:], scratch)
	testing.expect(t, ok && m.(Entity_Spawn) == dropped)
	inv: Inventory
	inventory_add(&inv, {item_of_block(.Stone), 100})
	inv.cursor = {item_of_tool(.Launcher), 1}
	inv.selected = 3
	m, ok = decode_server(encode_s(Inventory_Update{5, inv})[:], scratch)
	testing.expect(t, ok && m.(Inventory_Update) == Inventory_Update{5, inv})
	bad := inv
	bad.slots[0].count = 65 // more than a stack
	_, ok = decode_server(encode_s(Inventory_Update{5, bad})[:], scratch)
	testing.expect(t, !ok)
	req := Inventory_Request{9, {.Swap_Hotbar, 20, 3}}
	asked: Client_Message
	asked, ok = decode_client(encode_c(req)[:])
	testing.expect(t, ok && asked.(Inventory_Request) == req)
	_, ok = decode_client(encode_c(Inventory_Request{9, {.Click, 40, 0}})[:])
	testing.expect(t, !ok)
	m, ok = decode_server(encode_s(Entity_Despawn{77, true})[:], scratch)
	testing.expect(t, ok && m.(Entity_Despawn) == Entity_Despawn{77, true})
	m, ok = decode_server(encode_s(Entity_Hurt{9})[:], scratch)
	testing.expect(t, ok && m.(Entity_Hurt).entity == 9)
	ents := Entities {
		tick  = 5,
		count = ENTITIES_PER_MESSAGE,
	}
	for &e, i in ents.entries {e = {u32(i), {f64(i), 64, -f64(i)}, f32(i) * 0.1, -0.2}}
	ents_bytes := encode_s(ents)
	testing.expectf(
		t,
		len(ents_bytes) <= 1150,
		"a full Entities is %d bytes: too big for a packet",
		len(ents_bytes),
	)
	m, ok = decode_server(ents_bytes[:], scratch)
	testing.expect(t, ok && m.(Entities) == ents)
	m, ok = decode_server(encode_s(Bulk_Begin{9})[:], scratch)
	testing.expect(t, ok && m.(Bulk_Begin).count == 9)
	m, ok = decode_server(encode_s(Explosion{{1, 2, 3}, 6})[:], scratch)
	testing.expect(t, ok && m.(Explosion) == Explosion{{1, 2, 3}, 6})
	m, ok = decode_server(encode_s(Explosion{{1, 2, 3}, 1000})[:], scratch)
	testing.expect(t, !ok, "an explosion of radius 1000 decoded")
	fire: Client_Message
	fire, ok = decode_client(encode_c(Fire{5, 1.5, -0.3})[:])
	testing.expect(t, ok && fire.(Fire) == Fire{5, 1.5, -0.3})
	at: Client_Message
	at, ok = decode_client(encode_c(Attack{12, 34})[:])
	testing.expect(t, ok && at.(Attack) == Attack{12, 34})
	batch := Blocks_Changed {
		chunk = {-2, 3, 4},
		count = 2,
	}
	batch.entries[0] = {7, .Water_3}
	batch.entries[1] = {4095, .Air}
	m, ok = decode_server(encode_s(batch)[:], scratch)
	testing.expect(t, ok && m.(Blocks_Changed) == batch)
	m, ok = decode_server(encode_s(Variables{"worldgen.sea_level = 4\n"})[:], scratch)
	testing.expect(t, ok && m.(Variables).text == "worldgen.sea_level = 4\n")
	m, ok = decode_server(encode_s(Grants{"1 chat.*\n0 -chat.format\n", "spawn mute"})[:], scratch)
	testing.expect(
		t,
		ok &&
		m.(Grants).text == "1 chat.*\n0 -chat.format\n" &&
		m.(Grants).commands == "spawn mute",
	)
	m, ok = decode_server(encode_s(Chat_Line{7, NO_PLAYER, "&eBea joined"})[:], scratch)
	testing.expect(t, ok && m.(Chat_Line).id == 7 && m.(Chat_Line).text == "&eBea joined")
	m, ok = decode_server(encode_s(Chat_Delete{7})[:], scratch)
	testing.expect(t, ok && m.(Chat_Delete).id == 7)
	m, ok = decode_server(encode_s(Notice{"Open to LAN on port 27315"})[:], scratch)
	testing.expect(t, ok && m.(Notice).text == "Open to LAN on port 27315")
	// Names: letters, digits, _ and -, 1..16 of them.
	m, ok = decode_server(encode_s(Player_Joined{1, "bad name"})[:], scratch)
	testing.expect(t, !ok, "a name with a space decoded")
	for name in ([]string{"a", "Player_1", "x-y", "0123456789abcdef"}) {testing.expectf(t, name_valid(name), "%q", name)}
	for name in ([]string{"", "with space", "0123456789abcdefg", "é", "a/b"}) {testing.expectf(t, !name_valid(name), "%q", name)}
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
	test_terrain(9, terrain.array)
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
	test_terrain(9, terrain.array)

	server := [][dynamic]u8 {
		encode_s(
			Welcome{PROTOCOL_VERSION, TICK_RATE, 1, {}, 8, 4, RULES_DEFAULTS, address_derive(1)},
		),
		encode_s(Player_Joined{2, "Alice"}),
		encode_s(Player_Left{2}),
		encode_s(Players{tick = 9, count = 1}),
		encode_s(Notice{"hello"}),
		encode_s(Entity_Spawn{1, .Critter, {}, 0, {}}),
		encode_s(Entity_Despawn{1, false}),
		encode_s(Entities{tick = 1, count = 1}),
		encode_s(Entity_Hurt{1}),
		encode_s(Bulk_Begin{1}),
		encode_s(Explosion{{}, 1}),
		encode_s(Player_Update{1, {}, false, 0, 0}),
		encode_s(Rules_Changed{RULES_DEFAULTS}),
		encode_s(Edit_Result{1, false, {}, .Stone}),
		encode_s(Block_Changed{{}, .Dirt}),
		encode_s(Column{}),
		encode_s(Reject{"bye"}),
		encode_s(Chunk_Message{}, &terrain),
		encode_s(Unload_Chunk{}),
		encode_s(Pong{1}),
		encode_s(Time{0.5}),
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
	for bytes in ([][dynamic]u8{encode_c(Hello{1, {}, "abc"}), encode_c(Input{}), encode_c(Ping{3}), encode_c(Teleport{}), encode_c(Set_Rule{"a", "b"}), encode_c(Edit{1, 2, {}, .Stone})}) {
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
				case .Text, .Enum:
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
	bad_server(
		t,
		scratch,
		"negative time",
		proc(w: ^Writer) {
			write_u8(w, 11) // Time
			write_f64(w, -1)
		},
	)
	bad_server(t, scratch, "time NaN", proc(w: ^Writer) {
		write_u8(w, 11)
		write_f64(w, transmute(f64)u64(0x7ff8000000000001))
	})
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
	test_terrain(3, terrain.array)
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

// The Wireshark dissector names message kinds as the game does (and knows
// every kind): tools/wireshark/voxiverse.lua.
@(test)
test_dissector_knows_every_kind :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(
		"tools/wireshark/voxiverse.lua",
		context.temp_allocator,
	)
	if !testing.expectf(t, err == nil, "cannot read the dissector: %v", err) {return}
	lua := string(data)
	for side in Side {
		table_name := "CLIENT_KINDS" if side == .Client else "SERVER_KINDS"
		start := strings.index(
			lua,
			strings.concatenate({"local ", table_name, " = {"}, context.temp_allocator),
		)
		if !testing.expectf(t, start >= 0, "%s missing", table_name) {continue}
		body := lua[start:]
		body = body[:strings.index_byte(body, '}')]
		for kind in 1 ..< 256 {
			name := message_kind_name(side, u8(kind))
			entry := fmt.tprintf("[%d] = %q", kind, name)
			if name == "" {
				testing.expectf(
					t,
					!strings.contains(body, fmt.tprintf("[%d] =", kind)),
					"%s has kind %d, the game does not",
					table_name,
					kind,
				)
			} else {
				testing.expectf(t, strings.contains(body, entry), "%s lacks %s", table_name, entry)
			}
		}
	}
}
