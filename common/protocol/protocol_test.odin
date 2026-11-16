package protocol

import "common:access"
import "common:base"
import "common:game"
import "common:starmap"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
encode_s :: proc(m: Server_Message, blocks: ^game.Chunk_Blocks = nil) -> [dynamic]u8 {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	encode_server(&w, m, blocks)
	return w.buf
}

@(private = "file")
encode_c :: proc(m: Client_Message) -> [dynamic]u8 {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	encode_client(&w, m)
	return w.buf
}

@(test)
test_messages_round_trip :: proc(t: ^testing.T) {
	scratch := new(game.Block_Array)
	defer free(scratch)

	key: access.Account
	key[0], key[31] = 7, 9
	hello, ok := decode_client_t(
		encode_c(Hello{PROTOCOL_VERSION, key, "Ünïcode name", 0xfeed_beef_0123_4567, 0, nil})[:],
	)
	testing.expect(t, ok)
	testing.expect_value(t, hello.(Hello).character, "Ünïcode name")
	testing.expect(t, hello.(Hello).account == key)
	testing.expect_value(t, hello.(Hello).schema, u64(0xfeed_beef_0123_4567))
	sig: access.Signature
	sig[63] = 1
	proof: Client_Message
	proof, ok = decode_client_t(encode_c(Proof{sig})[:])
	testing.expect(t, ok && proof.(Proof).signature == sig)
	nonce: access.Nonce
	nonce[5] = 3
	challenge: Server_Message
	challenge, ok = decode_server_t(encode_s(Challenge{nonce})[:], scratch)
	testing.expect(t, ok && challenge.(Challenge).nonce == nonce)
	move: Client_Message
	input := game.Player_Input{{0.5, -1}, 1.25, -0.5, {.Jump, .Sprint}}
	move, ok = decode_client_t(encode_c(Input{42, input, 1 << 20})[:])
	got := move.(Input)
	testing.expect(t, ok && got.sequence == 42 && got.input == quantize_input(input))
	testing.expect_value(t, got.snapshot, u32(1 << 20))
	tp: Client_Message
	tp, ok = decode_client_t(encode_c(Teleport{{1.5, -2e6, 3}, 2, 0.5})[:])
	testing.expect(t, ok && tp.(Teleport) == Teleport{{1.5, -2e6, 3}, 2, 0.5})
	edit: Client_Message
	edit, ok = decode_client_t(encode_c(edit_plain(5, 9, {-3, game.WORLD_MIN_Y, 7}, .Sand))[:])
	testing.expect(t, ok && edit.(Edit) == edit_plain(5, 9, {-3, game.WORLD_MIN_Y, 7}, .Sand))
	placed := Edit{6, 10, {1, 2, 3}, game.Block(60), {1, 1, 3}, 2, {8, 16, 0}}
	edit, ok = decode_client_t(encode_c(placed)[:])
	testing.expect(t, ok && edit.(Edit) == placed)
	for bad in ([]Edit{{face = 8}, {hit = {17, 0, 0}}}) {
		_, ok = decode_client_t(encode_c(bad)[:])
		testing.expect(t, !ok)
	}
	result: Server_Message
	result, ok = decode_server_t(encode_s(Edit_Result{5, true, {1, 2, 3}, .Air, nil})[:], scratch)
	testing.expect(t, ok && result.(Edit_Result) == Edit_Result{5, true, {1, 2, 3}, .Air, nil})
	with_companion := Edit_Result{6, false, {1, 2, 3}, .Stone, Companion_Record{{1, 3, 3}, .Air}}
	result, ok = decode_server_t(encode_s(with_companion)[:], scratch)
	testing.expect(t, ok && result.(Edit_Result) == with_companion)
	column := Column {
		pos = {-7, 12},
	}
	for &h, i in column.heights {h = i32(i % 37) - 20 if i != 5 else game.WORLD_MIN_Y}
	col: Server_Message
	col_bytes := encode_s(column)
	col, ok = decode_server_t(col_bytes[:], scratch)
	testing.expect(t, ok && col.(Column) == column)
	testing.expect(t, len(col_bytes) < 300) // deltas: about a byte per height
	rule: Client_Message
	rule, ok = decode_client_t(encode_c(Set_Rule{"rules.gravity", "20"})[:])
	testing.expect(
		t,
		ok && rule.(Set_Rule).name == "rules.gravity" && rule.(Set_Rule).value == "20",
	)
	// A long command (bulk edits with far coordinates) fits; longer is invalid.
	long := "replace -2147483000 -2147483000 -2147483000 2147483000 2147483000 2147483000 gravel sand"
	admin: Client_Message
	admin, ok = decode_client_t(encode_c(Command{long})[:])
	testing.expect(t, ok && admin.(Command).command == long)
	too_long := strings.repeat("x", MAX_ADMIN_TEXT + 1, context.temp_allocator)
	_, ok = decode_client_t(encode_c(Command{too_long})[:])
	testing.expect(t, !ok)
	said: Client_Message
	said, ok = decode_client_t(encode_c(Chat{"&chello"})[:])
	testing.expect(t, ok && said.(Chat).text == "&chello")
	_, ok = decode_client_t(
		encode_c(Chat{strings.repeat("x", MAX_CHAT_TEXT + 1, context.temp_allocator)})[:],
	)
	testing.expect(t, !ok)
	welcome := Welcome {
		PROTOCOL_VERSION,
		game.TICK_RATE,
		3,
		{0, 40.5, 0},
		12,
		6,
		game.RULES_DEFAULTS,
		starmap.address_derive(7),
		0,
		"",
		"stopwatch",
		0xfeed_0123_4567_89ab,
	}
	moved: Server_Message
	moved, ok = decode_server_t(
		encode_s(World_Changed{starmap.address_derive(8), game.RULES_DEFAULTS})[:],
		scratch,
	)
	testing.expect(t, ok && moved.(World_Changed).address == starmap.address_derive(8))
	_, ok = decode_server_t(encode_s(World_Changed{{}, game.RULES_DEFAULTS})[:], scratch)
	testing.expect(t, !ok, "an address with a symbol twice")
	m: Server_Message
	m, ok = decode_server_t(encode_s(welcome)[:], scratch)
	testing.expect(t, ok && m.(Welcome) == welcome)
	// The game's id is a folder name of games/, checked at the edge; there is always one.
	for bad in ([]string{"", "Stopwatch", "_tag", "9lives", "tag/client", "a b"}) {
		odd := welcome
		odd.game = bad
		_, ok = decode_server_t(encode_s(odd)[:], scratch)
		testing.expectf(t, !ok, "the game id %q was let through", bad)
	}
	m, ok = decode_server_t(encode_s(Reject{"full"})[:], scratch)
	testing.expect(t, ok && m.(Reject).reason == "full")
	ping: Client_Message
	ping, ok = decode_client_t(encode_c(Ping{77})[:])
	testing.expect(t, ok && ping.(Ping).id == 77)
	m, ok = decode_server_t(encode_s(Pong{78})[:], scratch)
	testing.expect(t, ok && m.(Pong).id == 78)
	m, ok = decode_server_t(encode_s(Unload_Chunk{{-5, game.CHUNK_MIN_Y, 1 << 20}})[:], scratch)
	testing.expect(t, ok && m.(Unload_Chunk).pos == {-5, game.CHUNK_MIN_Y, 1 << 20})
	req := Inventory_Request{9, {.Swap_Hotbar, 20, 3}}
	asked: Client_Message
	asked, ok = decode_client_t(encode_c(req)[:])
	testing.expect(t, ok && asked.(Inventory_Request) == req)
	_, ok = decode_client_t(encode_c(Inventory_Request{9, {.Click, game.ALL_SLOTS, 0}})[:])
	testing.expect(t, !ok)
	m, ok = decode_server_t(encode_s(Bulk_Begin{9})[:], scratch)
	testing.expect(t, ok && m.(Bulk_Begin).count == 9)
	fire: Client_Message
	fire, ok = decode_client_t(encode_c(Fire{5, 1.5, -0.3})[:])
	testing.expect(t, ok && fire.(Fire) == Fire{5, 1.5, -0.3})
	shoot: Client_Message
	shoot, ok = decode_client_t(encode_c(Shoot{5, 2, true, 1.5, -0.3})[:])
	testing.expect(t, ok && shoot.(Shoot) == Shoot{5, 2, true, 1.5, -0.3})
	_, ok = decode_client_t(encode_c(Shoot{5, 9, true, 1.5, 0})[:]) // (no such hotbar slot)
	testing.expect(t, !ok)
	_, ok = decode_client_t(encode_c(Shoot{5, 1, true, 1.5, 3})[:]) // (looking past straight up)
	testing.expect(t, !ok)
	reload: Client_Message
	reload, ok = decode_client_t(encode_c(Reload{})[:])
	_, is_reload := reload.(Reload) // (Client_Message is no longer comparable: Hello holds a slice)
	testing.expect(t, ok && is_reload)
	at: Client_Message
	at, ok = decode_client_t(encode_c(Attack{12, 34})[:])
	testing.expect(t, ok && at.(Attack) == Attack{12, 34})
	at, ok = decode_client_t(encode_c(Use_Block{{-4, 70, 9}, 41})[:])
	testing.expect(t, ok && at.(Use_Block) == Use_Block{{-4, 70, 9}, 41})
	at, ok = decode_client_t(encode_c(Inventory_Request{3, {.Click, game.ALL_SLOTS - 1, 0}})[:])
	testing.expect(t, ok, "the last chest slot did not decode")
	_, ok = decode_client_t(encode_c(Inventory_Request{3, {.Click, game.ALL_SLOTS, 0}})[:])
	testing.expect(t, !ok, "a slot past the chest decoded")
	check := Prediction_Check {
		sequence = 90,
		fields   = player_fields(
			{position = {1, 2, 3}, velocity = {0.5, 0, 0}, on_ground = true, air_jumps = 1},
		),
	}
	at, ok = decode_client_t(encode_c(check)[:])
	testing.expect(t, ok && at.(Prediction_Check) == check, "Prediction_Check did not round-trip")
	at, ok = decode_client_t(encode_c(Use_Entity{12, 35})[:])
	testing.expect(t, ok && at.(Use_Entity) == Use_Entity{12, 35})
	at, ok = decode_client_t(encode_c(Stats_Request{"blocks", 2, "bob"})[:])
	testing.expect(t, ok && at.(Stats_Request) == Stats_Request{"blocks", 2, "bob"})
	_, ok = decode_client_t(
		encode_c(Stats_Request{"a very long filter that is more than thirty-two bytes", 0, ""})[:],
	)
	testing.expect(t, !ok, "an overlong filter decoded")
	batch := Telemetry_Batch{.Events, "2026-10-25", 1 << 33 | 5, "{\"t\":1}\n"}
	at, ok = decode_client_t(encode_c(batch)[:])
	testing.expect(t, ok && at.(Telemetry_Batch) == batch, "a batch did not round trip")
	_, ok = decode_client_t(
		encode_c(Telemetry_Batch{.Events, "a day that is far too long", 0, ""})[:],
	)
	testing.expect(t, !ok, "an overlong day decoded")
	report := Telemetry_Report {
		count = 2,
	}
	report.entries[0] = {7, "linux", {16, 70, 4000}}
	report.entries[1] = {8, "inventory", {5000, 0, 0}}
	at, ok = decode_client_t(encode_c(report)[:])
	testing.expect(t, ok && at.(Telemetry_Report) == report)
	report.count = MAX_TELEMETRY_ENTRIES + 1
	_, ok = decode_client_t(encode_c(report)[:])
	testing.expect(t, !ok, "too many entries decoded")
	dev := Dev_Message{9, "hi", "0.26", "Home", "A1", true, {1, -2, 3}, true, 1 << 40}
	at, ok = decode_client_t(encode_c(dev)[:])
	testing.expect(t, ok && at.(Dev_Message) == dev, "Dev_Message did not round trip")
	at, ok = decode_client_t(encode_c(Dev_Fetch{"0001"})[:])
	testing.expect(t, ok && at.(Dev_Fetch) == Dev_Fetch{"0001"})
	_, ok = decode_client_t(
		encode_c(
			Dev_Message {
				id = 1,
				text = strings.repeat("x", MAX_DEV_TEXT + 1, context.temp_allocator),
			},
		)[:],
	)
	testing.expect(t, !ok, "an oversized Dev_Message decoded")
	dack: Server_Message
	dack, ok = decode_server_t(encode_s(Dev_Ack{9, false, "no"})[:], scratch)
	testing.expect(t, ok && dack.(Dev_Ack) == Dev_Ack{9, false, "no"})
	replies := Dev_Replies {
		count = 2,
	}
	replies.entries[0] = {"0001", 1000, "first", ""}
	replies.entries[1] = {"0002", 2000, "second", "https://example.org"}
	dack, ok = decode_server_t(encode_s(replies)[:], scratch)
	testing.expect(t, ok && dack.(Dev_Replies) == replies, "Dev_Replies did not round trip")
	ack: Server_Message
	ack, ok = decode_server_t(encode_s(Telemetry_Ack{"2026-10-25", 1 << 34 | 9})[:], scratch)
	testing.expect(t, ok && ack.(Telemetry_Ack) == Telemetry_Ack{"2026-10-25", 1 << 34 | 9})
	page: Server_Message
	page, ok = decode_server_t(
		encode_s(Stats_Page{1, 3, "blocks.mined.stone 4\nsessions 1"})[:],
		scratch,
	)
	testing.expect(
		t,
		ok && page.(Stats_Page) == Stats_Page{1, 3, "blocks.mined.stone 4\nsessions 1"},
	)
	// The packs phase.
	want := Pack_Want {
		count = 2,
	}
	want.indices[0], want.indices[1] = 0, 3
	at, ok = decode_client_t(encode_c(want)[:])
	testing.expect(t, ok && at.(Pack_Want) == want, "Pack_Want did not round-trip")
	at, ok = decode_client_t(encode_c(Packs_Ready{1 << 40 | 5})[:])
	testing.expect(t, ok && at.(Packs_Ready) == Packs_Ready{1 << 40 | 5})
	packs := Packs {
		content = 0xabcdef,
		count   = 2,
	}
	packs.entries[0] = {"farmfix", "1.0.0", 5000, {0 = 1, 31 = 2}}
	packs.entries[1] = {"peat", "0.2", 9, {}}
	ps, pok := decode_server_t(encode_s(packs)[:], scratch)
	testing.expect(t, pok && ps.(Packs) == packs, "Packs did not round-trip")
	data := []u8{1, 2, 3, 4}
	part: Server_Message
	part, pok = decode_server_t(encode_s(Pack_Part{2, 1100, data})[:], scratch)
	testing.expect(t, pok)
	testing.expect_value(t, part.(Pack_Part).offset, u32(1100))
	testing.expect(t, slice.equal(part.(Pack_Part).data, data))
	_, pok = decode_server_t(encode_s(Pack_Part{2, 0, {}})[:], scratch)
	testing.expect(t, !pok, "an empty Pack_Part decoded")
	changed, cok := decode_server_t(encode_s(Packs_Changed{0xfeed_beef_1234})[:], scratch)
	testing.expect(t, cok && changed.(Packs_Changed) == Packs_Changed{0xfeed_beef_1234})
	// The market's kinds are retired (the sandbox's records and requests now): they do not decode.
	_, retired := decode_client_t([]u8{28, 3, 1, 0, 0, 32, 64})
	testing.expect(t, !retired, "a retired Market_Trade decoded")
	_, retired = decode_server_t([]u8{43, 0}, scratch)
	testing.expect(t, !retired, "a retired Market_View decoded")
	ga, gok := decode_client_t(encode_c(Game_Action{2, 77})[:])
	testing.expect(t, gok && ga.(Game_Action) == Game_Action{2, 77})
	_, gbad := decode_client_t(encode_c(Game_Action{MAX_GAME_ACTIONS, 1})[:])
	testing.expect(t, !gbad, "a game action past the most decoded")
	// Names: letters, digits, _ and -, 1..16 of them.
	for name in ([]string{"a", "Player_1", "x-y", "0123456789abcdef"}) {testing.expectf(t, game.name_valid(name), "%q", name)}
	for name in ([]string{"", "with space", "0123456789abcdefg", "é", "a/b"}) {testing.expectf(t, !game.name_valid(name), "%q", name)}
}

@(test)
test_chunk_round_trip :: proc(t: ^testing.T) {
	arrays: game.Block_Arrays
	testing.expect(t, game.block_arrays_init(&arrays, 16) == nil)
	defer game.block_arrays_destroy(&arrays)
	scratch := new(game.Block_Array)
	defer free(scratch)

	// Uniform.
	stone := game.Chunk_Blocks {
		uniform = .Stone,
	}
	m, ok := decode_server_t(encode_s(Chunk_Message{pos = {1, 2, 3}}, &stone)[:], scratch)
	c := m.(Chunk_Message)
	testing.expect(t, ok && c.is_uniform && c.uniform == .Stone && c.pos == {1, 2, 3})

	// Real terrain, and the worst case: every block differs from the last.
	terrain := game.Chunk_Blocks{}
	terrain.array, _ = game.block_arrays_take(&arrays)
	game.test_terrain(9, terrain.array)
	worst := game.Chunk_Blocks{}
	worst.array, _ = game.block_arrays_take(&arrays)
	for &b, i in worst.array {b = game.Block(1 + i % (len(game.Block) - 1))}
	for blocks in ([]^game.Chunk_Blocks{&terrain, &worst}) {
		bytes := encode_s(Chunk_Message{pos = {0, -1, 0}}, blocks)
		testing.expect(t, len(bytes) <= MAX_MESSAGE_SIZE)
		m, ok = decode_server_t(bytes[:], scratch)
		c = m.(Chunk_Message)
		testing.expect(t, ok && !c.is_uniform && scratch^ == blocks.array^)
	}
	game.chunk_release(&terrain, &arrays)
	game.chunk_release(&worst, &arrays)
}

// Every proper prefix of a valid message is invalid.
@(test)
test_truncated_messages_fail :: proc(t: ^testing.T) {
	scratch := new(game.Block_Array)
	defer free(scratch)
	arrays: game.Block_Arrays
	testing.expect(t, game.block_arrays_init(&arrays, 16) == nil)
	defer game.block_arrays_destroy(&arrays)
	terrain := game.Chunk_Blocks{}
	terrain.array, _ = game.block_arrays_take(&arrays)
	defer game.chunk_release(&terrain, &arrays)
	game.test_terrain(9, terrain.array)

	server := [][dynamic]u8 {
		encode_s(
			Welcome {
				PROTOCOL_VERSION,
				game.TICK_RATE,
				1,
				{},
				8,
				4,
				game.RULES_DEFAULTS,
				starmap.address_derive(1),
				0xfeed,
				"voxiverse@1.0.0",
				"stopwatch",
				0xbeef,
			},
		),
		encode_s(Bulk_Begin{1}),
		encode_s(Edit_Result{1, false, {}, .Stone, nil}),
		encode_s(Column{}),
		encode_s(Reject{"bye"}),
		encode_s(Chunk_Message{}, &terrain),
		encode_s(Unload_Chunk{}),
		encode_s(Pong{1}),
	}
	for bytes in server {
		for n in 0 ..< len(bytes) {
			_, ok := decode_server_t(bytes[:n], scratch)
			testing.expectf(t, !ok, "%d-byte prefix of a %d-byte message decoded", n, len(bytes))
		}
		// And one byte too many.
		longer := make([dynamic]u8, context.temp_allocator)
		append(&longer, ..bytes[:])
		append(&longer, 0)
		_, ok := decode_server_t(longer[:], scratch)
		testing.expect(t, !ok, "trailing byte accepted")
	}
	for bytes in ([][dynamic]u8{encode_c(Hello{1, {}, "abc", 0, 0, nil}), encode_c(Input{}), encode_c(Ping{3}), encode_c(Teleport{}), encode_c(Set_Rule{"a", "b"}), encode_c(edit_plain(1, 2, {}, .Stone))}) {
		for n in 0 ..< len(bytes) {
			_, ok := decode_client_t(bytes[:n])
			testing.expect(t, !ok)
		}
	}
}

// Hello's Steam part is optional: none is one zero byte; with a ticket it is the SteamID and
// the ticket, and a ticket over the limit or a ticket without a SteamID is refused.
@(test)
test_hello_steam :: proc(t: ^testing.T) {
	ticket := []u8{1, 2, 3, 4, 5}
	id := u64(76561197960265737)
	h, ok := decode_client_t(encode_c(Hello{PROTOCOL_VERSION, {}, "abc", 7, id, ticket})[:])
	testing.expect(t, ok)
	got, is_hello := h.(Hello)
	testing.expect(t, is_hello && got.steam_id == id && slice.equal(got.ticket, ticket))
	h, ok = decode_client_t(encode_c(Hello{PROTOCOL_VERSION, {}, "abc", 7, 0, nil})[:])
	got, is_hello = h.(Hello)
	testing.expect(t, ok && is_hello && got.steam_id == 0 && len(got.ticket) == 0)
	big := make([]u8, MAX_STEAM_TICKET + 1, context.temp_allocator)
	_, ok = decode_client_t(encode_c(Hello{PROTOCOL_VERSION, {}, "abc", 7, 5, big})[:])
	testing.expect(t, !ok, "a ticket over the limit")
	_, ok = decode_client_t(encode_c(Hello{PROTOCOL_VERSION, {}, "abc", 7, 0, ticket})[:])
	testing.expect(t, !ok, "a ticket with no SteamID")
}

@(test)
test_invalid_values_fail :: proc(t: ^testing.T) {
	scratch := new(game.Block_Array)
	defer free(scratch)

	bad_server :: proc(
		t: ^testing.T,
		scratch: ^game.Block_Array,
		what: string,
		build: proc(w: ^game.Writer),
	) {
		w: game.Writer
		game.writer_init(&w, context.temp_allocator)
		build(&w)
		_, ok := decode_server_t(w.buf[:], scratch)
		testing.expectf(t, !ok, "accepted: %s", what)
	}
	bad_client :: proc(t: ^testing.T, what: string, build: proc(w: ^game.Writer)) {
		w: game.Writer
		game.writer_init(&w, context.temp_allocator)
		build(&w)
		_, ok := decode_client_t(w.buf[:])
		testing.expectf(t, !ok, "accepted: %s", what)
	}

	bad_server(t, scratch, "empty message", proc(w: ^game.Writer) {})
	bad_server(t, scratch, "unknown kind", proc(w: ^game.Writer) {game.write_u8(w, 200)})
	bad_server(t, scratch, "kind 0", proc(w: ^game.Writer) {game.write_u8(w, 0)})
	bad_server(
		t,
		scratch,
		"chunk pos past the world limit",
		proc(w: ^game.Writer) {
			game.write_u8(w, 4) // Unload_Chunk
			game.write_i32(w, game.CHUNK_LIMIT)
			game.write_i32(w, 0)
			game.write_i32(w, 0)
		},
	)
	bad_server(
		t,
		scratch,
		"chunk above the world",
		proc(w: ^game.Writer) {
			game.write_u8(w, 4) // Unload_Chunk
			game.write_i32(w, 0)
			game.write_i32(w, game.CHUNK_MAX_Y)
			game.write_i32(w, 0)
		},
	)
	bad_server(t, scratch, "view radius too large", proc(w: ^game.Writer) {
		game.write_u8(w, 1)
		game.write_u32(w, PROTOCOL_VERSION)
		game.write_u32(w, game.TICK_RATE)
		for _ in 0 ..< 3 {game.write_f64(w, 0)}
		game.write_u32(w, MAX_VIEW_RADIUS + 1)
		game.write_u32(w, 4)
		rules := game.RULES_DEFAULTS
		write_vars(w, game.rules_table(), &rules)
	})
	bad_server(t, scratch, "view height zero", proc(w: ^game.Writer) {
		game.write_u8(w, 1)
		game.write_u32(w, PROTOCOL_VERSION)
		game.write_u32(w, game.TICK_RATE)
		for _ in 0 ..< 3 {game.write_f64(w, 0)}
		game.write_u32(w, 8)
		game.write_u32(w, 0)
		rules := game.RULES_DEFAULTS
		write_vars(w, game.rules_table(), &rules)
	})
	bad_server(t, scratch, "view height too large", proc(w: ^game.Writer) {
		game.write_u8(w, 1)
		game.write_u32(w, PROTOCOL_VERSION)
		game.write_u32(w, game.TICK_RATE)
		for _ in 0 ..< 3 {game.write_f64(w, 0)}
		game.write_u32(w, 8)
		game.write_u32(w, game.MAX_VIEW_HEIGHT + 1)
		rules := game.RULES_DEFAULTS
		write_vars(w, game.rules_table(), &rules)
	})

	chunk_header :: proc(w: ^game.Writer) {
		game.write_u8(w, 3) // Chunk
		for _ in 0 ..< 3 {game.write_i32(w, 0)}
	}
	bad_server(
		t,
		scratch,
		"column height above the world",
		proc(w: ^game.Writer) {
			game.write_u8(w, 10) // Column
			game.write_i32(w, 0)
			game.write_i32(w, 0)
			game.write_svarint(w, game.WORLD_MAX_Y)
			for _ in 1 ..< game.CHUNK_SIZE * game.CHUNK_SIZE {game.write_svarint(w, 0)}
		},
	)
	bad_server(t, scratch, "uniform chunk of an unknown block", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 0)
		game.write_u16(w, u16(len(game.Block) + game.BASE_NEW_STATES))
	})
	bad_server(t, scratch, "unknown chunk encoding", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 2)
	})
	bad_server(t, scratch, "empty palette", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 1)
		game.write_varint(w, 0)
	})
	bad_server(t, scratch, "palette of an unknown block", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 1)
		game.write_varint(w, 1)
		game.write_u16(w, 999)
		game.write_varint(w, game.CHUNK_VOLUME)
		game.write_varint(w, 0)
	})
	bad_server(t, scratch, "runs past the chunk", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 1)
		game.write_varint(w, 1)
		game.write_u16(w, 1)
		game.write_varint(w, game.CHUNK_VOLUME + 1)
		game.write_varint(w, 0)
	})
	bad_server(t, scratch, "runs short of the chunk", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 1)
		game.write_varint(w, 1)
		game.write_u16(w, 1)
		game.write_varint(w, game.CHUNK_VOLUME - 1)
		game.write_varint(w, 0)
	})
	bad_server(t, scratch, "zero-length run", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 1)
		game.write_varint(w, 1)
		game.write_u16(w, 1)
		game.write_varint(w, 0)
		game.write_varint(w, 0)
		game.write_varint(w, game.CHUNK_VOLUME)
		game.write_varint(w, 0)
	})
	bad_server(t, scratch, "palette index out of range", proc(w: ^game.Writer) {
		chunk_header(w)
		game.write_u8(w, 1)
		game.write_varint(w, 1)
		game.write_u16(w, 1)
		game.write_varint(w, game.CHUNK_VOLUME)
		game.write_varint(w, 1)
	})

	bad_client(t, "name too long", proc(w: ^game.Writer) {
		game.write_u8(w, 1)
		game.write_u32(w, PROTOCOL_VERSION)
		game.write_string(w, "a name that is far too long for anyone to need")
	})
	bad_client(t, "name not UTF-8", proc(w: ^game.Writer) {
		game.write_u8(w, 1)
		game.write_u32(w, PROTOCOL_VERSION)
		game.write_string(w, "\xff\xfe")
	})
	bad_client(t, "string length past the message", proc(w: ^game.Writer) {
		game.write_u8(w, 1)
		game.write_u32(w, PROTOCOL_VERSION)
		game.write_varint(w, 1 << 31)
	})
	bad_client(
		t,
		"unknown input button",
		proc(w: ^game.Writer) {
			game.write_u8(w, 2) // Input
			game.write_u32(w, 1)
			game.write_u8(w, 0)
			game.write_u8(w, 0)
			game.write_f32(w, 0)
			game.write_f32(w, 0)
			game.write_u8(w, 0x80)
		},
	)
	bad_client(t, "input looking past straight up", proc(w: ^game.Writer) {
		game.write_u8(w, 2)
		game.write_u32(w, 1)
		game.write_u8(w, 0)
		game.write_u8(w, 0)
		game.write_f32(w, 0)
		game.write_f32(w, 2)
		game.write_u8(w, 0)
	})
	bad_client(t, "input with NaN yaw", proc(w: ^game.Writer) {
		game.write_u8(w, 2)
		game.write_u32(w, 1)
		game.write_u8(w, 0)
		game.write_u8(w, 0)
		game.write_f32(w, math.nan_f32())
		game.write_f32(w, 0)
		game.write_u8(w, 0)
	})
	bad_client(
		t,
		"edit above the world",
		proc(w: ^game.Writer) {
			game.write_u8(w, 6) // Edit
			game.write_u32(w, 1)
			game.write_i32(w, 0)
			game.write_i32(w, game.WORLD_MAX_Y)
			game.write_i32(w, 0)
			game.write_u16(w, u16(game.Block.Stone))
		},
	)
	bad_client(t, "edit with an unknown block", proc(w: ^game.Writer) {
		game.write_u8(w, 6)
		game.write_u32(w, 1)
		game.write_u32(w, 0)
		game.write_i32(w, 0)
		game.write_i32(w, 0)
		game.write_i32(w, 0)
		game.write_u16(w, 999)
	})
	bad_client(
		t,
		"NaN position",
		proc(w: ^game.Writer) {
			game.write_u8(w, 4) // Teleport
			game.write_f64(w, math.nan_f64())
			game.write_f64(w, 0)
			game.write_f64(w, 0)
			game.write_f32(w, 0)
			game.write_f32(w, 0)
		},
	)
	bad_client(
		t,
		"infinite position",
		proc(w: ^game.Writer) {
			game.write_u8(w, 4) // Teleport
			game.write_f64(w, 0)
			game.write_f64(w, math.inf_f64(-1))
			game.write_f64(w, 0)
			game.write_f32(w, 0)
			game.write_f32(w, 0)
		},
	)
	bad_client(
		t,
		"position past the world limit",
		proc(w: ^game.Writer) {
			game.write_u8(w, 4) // Teleport
			game.write_f64(w, game.WORLD_LIMIT)
			game.write_f64(w, 0)
			game.write_f64(w, 0)
			game.write_f32(w, 0)
			game.write_f32(w, 0)
		},
	)
}

@(test)
test_varint :: proc(t: ^testing.T) {
	for v in ([]u32{0, 1, 127, 128, 300, 1 << 21, max(u32)}) {
		w: game.Writer
		game.writer_init(&w, context.temp_allocator)
		game.write_varint(&w, v)
		r := game.reader_make(w.buf[:])
		testing.expect_value(t, game.read_varint(&r), v)
		testing.expect(t, game.reader_finish(&r))
	}
	bad := [][]u8 {
		{0x80, 0x00}, // overlong zero
		{0xff, 0x00}, // overlong 127
		{0xff, 0xff, 0xff, 0xff, 0x1f}, // 33 bits
		{0x80, 0x80, 0x80, 0x80, 0x80, 0x01}, // 6 bytes
		{0x80}, // truncated
	}
	for b in bad {
		r := game.reader_make(b)
		game.read_varint(&r)
		testing.expectf(t, !r.ok, "accepted varint %v", b)
	}
}

// The dissector's generated schema block is the game's schema as it is now.
@(test)
test_dissector_schema_current :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(
		"tools/wireshark/voxiverse.lua",
		context.temp_allocator,
	)
	if !testing.expectf(t, err == nil, "cannot read the dissector: %v", err) {return}
	s := game_schema(allocator = context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	schema_lua(&s, &b)
	spliced, ok := schema_lua_splice(string(data), strings.to_string(b))
	if !testing.expect(t, ok, "tools/wireshark/voxiverse.lua has no schema block") {return}
	testing.expect(
		t,
		spliced == string(data),
		"tools/wireshark/voxiverse.lua's schema is stale: run ./build.sh schema",
	)
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

// 64-bit varints: the edges round-trip, overlong and over-wide encodings fail.
@(test)
test_varint64_edges :: proc(t: ^testing.T) {
	unsigned := [?]u64{0, 1, 127, 128, 1 << 32, 1 << 63, max(u64)}
	for v in unsigned {
		w: game.Writer
		game.writer_init(&w, context.temp_allocator)
		game.write_varint64(&w, v)
		r := game.reader_make(w.buf[:])
		testing.expect_value(t, game.read_varint64(&r), v)
		testing.expect(t, game.reader_finish(&r))
	}
	signed := [?]i64{0, -1, 1, min(i64), max(i64), -(1 << 40)}
	for v in signed {
		w: game.Writer
		game.writer_init(&w, context.temp_allocator)
		game.write_svarint64(&w, v)
		r := game.reader_make(w.buf[:])
		testing.expect_value(t, game.read_svarint64(&r), v)
		testing.expect(t, game.reader_finish(&r))
	}
	bad := [][]u8 {
		{0x80, 0x00}, // overlong zero
		{0x81, 0x80, 0x00}, // overlong one
		{0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02}, // 65 bits
		{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}, // 11 bytes
		{0x80}, // ends inside
	}
	for b, i in bad {
		r := game.reader_make(b)
		game.read_varint64(&r)
		testing.expectf(t, !r.ok, "bad encoding %d was accepted", i)
	}
}

// A rules table carries every kind it holds (numbers, bools and the text of
// default_game_mode) through write_vars and read_vars; a kind write_vars
// does not know panics, and a panic inside a test thread hangs the runner.
@(test)
test_rules_vars_round_trip :: proc(t: ^testing.T) {
	rules := game.RULES_DEFAULTS
	rules.gravity = 12.5
	rules.pvp = false
	rules.random_tick_speed = 9
	testing.expect(t, base.var_text_set(&rules.default_game_mode, "adventure"))

	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	write_vars(&w, game.rules_table(), &rules)

	r := game.reader_make(w.buf[:])
	got: game.Rules
	read_vars(&r, game.rules_table(), &got)
	testing.expect(t, r.ok)
	testing.expect_value(t, got.gravity, rules.gravity)
	testing.expect_value(t, got.pvp, false)
	testing.expect_value(t, got.random_tick_speed, i32(9))
	testing.expect_value(t, base.var_text(&got.default_game_mode), "adventure")
	testing.expect(t, game.rules_valid(&got))
}

decode_client_t :: proc(data: []u8) -> (Client_Message, bool) {
	return decode_client(data, game.test_reg())
}

decode_server_t :: proc(data: []u8, blocks: ^game.Block_Array) -> (Server_Message, bool) {
	return decode_server(data, blocks, game.test_reg())
}
