package core

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"

import "common:access"
import "common:base"
import "common:game"
import "common:netcode"
import "common:protocol"

// The mirror and the session (shared with determinism_test.odin so a fuzz
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
	key:           access.Account_Key,
	endpoint:      protocol.Endpoint,
	scratch:       ^game.Block_Array,
	arrays:        game.Block_Arrays,
	chunks:        map[game.Chunk_Pos]game.Chunk_Blocks,
	layers:        map[game.Chunk_Pos]game.Chunk_Layers, // its replicated channels
	pools:         game.Layer_Pools,
	prediction:    protocol.Prediction,
	rules:         game.Rules,
	welcomed:      bool,
	last_update:   protocol.Own_Player,
	schema:        protocol.Schema,
	rx:            protocol.Receiver,
	teleports:     u8,
	entities:      [dynamic]u32, // ids told, in the order told
	notices:       [dynamic]string, // the text of every Notice told (heap)
	machines:      map[game.Block_Pos][game.MAX_MACHINE_SHOWN]u8, // what each machine shows, as told (heap)
	belts:         map[game.Block_Pos]game.Lane, // each belt's items, as last told (heap)
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
	reg:           ^game.Registry, // the server's (its game's pack's blocks and modes too); nil: the base registry
}

// mirror_reg: the registry the mirror reads blocks and modes by, as a client that took
// the server's packs does.
mirror_reg :: proc(m: ^Mirror) -> ^game.Registry {
	return m.reg if m.reg != nil else test_reg()
}

// mirror_mods: what the real client moves with: the mode and inventory the server told
// (derive_character), as the server's step does.
mirror_mods :: proc(m: ^Mirror) -> game.Mods {
	if !m.mode_known {return game.MODS_NONE}
	return game.derive_character(mirror_reg(m), m.mode, &m.inventory)
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
	hook:       proc(data: rawptr, msg: protocol.Input, in_: game.Player_Input), // after each input sent (not scripted)
	hook_data:  rawptr,
}

block_of :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
	m := (^Mirror)(data)
	blocks, ok := &m.chunks[game.chunk_of(p)]
	if !ok {return .Air, false}
	return game.chunk_get(blocks, game.local_of(p)), true
}

query :: proc(m: ^Mirror) -> game.Block_Query {
	return {m, block_of, &mirror_reg(m).blocks, {}}
}

mirror_set :: proc(m: ^Mirror, p: game.Block_Pos, b: game.Block) {
	if blocks, ok := &m.chunks[game.chunk_of(p)]; ok {
		game.chunk_replica_set(blocks, &m.arrays, game.local_of(p), b)
	}
}

mirror_send :: proc(m: ^Mirror, msg: protocol.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	protocol.encode_client(&w, msg)
	if m.sent != nil {append(m.sent, slice.clone(w.buf[:], runtime.heap_allocator()))}
	protocol.send(m.endpoint, w.buf[:])
}

mirror_pump :: proc(sess: ^Session) {
	m := &sess.mirror
	packets := make([dynamic]protocol.Packet, context.temp_allocator)
	protocol.receive(m.endpoint, &packets)
	for p in packets {
		defer protocol.packet_free(m.endpoint, p)
		if m.heard != nil {append(m.heard, slice.clone(p, runtime.heap_allocator()))}
		msg, ok := protocol.decode_server(p, m.scratch, m.rx.reg)
		if !ok {
			append(&sess.failures, strings.clone("the mirror could not decode a message"))
			continue
		}
		#partial switch v in msg {
		case protocol.Packs_Changed:
			m.packs_changed = v.content
		case protocol.Challenge:
			mirror_send(m, protocol.Proof{access.account_sign(&m.key, v.nonce)})
		case protocol.Welcome:
			if v.schema != m.schema.hash {
				append(&sess.failures, strings.clone("the mirror's schema is not the server's"))
			}
			m.rules, m.welcomed = v.rules, true
			protocol.prediction_init(&m.prediction, {position = v.spawn})
			rules := v.rules
			protocol.receiver_seed(&m.rx, int(protocol.State_Kind.Rules), &rules)
		case protocol.Chunk_Message:
			blocks := game.Chunk_Blocks {
				uniform = v.uniform,
			}
			if !v.is_uniform {
				blocks.array, _ = game.block_arrays_take(&m.arrays)
				blocks.array^ = m.scratch^
			}
			if old, had := &m.chunks[v.pos]; had {game.chunk_release(old, &m.arrays)}
			m.chunks[v.pos] = blocks
			if v.pos not_in m.layers {m.layers[v.pos] = {}}
			l := &m.layers[v.pos]
			if game.layers_from_wire(l, &m.pools, m.rx.reg.channels, v.channels) != nil {
				append(&sess.failures, strings.clone("the mirror is out of channel pages"))
			}
		case protocol.Unload_Chunk:
			if old, had := &m.chunks[v.pos]; had {
				game.chunk_release(old, &m.arrays)
				delete_key(&m.chunks, v.pos)
			}
			if l, had := &m.layers[v.pos]; had {
				game.layers_release(l, &m.pools)
				delete_key(&m.layers, v.pos)
			}
		case protocol.State_Message:
			got := make([dynamic]protocol.Received, context.temp_allocator)
			if !protocol.receive_state(&m.rx, v.data, &got) {
				append(
					&sess.failures,
					strings.clone("the mirror could not decode a State message"),
				)
			}
			mirror_apply(sess, got[:])
		case protocol.Snapshot_Message:
			got := make([dynamic]protocol.Received, context.temp_allocator)
			if !protocol.receive_snapshot(&m.rx, v.data, &got) {
				append(
					&sess.failures,
					strings.clone("the mirror could not decode a Snapshot message"),
				)
			}
			mirror_apply(sess, got[:])
		case protocol.Edit_Result:
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

// mirror_game_record: the mirror's record of the game's kind whose value type is T
// (under key), or nil: what the server last put for it (a reliable kind's).
mirror_game_record :: proc(m: ^Mirror, $T: typeid, key := protocol.Key{}) -> ^T {
	kind, found := protocol.game_kind(&m.schema, T)
	if !found {return nil}
	return (^T)(protocol.replica_get(&m.rx.live, kind, key))
}

// mirror_apply: what the receiver yielded, as the mirror keeps it.
mirror_apply :: proc(sess: ^Session, got: []protocol.Received) {
	m := &sess.mirror
	for g in got {
		if g.kind >= m.schema.engine {continue} 	// a game's: they stay in m.rx (mirror_game_record)
		if g.op == .Event {
			if protocol.Event_Kind(g.kind - len(protocol.State_Kind)) == .Notice {
				append(&m.notices, strings.clone((^protocol.Notice)(g.value).text))
			}
			continue
		}
		switch protocol.State_Kind(g.kind) {
		case .Block:
			v := (^protocol.Block_Record)(g.value)
			mirror_set(m, protocol.key_block(g.key), game.Block(v.block))
		case .Channel:
			p := protocol.key_block(g.key)
			if l, ok := &m.layers[game.chunk_of(p)]; ok && g.op != .Remove {
				v := (^protocol.Channel_Record)(g.value).value
				if game.layers_set(
					   l,
					   &m.pools,
					   int(g.key.d),
					   game.local_index(game.local_of(p)),
					   v,
				   ) !=
				   nil {
					append(&sess.failures, strings.clone("the mirror is out of channel pages"))
				}
			}
		case .Own_Player:
			v := (^protocol.Own_Player)(g.value)^
			m.last_update = v
			before := m.prediction.corrections
			teleported := v.teleports != m.teleports
			m.teleports = v.teleports
			protocol.prediction_reconcile(
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
			if mode, found := game.mode_find(mirror_reg(m), (^protocol.Mode_Record)(g.value).mode);
			   found {
				m.mode, m.mode_known = mode, true
			}
		case .Inventory:
			m.inventory = (^protocol.Inventory_State)(g.value).inventory
		case .Belt:
			if m.belts == nil {m.belts = make(type_of(m.belts), runtime.heap_allocator())}
			m.belts[protocol.key_block(g.key)] = (^protocol.Belt_Record)(g.value).lane
		case .Machine:
			if m.machines == nil {m.machines = make(type_of(m.machines), runtime.heap_allocator())}
			m.machines[protocol.key_block(g.key)] = (^protocol.Machine_Record)(g.value).shown
		case .Health,
		     .Clock,
		     .Grants,
		     .Variables,
		     .Selection,
		     .Player,
		     .Player_Motion,
		     .Entity_Motion,
		     .Tally,
		     .Island,
		     .Place:
		}
	}
}

session_start :: proc(
	sess: ^Session,
	perturb: Perturb,
	logging: bool,
	no_natural_spawns := false,
	with: Maybe(Config) = nil,
	conditions := netcode.Conditions{},
) -> bool {
	config := Config {
		seed              = DETERMINISM_SEED,
		generator         = .Earth,
		view_radius       = 4,
		view_height       = 2,
		allow_cheats      = true,
		max_players       = 1,
		perturb           = perturb,
		no_natural_spawns = no_natural_spawns,
		kit               = HARNESS_KIT,
	}
	if c, given := with.?; given {config = c}
	if !harness_start(&sess.h, config, local = true, conditions = conditions) {return false}
	sess.input = {
		pitch = -0.7,
	}
	m := &sess.mirror
	m.endpoint = harness_local(&sess.h)
	m.reg = sess.h.srv.registry
	m.scratch = new(game.Block_Array)
	game.block_arrays_init(&m.arrays, 2048)
	game.layer_pools_init(&m.pools, 2048 * game.registry_replicated_channels(sess.h.srv.registry))
	m.key = test_key("determinism")
	// (the server's game's kinds too: the mirror checks Welcome's hash, as a client does)
	m.schema = protocol.game_schema(sess.h.srv.config.game.id, sess.h.srv.config.game.kinds)
	protocol.receiver_init(&m.rx, &m.schema, sess.h.srv.registry)
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
	for _, &l in m.layers {game.layers_release(&l, &m.pools)}
	delete(m.layers)
	game.layer_pools_destroy(&m.pools)
	delete(m.entities)
	for n in m.notices {delete(n)}
	delete(m.notices)
	delete(m.machines)
	delete(m.belts)
	protocol.receiver_destroy(&m.rx)
	protocol.schema_destroy(&m.schema)
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
	mirror_send(m, protocol.Command{text})
}

inventory :: proc(m: ^Mirror, kind: game.Inventory_Action_Kind, slot: int, arg := 0) {
	m.inv_seq += 1
	mirror_send(m, protocol.Inventory_Request{m.inv_seq, {kind, slot, arg}})
}

feet_block :: proc(m: ^Mirror) -> game.Block_Pos {
	p := m.prediction.state.position
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

// act: what the script does at its tick, besides walking.
act :: proc(m: ^Mirror, tick: u64, msg: protocol.Input, in_: game.Player_Input) {
	if tick >= 300 && tick < 3900 && tick % 40 == 0 {
		dir := look_dir(in_.yaw, in_.pitch)
		eye := game.player_eye(m.prediction.state)
		if hit, aimed := game.raycast(query(m), eye, dir, f64(m.rules.reach)); aimed {
			m.edit_id += 1
			e := protocol.edit_plain(m.edit_id, msg.sequence, hit.block, .Air)
			if (tick / 40) % 2 == 1 {e.pos, e.block = hit.block + hit.normal, .Stone}
			mirror_set(m, e.pos, e.block) // predicted
			mirror_send(m, e)
		}
	}
	switch tick {
	case 50:
		command(m, "summon dummy 2")
	case 600:
		command(m, "summon dummy 4")
	case 1200:
		command(m, "give @s wheat 5")
	case 1300:
		if len(m.entities) > 0 {mirror_send(m, protocol.Use_Entity{m.entities[0], msg.sequence})}
	case 2500:
		command(m, "setblock ~3 ~2 ~ water")
	case 3000:
		command(m, "fill ~2 ~-1 ~2 ~6 ~-1 ~6 farmland")
		command(m, "fill ~2 ~ ~2 ~6 ~ ~6 wheat_0")
	case 6000:
		mirror_send(m, protocol.Fire{msg.sequence, in_.yaw, -0.9})
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
		mirror_send(m, protocol.Use_Block{b, msg.sequence})
	case 9020:
		inventory(m, .Click, 0)
		inventory(m, .Click, game.CHEST_BASE)
	}
}

// mirror_check sends the Prediction_Check a client sends every DESYNC_CHECK_INPUTS
// inputs, once the chunks around it are there.
mirror_check :: proc(m: ^Mirror, sequence: u32) {
	if sequence % protocol.DESYNC_CHECK_INPUTS != 0 {return}
	centre := game.chunk_of(feet_block(m))
	for dy in i32(-1) ..= 1 {
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				if centre + {dx, dy, dz} not_in m.chunks {return}
			}
		}
	}
	mirror_send(m, protocol.Prediction_Check{sequence, protocol.player_fields(m.prediction.state)})
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
		msg := protocol.prediction_tick(&m.prediction, in_, &m.rules, query(m), mirror_mods(m))
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
	channels := sess.h.srv.registry.channels
	for pos in held {game.hash_chunk(&h, pos, &m.chunks[pos], &m.layers[pos], channels)}
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
test_key :: proc(name: string) -> (k: access.Account_Key) {
	seed: [32]u8
	for i in 0 ..< 32 {seed[i] = u8(i) * 7 ~ (name[i % len(name)] if len(name) > 0 else 0)}
	access.account_key_set(&k, seed[:])
	return
}

test_hello :: proc(name: string) -> protocol.Hello {
	schema := protocol.game_schema(allocator = context.temp_allocator)
	return {protocol.PROTOCOL_VERSION, test_key(name).account, name, schema.engine_hash, 0, nil}
}

// Harness_Player: one more player for a test, joining a listening harness server over
// its network as a remote client does (its account, the packs, its character), then
// standing still: a game's tests play with it beside the mirror (two players, a
// third...). It keeps what it is told of the game's records (harness_player_record) and
// the notices; the test moves it on the server's side (teleport, damage...).
Harness_Player :: struct {
	name:     string,
	h:        ^Harness,
	link:     netcode.Link,
	scratch:  ^game.Block_Array,
	schema:   protocol.Schema,
	rx:       protocol.Receiver,
	welcomed: bool,
	gone:     bool, // harness_player_leave: it no longer plays
	sequence: u32,
	messages: [dynamic][]u8,
	notices:  [dynamic]string, // the text of every Notice (heap)
}

// harness_player_join: p connects to h's server (which listens) as name; the harness
// runs it each tick from now. h and p stay where they are until harness_player_free,
// after harness_stop.
harness_player_join :: proc(h: ^Harness, p: ^Harness_Player, name: string) {
	assert(h.srv.listening, "harness_player_join needs a server that listens")
	s := &h.srv
	p^ = {
		name    = name,
		h       = h,
		scratch = new(game.Block_Array),
		schema  = protocol.game_schema(s.config.game.id, s.config.game.kinds),
	}
	protocol.receiver_init(&p.rx, &p.schema, s.registry)
	netcode.link_connect(
		&p.link,
		{net.IP4_Loopback, s.host.socket.port},
		"",
		h.net.now,
		sim = &h.net,
	)
	harness_add(h, harness_player_tick, p)
}

// harness_player_leave: p disconnects, as a player who quits; it stays in the
// harness's list doing nothing.
harness_player_leave :: proc(p: ^Harness_Player) {
	if p.gone {return}
	netcode.link_close(&p.link, "left")
	p.gone = true
}

// harness_player_free frees what p holds (after harness_stop).
harness_player_free :: proc(p: ^Harness_Player) {
	harness_player_leave(p)
	free(p.scratch)
	protocol.receiver_destroy(&p.rx)
	protocol.schema_destroy(&p.schema)
	for m in p.messages {netcode.link_free(&p.link, m)}
	delete(p.messages)
	for n in p.notices {delete(n)}
	delete(p.notices)
}

// harness_player_client: p's client on the server (nil before it joins).
harness_player_client :: proc(p: ^Harness_Player) -> ^Client {
	return client_by_name(&p.h.srv, p.name)
}

// harness_player_record: what the server last put for p of the game's kind whose value
// type is T (under key), or nil.
harness_player_record :: proc(p: ^Harness_Player, $T: typeid, key := protocol.Key{}) -> ^T {
	kind, found := protocol.game_kind(&p.schema, T)
	if !found {return nil}
	return (^T)(protocol.replica_get(&p.rx.live, kind, key))
}

@(private = "file")
harness_player_send :: proc(p: ^Harness_Player, m: protocol.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	protocol.encode_client(&w, m)
	netcode.link_send(&p.link, w.buf[:], protocol.message_reliable(.Client, w.buf[0]))
}

// harness_player_tick: what arrived is handled as a client handles it (the packs are
// the server's own registry's: it claims them all), and an idle input goes back.
@(private = "file")
harness_player_tick :: proc(data: rawptr) {
	p := (^Harness_Player)(data)
	if p.gone {return}
	s := &p.h.srv
	now := netcode.link_now(&p.link)
	was := p.link.state
	netcode.link_update(&p.link, now)
	if was != .Connected && p.link.state == .Connected {
		k := test_key(p.name)
		harness_player_send(
			p,
			protocol.Hello {
				protocol.PROTOCOL_VERSION,
				k.account,
				p.name,
				p.schema.engine_hash,
				0,
				nil,
			},
		)
	}
	netcode.link_receive(&p.link, &p.messages)
	for m in p.messages {
		defer netcode.link_free(&p.link, m)
		msg, ok := protocol.decode_server(m, p.scratch, s.registry)
		if !ok {continue}
		#partial switch v in msg {
		case protocol.Packs:
			harness_player_send(p, protocol.Pack_Want{})
			harness_player_send(p, protocol.Packs_Ready{v.content})
		case protocol.Challenge:
			k := test_key(p.name)
			harness_player_send(p, protocol.Proof{access.account_sign(&k, v.nonce)})
		case protocol.Characters:
			harness_player_send(p, protocol.Choose{p.name})
		case protocol.Welcome:
			p.welcomed = true
			rules := v.rules
			protocol.receiver_seed(&p.rx, int(protocol.State_Kind.Rules), &rules)
		case protocol.State_Message:
			got := make([dynamic]protocol.Received, context.temp_allocator)
			protocol.receive_state(&p.rx, v.data, &got)
			for g in got {
				if g.op == .Event &&
				   g.kind < p.schema.engine &&
				   protocol.Event_Kind(g.kind - len(protocol.State_Kind)) == .Notice {
					append(&p.notices, strings.clone((^protocol.Notice)(g.value).text))
				}
			}
		case protocol.Snapshot_Message:
			got := make([dynamic]protocol.Received, context.temp_allocator)
			protocol.receive_snapshot(&p.rx, v.data, &got)
		}
	}
	clear(&p.messages)
	if p.welcomed {
		p.sequence += 1
		harness_player_send(p, protocol.Input{p.sequence, {}, p.rx.ack})
	}
	netcode.link_flush(&p.link, now)
}
