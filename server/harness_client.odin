package server

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"

import "common:base"
import "common:game"
import "common:netcode"

// The mirror and the session (M38, moved out of determinism_test.odin by Q2b so a fuzz
// target can use them): a test client on the pipe of a stepped server, and the session that
// pairs it with its server. No behaviour of its own: the determinism tests, the scenarios
// and the fuzz targets drive it.

DETERMINISM_TICKS :: #config(VX_DETERMINISM_TICKS, 2000)
DETERMINISM_LOG :: #config(VX_DETERMINISM_LOG, "")
DETERMINISM_SEED :: 38
CHECKPOINT_EVERY :: 1000


// Mirror: the client on the pipe. latency_test's predicting client grown up: it
// answers the challenge, keeps the chunks it is sent, predicts and reconciles.
Mirror :: struct {
	key:           game.Account_Key,
	endpoint:      game.Endpoint,
	scratch:       ^game.Block_Array,
	arrays:        game.Block_Arrays,
	chunks:        map[game.Chunk_Pos]game.Chunk_Blocks,
	prediction:    game.Prediction,
	rules:         game.Rules,
	welcomed:      bool,
	last_update:   game.Own_Player,
	schema:        game.Schema,
	rx:            game.Receiver,
	teleports:     u8,
	entities:      [dynamic]u32, // ids told, in the order told
	notices:       [dynamic]string, // the text of every Notice told (heap)
	packs_changed: u64, // the content of the last Packs_Changed
	inv_seq:       u32,
	edit_id:       u32,
	mismatches:    int, // updates where the mirror's prediction was not the server's
	updates:       int,
	corrections:   int, // counted from the script's start
	first_fix:     u64, // the server tick of the first
	inventory:     game.Inventory, // as the server last said
	mode:          int, // the game mode it said (when mode_known)
	mode_known:    bool,
	sent:          ^[dynamic][]u8, // when set, every message sent is also kept here (a copy, heap)
	heard:         ^[dynamic][]u8, // when set, every packet the server sent is kept here (a copy, heap), as it arrived
}

// mirror_mods: what the real client moves with: the mode and inventory the server told
// (derive_character), as the server's step does.
mirror_mods :: proc(m: ^Mirror) -> game.Mods {
	if !m.mode_known {return game.MODS_NONE}
	return game.derive_character(test_reg(), m.mode, &m.inventory)
}

Session :: struct {
	scripted:   bool, // the mirror's turn this tick follows the script
	manual:     bool, // the test drives the mirror itself (mirror_receive, mirror_send) before each harness_step: its turn does nothing
	h:          Harness, // the server, its pipe and its clock (harness.odin)
	mirror:     Mirror,
	script_at:  u64, // the server tick the script started after
	hashes:     [dynamic]State_Hash,
	log:        strings.Builder, // (session A, when VX_DETERMINISM_LOG is set)
	logging:    bool,
	seen:       [Hash_Section]map[u64]struct{},
	checkpoint: [dynamic]bool, // per checkpoint: the mirror's chunks hash as the server's
	failures:   [dynamic]string,
	input:      game.Player_Input, // what the mirror's turn sends when it is not scripted (scenario_test.odin sets it)
	check:      bool, // the mirror sends a Prediction_Check every DESYNC_CHECK_INPUTS inputs, as a client does
	hook:       proc(data: rawptr, msg: game.Input, in_: game.Player_Input), // after each input sent (not scripted)
	hook_data:  rawptr,
}

block_of :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
	m := (^Mirror)(data)
	blocks, ok := &m.chunks[game.chunk_of(p)]
	if !ok {return .Air, false}
	return game.chunk_get(blocks, game.local_of(p)), true
}

query :: proc(m: ^Mirror) -> game.Block_Query {
	return {m, block_of, test_blocks()}
}

mirror_set :: proc(m: ^Mirror, p: game.Block_Pos, b: game.Block) {
	if blocks, ok := &m.chunks[game.chunk_of(p)]; ok {
		game.chunk_replica_set(blocks, &m.arrays, game.local_of(p), b)
	}
}

mirror_send :: proc(m: ^Mirror, msg: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, msg)
	if m.sent != nil {append(m.sent, slice.clone(w.buf[:], runtime.heap_allocator()))}
	game.send(m.endpoint, w.buf[:])
}

mirror_pump :: proc(sess: ^Session) {
	m := &sess.mirror
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(m.endpoint, &packets)
	for p in packets {
		defer game.packet_free(m.endpoint, p)
		if m.heard != nil {append(m.heard, slice.clone(p, runtime.heap_allocator()))}
		msg, ok := game.decode_server(p, m.scratch, m.rx.reg)
		if !ok {
			append(&sess.failures, "the mirror could not decode a message")
			continue
		}
		#partial switch v in msg {
		case game.Packs_Changed:
			m.packs_changed = v.content
		case game.Challenge:
			mirror_send(m, game.Proof{game.account_sign(&m.key, v.nonce)})
		case game.Welcome:
			m.rules, m.welcomed = v.rules, true
			game.prediction_init(&m.prediction, {position = v.spawn})
			rules := v.rules
			game.receiver_seed(&m.rx, int(game.State_Kind.Rules), &rules)
		case game.Chunk_Message:
			blocks := game.Chunk_Blocks {
				uniform = v.uniform,
			}
			if !v.is_uniform {
				blocks.array, _ = game.block_arrays_take(&m.arrays)
				blocks.array^ = m.scratch^
			}
			if old, had := &m.chunks[v.pos]; had {game.chunk_release(old, &m.arrays)}
			m.chunks[v.pos] = blocks
		case game.Unload_Chunk:
			if old, had := &m.chunks[v.pos]; had {
				game.chunk_release(old, &m.arrays)
				delete_key(&m.chunks, v.pos)
			}
		case game.State_Message:
			got := make([dynamic]game.Received, context.temp_allocator)
			if !game.receive_state(&m.rx, v.data, &got) {
				append(&sess.failures, "the mirror could not decode a State message")
			}
			mirror_apply(sess, got[:])
		case game.Snapshot_Message:
			got := make([dynamic]game.Received, context.temp_allocator)
			if !game.receive_snapshot(&m.rx, v.data, &got) {
				append(&sess.failures, "the mirror could not decode a Snapshot message")
			}
			mirror_apply(sess, got[:])
		case game.Edit_Result:
			mirror_set(m, v.pos, v.block)
			if c, two := v.companion.?; two {mirror_set(m, c.pos, c.block)}
		}
	}
}

// The mirror's pieces, for the tests that script their own session.
mirror_query :: proc(m: ^Mirror) -> game.Block_Query {
	return query(m)
}

mirror_receive :: proc(sess: ^Session) {
	mirror_pump(sess)
}

// chunks_agree: the mirror's chunks hash as the server's.
chunks_agree :: proc(sess: ^Session) -> bool {
	c := checkpoint(sess)
	return c.server == c.mirror
}

// mirror_apply: what the receiver yielded, as the mirror keeps it.
mirror_apply :: proc(sess: ^Session, got: []game.Received) {
	m := &sess.mirror
	for g in got {
		if g.op == .Event {
			if game.Event_Kind(g.kind - len(game.State_Kind)) == .Notice {
				append(&m.notices, strings.clone((^game.Notice)(g.value).text))
			}
			continue
		}
		switch game.State_Kind(g.kind) {
		case .Block:
			v := (^game.Block_Record)(g.value)
			mirror_set(m, game.key_block(g.key), game.Block(v.block))
		case .Own_Player:
			v := (^game.Own_Player)(g.value)^
			m.last_update = v
			before := m.prediction.corrections
			teleported := v.teleports != m.teleports
			m.teleports = v.teleports
			game.prediction_reconcile(
				&m.prediction,
				v,
				&m.rules,
				query(m),
				mirror_mods(m),
				teleported = teleported,
			)
			m.updates += 1
			knockback := sess.h.srv.tick - sess.script_at
			if m.prediction.corrections != before && !(knockback >= 6000 && knockback < 6030) { 	// (the rocket's blast moves the player: a correction by design)
				m.corrections += 1
				if m.first_fix == 0 {m.first_fix = sess.h.srv.tick}
			}
			if v.acked == m.prediction.next_sequence - 1 && m.prediction.state != v.state {
				m.mismatches += 1
			}
		case .Rules:
			m.rules = (^game.Rules)(g.value)^
		case .Entity:
			if g.op == .Create {append(&m.entities, u32(g.key.a))}
		case .Mode:
			if mode, found := game.mode_find(test_reg(), (^game.Mode_Record)(g.value).mode);
			   found {
				m.mode, m.mode_known = mode, true
			}
		case .Inventory:
			m.inventory = (^game.Inventory_State)(g.value).inventory
		case .Health,
		     .Clock,
		     .Grants,
		     .Variables,
		     .Selection,
		     .Player,
		     .Player_Motion,
		     .Entity_Motion,
		     .Tally,
		     .Place:
		}
	}
}

session_start :: proc(
	sess: ^Session,
	perturb: Perturb,
	logging: bool,
	no_sheep := false,
	with: Maybe(Config) = nil,
	conditions := netcode.Conditions{},
) -> bool {
	config := Config {
		seed         = DETERMINISM_SEED,
		generator    = .Earth,
		view_radius  = 4,
		view_height  = 2,
		allow_cheats = true,
		max_players  = 1,
		perturb      = perturb,
		no_sheep     = no_sheep,
	}
	if c, given := with.?; given {config = c}
	if !harness_start(&sess.h, config, local = true, conditions = conditions) {return false}
	sess.input = {
		pitch = -0.7,
	}
	m := &sess.mirror
	m.endpoint = harness_local(&sess.h)
	m.scratch = new(game.Block_Array)
	game.block_arrays_init(&m.arrays, 2048)
	m.key = test_key("determinism")
	m.schema = game.game_schema()
	game.receiver_init(&m.rx, &m.schema, sess.h.srv.registry)
	for sec in Hash_Section {sess.seen[sec] = make(map[u64]struct{})}
	sess.logging = logging
	if logging {
		sess.log = strings.builder_make()
		fmt.sbprintfln(
			&sess.log,
			"determinism 1 seed=%d ticks=%d os=%v opt=%v odin=%s",
			DETERMINISM_SEED,
			DETERMINISM_TICKS,
			ODIN_OS,
			ODIN_OPTIMIZATION_MODE,
			ODIN_VERSION,
		)
	}
	harness_add(&sess.h, mirror_tick, sess)
	mirror_send(m, test_hello("determinism"))
	return true
}

session_stop :: proc(sess: ^Session) {
	harness_stop(&sess.h)
	m := &sess.mirror
	for _, &c in m.chunks {game.chunk_release(&c, &m.arrays)}
	delete(m.chunks)
	delete(m.entities)
	for n in m.notices {delete(n)}
	delete(m.notices)
	game.receiver_destroy(&m.rx)
	game.schema_destroy(&m.schema)
	game.block_arrays_destroy(&m.arrays)
	free(m.scratch)
	delete(sess.hashes)
	delete(sess.checkpoint)
	for f in sess.failures {delete(f)}
	delete(sess.failures)
	for sec in Hash_Section {delete(sess.seen[sec])}
	if sess.logging {strings.builder_destroy(&sess.log)}
}

ticks_of :: proc(sess: ^Session) -> u64 {
	return sess.h.srv.tick - sess.script_at
}

// The script is a pure function of the tick it is on.
script_input :: proc(tick: u64) -> game.Player_Input {
	t := f64(tick)
	in_ := game.Player_Input {
		move  = {0.4 * f32(base.sin(t * 0.07)), 0.6},
		yaw   = -math.PI / 2 + 0.5 * f32(base.sin(t * 0.03)),
		pitch = -0.7, // looking ahead and down, at the ground in front
	}
	if tick % 35 == 20 {in_.buttons += {.Jump}}
	if tick >= 1000 && tick < 2000 {in_.buttons += {.Sprint}}
	if tick >= 2000 && tick < 2300 {in_.buttons += {.Sneak}}
	if tick == 4000 || tick == 5000 {in_.buttons += {.Toggle_Fly}}
	return in_
}

look_dir :: proc(yaw, pitch: f32) -> [3]f64 {
	y, p := f64(yaw), f64(pitch)
	return {-base.sin(y) * base.cos(p), base.sin(p), -base.cos(y) * base.cos(p)}
}

command :: proc(m: ^Mirror, text: string) {
	mirror_send(m, game.Command{text})
}

inventory :: proc(m: ^Mirror, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
	m.inv_seq += 1
	mirror_send(m, game.Inventory_Request{m.inv_seq, {kind, slot, arg}})
}

feet_block :: proc(m: ^Mirror) -> game.Block_Pos {
	p := m.prediction.state.position
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

// act: what the script does at its tick, besides walking.
act :: proc(m: ^Mirror, tick: u64, msg: game.Input, in_: game.Player_Input) {
	if tick >= 300 && tick < 3900 && tick % 40 == 0 {
		dir := look_dir(in_.yaw, in_.pitch)
		eye := game.player_eye(m.prediction.state)
		if hit, aimed := game.raycast(query(m), eye, dir, f64(m.rules.reach)); aimed {
			m.edit_id += 1
			e := game.edit_plain(m.edit_id, msg.sequence, hit.block, .Air)
			if (tick / 40) % 2 == 1 {e.pos, e.block = hit.block + hit.normal, .Stone}
			mirror_set(m, e.pos, e.block) // predicted
			mirror_send(m, e)
		}
	}
	switch tick {
	case 50:
		command(m, "summon sheep 2")
	case 600:
		command(m, "summon sheep 4")
	case 1200:
		command(m, "give @s wheat 5")
	case 1300:
		if len(m.entities) > 0 {mirror_send(m, game.Use_Entity{m.entities[0], msg.sequence})}
	case 2500:
		command(m, "setblock ~3 ~2 ~ water")
	case 3000:
		command(m, "fill ~2 ~-1 ~2 ~6 ~-1 ~6 farmland")
		command(m, "fill ~2 ~ ~2 ~6 ~ ~6 wheat_0")
	case 6000:
		mirror_send(m, game.Fire{msg.sequence, in_.yaw, -0.9})
	case 7000:
		command(m, "time set midnight")
	case 7500:
		command(m, "rule drops false")
	case 8000:
		inventory(m, .Drop, 0, 1)
	case 9000:
		command(m, "setblock ~2 ~ ~-2 chest")
	case 9010:
		b := feet_block(m) + {2, 0, -2}
		mirror_send(m, game.Use_Block{b, msg.sequence})
	case 9020:
		inventory(m, .Click, 0)
		inventory(m, .Click, game.CHEST_BASE)
	}
}

// mirror_check sends the Prediction_Check a client sends every DESYNC_CHECK_INPUTS
// inputs, once the chunks around it are there.
mirror_check :: proc(m: ^Mirror, sequence: u32) {
	if sequence % game.DESYNC_CHECK_INPUTS != 0 {return}
	centre := game.chunk_of(feet_block(m))
	for dy in i32(-1) ..= 1 {
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				if centre + {dx, dy, dz} not_in m.chunks {return}
			}
		}
	}
	mirror_send(m, game.Prediction_Check{sequence, game.player_fields(m.prediction.state)})
}

// mirror_tick is the mirror's turn in a tick (a harness party): it takes what
// the last tick sent and plays its part of this one.
mirror_tick :: proc(data: rawptr) {
	sess := (^Session)(data)
	if sess.manual {return}
	m := &sess.mirror
	mirror_pump(sess)
	if m.welcomed {
		tick := ticks_of(sess)
		in_ := sess.input
		if sess.scripted {in_ = script_input(tick)}
		msg := game.prediction_tick(&m.prediction, in_, &m.rules, query(m), mirror_mods(m))
		msg.snapshot = m.rx.ack
		mirror_send(m, msg)
		if sess.check {mirror_check(m, msg.sequence)}
		if sess.scripted {
			act(m, tick, msg, in_)
		} else if sess.hook != nil {
			sess.hook(sess.hook_data, msg, in_)
		}
	}
}

// session_step: one harness tick (the mirror's turn, then the server's), and
// the bookkeeping.
session_step :: proc(sess: ^Session, scripted: bool) -> State_Hash {
	sess.scripted = scripted
	h := harness_step(&sess.h)
	append(&sess.hashes, h)
	for sec in Hash_Section {sess.seen[sec][h.sections[sec]] = {}}
	if sess.logging {log_tick(sess, h)}
	return h
}

log_tick :: proc(sess: ^Session, h: State_Hash) {
	b := &sess.log
	fmt.sbprintf(b, "%d %016x", h.tick, h.root)
	for sec in Hash_Section {fmt.sbprintf(b, " %v=%016x", sec, h.sections[sec])}
	fmt.sbprintln(b)
}

// ready: joined, the world is there and the player has landed.
ready :: proc(sess: ^Session) -> bool {
	m := &sess.mirror
	st := m.last_update.state
	return(
		st.on_ground &&
		m.last_update.acked > 0 &&
		len(m.chunks) > 200 &&
		m.prediction.state == st \
	)
}


Checkpoint :: struct {
	server, mirror: u64,
}

// checkpoint: the chunks the mirror holds, hashed by the server and by the
// mirror from its own copies.
checkpoint :: proc(sess: ^Session) -> Checkpoint {
	m := &sess.mirror
	held := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in m.chunks {append(&held, pos)}
	slice.sort_by(held[:], game.chunk_pos_less)
	h := game.hasher_make()
	for pos in held {game.hash_chunk(&h, pos, &m.chunks[pos])}
	return {hash_chunks(sess.h.srv.home, held[:]), game.hasher_finish(h)}
}

@(private = "file")
shared_reg: ^game.Registry
@(private = "file")
shared_once: sync.Once

// test_reg: the base registry, built once for the package's tests and fuzz targets.
test_reg :: proc() -> ^game.Registry {
	sync.once_do(&shared_once, proc() {
		context.allocator = runtime.default_allocator()
		shared_reg = game.registry_base(runtime.default_allocator())
	})
	return shared_reg
}

test_blocks :: proc() -> ^game.Block_Table {
	return &test_reg().blocks
}

// test_key: the account a test client of name has (the same every run, so
// a restarted server knows it again).
test_key :: proc(name: string) -> (k: game.Account_Key) {
	seed: [32]u8
	for i in 0 ..< 32 {seed[i] = u8(i) * 7 ~ (name[i % len(name)] if len(name) > 0 else 0)}
	game.account_key_set(&k, seed[:])
	return
}

test_hello :: proc(name: string) -> game.Hello {
	schema := game.game_schema(context.temp_allocator)
	return {game.PROTOCOL_VERSION, test_key(name).account, name, schema.hash}
}
