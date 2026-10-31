package game

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:sync"

import "common:base"
import "common:base/fuzz"

// The fuzz targets of the protocol's decoders (Q2, docs/fuzzing.md): every message a client
// sends, every message a server sends, and the state records under them. tools/fuzz lists
// net_fuzz_targets; the suite replays their regression files.

net_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "net.client_decode",
			run = fuzz_net_client_decode,
			seeds = SEEDS + "net.client_decode",
			dictionary = {"\x00\x00", "\xff\xff", "\xff\xff\xff\xff", "\x7f\xff\xff\xff"},
			max_len = MAX_MESSAGE_SIZE,
			generate = fuzz_net_generate_client,
			alloc_cap = 8 << 20,
		},
		{
			name = "net.server_decode",
			run = fuzz_net_server_decode,
			seeds = SEEDS + "net.server_decode",
			dictionary = {"\x00\x00", "\xff\xff", "\xff\xff\xff\xff", "\x7f\xff\xff\xff"},
			max_len = MAX_MESSAGE_SIZE,
			generate = fuzz_net_generate_server,
			alloc_cap = 8 << 20,
		},
		{
			name = "net.state",
			run = fuzz_net_state,
			seeds = SEEDS + "net.state",
			dictionary = {"\x00\x00", "\xff\xff", "\xff\xff\xff\xff", "\x01\x01", "\x02\x01"},
			max_len = 8 << 10,
			generate = fuzz_net_generate_state,
			alloc_cap = 32 << 20,
		},
	}
	return targets[:]
}

// ---- net.client_decode

fuzz_net_client_decode :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	m, ok := decode_client(data, fuzz_registry())
	if !ok {return 1}
	return fuzz.sig_mix(2, u64(reflect.get_union_variant_raw_tag(m)), fuzz.sig_bucket(len(data)))
}

// ---- generators

@(private = "file")
fuzz_net_pick :: proc(rng: ^base.Rng, values: []i64) -> i64 {
	return values[base.rng_int_max(rng, len(values))]
}

@(private = "file")
EDGE_U32 := [?]i64{0, 1, 2, 255, 256, 65535, 65536, 0x7fff_ffff, 0xffff_ffff}

@(private = "file")
edge_u32 :: proc(rng: ^base.Rng) -> u32 {return u32(fuzz_net_pick(rng, EDGE_U32[:]))}

@(private = "file")
edge_f32 :: proc(rng: ^base.Rng) -> f32 {
	switch base.rng_int_max(rng, 6) {
	case 0:
		return 0
	case 1:
		return 3.14159
	case 2:
		return -1e6
	case 3:
		return 1e30
	case 4:
		return base.rng_f32_range(rng, -4, 4)
	}
	return -0.5
}

@(private = "file")
edge_pos :: proc(rng: ^base.Rng) -> Block_Pos {
	edges := [?]i32{0, -1, 1, WORLD_MIN_Y, WORLD_MAX_Y - 1, WORLD_LIMIT - 1, -WORLD_LIMIT}
	return {
		edges[base.rng_int_max(rng, len(edges))],
		edges[base.rng_int_max(rng, len(edges))],
		edges[base.rng_int_max(rng, len(edges))],
	}
}

@(private = "file")
word :: proc(rng: ^base.Rng, max_len: int) -> string {
	n := base.rng_int_max(rng, max_len + 1)
	b := make([]u8, n, context.temp_allocator)
	for &c in b {c = u8('a' + base.rng_int_max(rng, 26))}
	return string(b)
}

fuzz_net_generate_client :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	which := base.rng_int_max(rng, 25)
	m: Client_Message
	switch which {
	case 0:
		account: Account
		for &b in account {b = u8(base.rng_u32(rng))}
		m = Hello{PROTOCOL_VERSION, account, "Steve_1", base.rng_u64(rng)}
	case 1:
		m = Input {
			sequence = edge_u32(rng),
			input = {
				move = {edge_f32(rng), edge_f32(rng)},
				yaw = edge_f32(rng),
				pitch = edge_f32(rng),
				buttons = transmute(bit_set[Button;u8])u8(base.rng_u32(rng)),
			},
			snapshot = edge_u32(rng),
		}
	case 2:
		m = Ping{edge_u32(rng)}
	case 3:
		m = Teleport {
			{f64(edge_f32(rng)), f64(edge_f32(rng)), f64(edge_f32(rng))},
			edge_f32(rng),
			edge_f32(rng),
		}
	case 4:
		m = Set_Rule{"rules.gravity", word(rng, 8)}
	case 5:
		m = Edit {
			id     = edge_u32(rng),
			after  = edge_u32(rng),
			pos    = edge_pos(rng),
			block  = Block(base.rng_int_max(rng, 70)),
			target = edge_pos(rng),
			face   = u8(base.rng_int_max(rng, 9)),
			hit    = {u8(base.rng_int_max(rng, 18)), u8(base.rng_int_max(rng, 18)), 0},
		}
	case 6:
		m = Command{word(rng, MAX_ADMIN_TEXT)}
	case 7:
		m = Attack{edge_u32(rng), edge_u32(rng)}
	case 8:
		m = Fire{edge_u32(rng), edge_f32(rng), edge_f32(rng)}
	case 9:
		m = Chat{word(rng, MAX_CHAT_TEXT)}
	case 10:
		m = Inventory_Request {
			edge_u32(rng),
			{
				kind = Inventory_Action_Kind(base.rng_int_max(rng, 8)),
				slot = base.rng_int_range(rng, -2, 50),
				arg = base.rng_int_max(rng, 70000),
			},
		}
	case 11:
		sig: Signature
		for &b in sig {b = u8(base.rng_u32(rng))}
		m = Proof{sig}
	case 12:
		m = Choose{"Alex"}
	case 13:
		g: Dial
		g.gate = edge_pos(rng)
		for &b in g.address.galaxy {b = u8(base.rng_int_max(rng, SYMBOLS))}
		for &b in g.address.world {b = u8(base.rng_int_max(rng, SYMBOLS))}
		m = g
	case 14:
		m = Use_Entity{edge_u32(rng), edge_u32(rng)}
	case 15:
		m = Stats_Request{word(rng, MAX_STATS_FILTER), u16(base.rng_u32(rng)), "Steve_1"}
	case 16:
		t := Telemetry_Report {
			count = base.rng_int_max(rng, MAX_TELEMETRY_ENTRIES + 1),
		}
		for &e in t.entries {
			e.kind = u8(base.rng_int_max(rng, 8))
			e.text = word(rng, MAX_TELEMETRY_TEXT)
			e.n = {edge_u32(rng), edge_u32(rng), 0}
		}
		m = t
	case 17:
		m = Telemetry_Batch {
			kind   = Batch_Kind(base.rng_int_max(rng, 2)),
			day    = "2026-10-31",
			offset = base.rng_u64(rng),
			text   = word(rng, 200),
		}
	case 18:
		m = Use_Block{edge_pos(rng), edge_u32(rng)}
	case 19:
		p: Prediction_Check
		p.sequence = edge_u32(rng)
		for &f in p.fields {f = edge_u32(rng)}
		m = p
	case 20:
		w := Pack_Want {
			count = u8(base.rng_int_max(rng, MAX_PACKS + 1)),
		}
		for &i in w.indices {i = u8(base.rng_int_max(rng, MAX_PACKS + 1))}
		m = w
	case 21:
		m = Packs_Ready{base.rng_u64(rng)}
	case 22:
		m = Respawn{}
	case 23:
		m = Shoot {
			edge_u32(rng),
			u8(base.rng_int_max(rng, 12)),
			base.rng_int_max(rng, 2) == 0,
			edge_f32(rng),
			edge_f32(rng),
		}
	case:
		m = Reload{}
	}
	w: Writer
	writer_init(&w, context.temp_allocator)
	encode_client(&w, m)
	append(out, ..w.buf[:])
}

// ---- net.server_decode

fuzz_net_server_decode :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	scratch := new(Block_Array, allocator)
	defer free(scratch, allocator)
	m, ok := decode_server(data, scratch, fuzz_registry())
	if !ok {return 1}
	return fuzz.sig_mix(2, u64(reflect.get_union_variant_raw_tag(m)), fuzz.sig_bucket(len(data)))
}

fuzz_net_generate_server :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	which := base.rng_int_max(rng, 18)
	m: Server_Message
	blocks: Chunk_Blocks
	switch which {
	case 0:
		m = Welcome {
			protocol    = PROTOCOL_VERSION,
			tick_rate   = TICK_RATE,
			player      = u16(base.rng_int_max(rng, 40)),
			spawn       = {f64(edge_f32(rng)), 64, 0},
			view_radius = u32(base.rng_int_max(rng, 40)),
			view_height = u32(base.rng_int_max(rng, 20)),
			content     = base.rng_u64(rng),
			packs       = word(rng, 40),
		}
	case 1:
		m = Reject{word(rng, MAX_REASON_LENGTH)}
	case 2:
		// a chunk: uniform, or an array with a palette of every size up to 300 blocks
		arr := new(Block_Array, context.temp_allocator)
		palette := 1 + base.rng_int_max(rng, 300)
		for &b, i in arr {b = Block(i % palette if i % 3 != 0 else 0)}
		if base.rng_int_max(rng, 4) == 0 {
			blocks.uniform = Block(base.rng_int_max(rng, 70))
			m = Chunk_Message {
				pos        = {1, 2, 3},
				uniform    = blocks.uniform,
				is_uniform = true,
			}
		} else {
			blocks.array = arr
			m = Chunk_Message {
				pos = {i32(base.rng_int_range(rng, -9, 9)), 0, 0},
			}
		}
	case 3:
		m = Unload_Chunk{{1, -2, 3}}
	case 4:
		m = Pong{edge_u32(rng)}
	case 5:
		m = Edit_Result {
			edge_u32(rng),
			base.rng_int_max(rng, 2) == 0,
			edge_pos(rng),
			Block(base.rng_int_max(rng, 70)),
			nil,
		}
		if base.rng_int_max(rng, 2) == 0 {
			e := m.(Edit_Result)
			e.companion = Companion_Record{edge_pos(rng), .Air}
			m = e
		}
	case 6:
		c := Column {
			pos = {i32(base.rng_int_range(rng, -30, 30)), i32(base.rng_int_range(rng, -30, 30))},
		}
		for &h in c.heights {h = i32(base.rng_int_range(rng, WORLD_MIN_Y, WORLD_MAX_Y))}
		m = c
	case 7:
		m = Bulk_Begin{u16(base.rng_u32(rng))}
	case 8:
		n: Nonce
		for &b in n {b = u8(base.rng_u32(rng))}
		m = Challenge{n}
	case 9:
		m = Characters{"Steve_1,Alex"}
	case 10:
		m = World_Changed{}
	case 11:
		m = Stats_Page {
			u16(base.rng_int_max(rng, 5)),
			u16(base.rng_int_max(rng, 5)),
			word(rng, 300),
		}
	case 12:
		m = Telemetry_Ack{"2026-10-31", base.rng_u64(rng)}
	case 13:
		m = State_Message{fuzz_net_state_bytes(rng, false)}
	case 14:
		m = Snapshot_Message{fuzz_net_state_bytes(rng, true)}
	case 15:
		p := Packs {
			content = base.rng_u64(rng),
			count   = u8(base.rng_int_max(rng, 4)),
		}
		for i in 0 ..< int(p.count) {
			p.entries[i] = {"extra", "1.0.0", edge_u32(rng), {}}
		}
		m = p
	case 16:
		m = Pack_Part {
			u8(base.rng_int_max(rng, 4)),
			edge_u32(rng),
			make([]u8, base.rng_int_max(rng, MAX_PACK_PART + 1), context.temp_allocator),
		}
	case:
		m = Packs_Changed{base.rng_u64(rng)}
	}
	w: Writer
	writer_init(&w, context.temp_allocator, MAX_MESSAGE_SIZE)
	encode_server(&w, m, &blocks)
	append(out, ..w.buf[:])
}

// ---- net.state

// fuzz_net_schema: the game's schema, made once and never freed.
fuzz_net_schema :: proc() -> ^Schema {
	@(static) once: sync.Once
	@(static) schema: Schema
	sync.once_do(&once, proc() {schema = game_schema(runtime.heap_allocator())})
	return &schema
}

// fuzz_net_put: one value of every kind into tx: records of the keyed kinds under two keys,
// the scalar fields given small values from rng when it is not nil.
@(private = "file")
fuzz_net_put :: proc(tx: ^Sender, rng: ^base.Rng) {
	schema := tx.schema
	for kind in 0 ..< len(schema.kinds) {
		k := &schema.kinds[kind]
		keys := 1 if k.key == .None else 2
		for i in 0 ..< keys {
			v := mem.alloc_bytes(max(k.size, 8), 8, context.temp_allocator) or_else nil
			if rng != nil {
				for f in k.fields {
					p := rawptr(uintptr(raw_data(v)) + uintptr(f.offset))
					#partial switch f.type {
					case .Bool:
						(^bool)(p)^ = base.rng_int_max(rng, 2) == 0
					case .Uint, .Int:
						if f.size <= 2 {
							store_bits(p, f.size, u64(base.rng_int_max(rng, 40)))
						}
					}
				}
			}
			if k.check != nil && !k.check(fuzz_registry(), raw_data(v)) {
				fuzz_net_fix(k, raw_data(v))
				if !k.check(fuzz_registry(), raw_data(v)) {continue}
			}
			key := Key{}
			if k.key != .None {key = {
					a = i32(i + 1),
					b = i32(i),
					c = 0,
				}}
			switch {
			case k.is_event:
				sender_event(tx, kind, raw_data(v))
			case:
				sender_put(tx, kind, key, raw_data(v))
			}
		}
	}
}

// fuzz_net_fix: gives a value the zero value fails the check of a plausible one.
@(private = "file")
fuzz_net_fix :: proc(k: ^Schema_Kind, v: rawptr) {
	switch k.value {
	case Rules:
		(^Rules)(v)^ = RULES_DEFAULTS
	case Health:
		(^Health)(v)^ = {20, 20, false}
	case Player_Record:
		(^Player_Record)(v).name = "Steve_1"
		(^Player_Record)(v).held = NO_ITEM
		for &w in (^Player_Record)(v).worn {w = NO_ITEM}
	}
}

// fuzz_net_baseline: the snapshot parts and the State message of tick 1, from a sender whose
// values are zero: what every case's receiver has applied before the input.
fuzz_net_baseline :: proc(tx: ^Sender, allocator: runtime.Allocator) -> []Outgoing {
	context.allocator = allocator
	sender_init(tx, fuzz_net_schema(), allocator)
	fuzz_net_put(tx, nil)
	out := make([dynamic]Outgoing, allocator)
	sender_flush(tx, 1, {}, &out, allocator)
	return out[:]
}

// fuzz_net_state_bytes: a message of tick 2 (a snapshot part as a delta against tick 1, or
// a State message), values varied by rng.
fuzz_net_state_bytes :: proc(rng: ^base.Rng, snapshot: bool) -> []u8 {
	context.allocator = context.temp_allocator
	tx: Sender
	fuzz_net_baseline(&tx, context.temp_allocator)
	sender_ack(&tx, 1)
	fuzz_net_put(&tx, rng)
	out := make([dynamic]Outgoing, context.temp_allocator)
	sender_flush(&tx, 2, {}, &out, context.temp_allocator)
	options := make([dynamic][]u8, context.temp_allocator)
	for o in out {
		if o.snapshot == snapshot {append(&options, o.data)}
	}
	if len(options) == 0 {
		one := make([]u8, 1, context.temp_allocator)
		one[0] = SNAPSHOT_MESSAGE if snapshot else STATE_MESSAGE
		return one
	}
	return slice.clone(options[base.rng_int_max(rng, len(options))], context.temp_allocator)
}

fuzz_net_generate_state :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	append(out, ..fuzz_net_state_bytes(rng, base.rng_int_max(rng, 2) == 0))
}

fuzz_net_state :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = allocator
	rx: Receiver
	receiver_init(&rx, fuzz_net_schema(), fuzz_registry(), allocator)
	defer receiver_destroy(&rx)
	// the replica holds a value of every kind, and tick 1's snapshot
	{
		arena: mem.Dynamic_Arena // the sender's output is many small allocations: one arena frees them
		mem.dynamic_arena_init(&arena, allocator, allocator)
		defer mem.dynamic_arena_destroy(&arena)
		in_arena := mem.dynamic_arena_allocator(&arena)
		tx: Sender
		parts := fuzz_net_baseline(&tx, in_arena)
		got := make([dynamic]Received, allocator)
		defer delete(got)
		for p in parts {
			ok :=
				receive_state(&rx, p.data, &got) if !p.snapshot else receive_snapshot(&rx, p.data, &got)
			if !ok {fuzz.fail("the receiver refused the baseline")}
		}
	}
	got := make([dynamic]Received, allocator)
	defer delete(got)
	ok: bool
	switch {
	case len(data) > 0 && data[0] == STATE_MESSAGE:
		ok = receive_state(&rx, data, &got)
	case len(data) > 0 && data[0] == SNAPSHOT_MESSAGE:
		ok = receive_snapshot(&rx, data, &got)
	}
	if !ok {return 1}
	return fuzz.sig_mix(2, u64(data[0]), u64(len(got)), fuzz.sig_bucket(len(data)))
}
