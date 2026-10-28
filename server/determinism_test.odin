package server

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "../base"
import "../common/game"

// M38: the simulation is a function of what reaches it at each tick boundary.
// A stepped server (no thread, inline chunk jobs) is run twice side by side
// through a scripted session, each with a mirror client on its pipe, and every
// tick's state hash is compared; the first difference is named by field.

DETERMINISM_TICKS :: #config(VX_DETERMINISM_TICKS, 2000)
DETERMINISM_LOG :: #config(VX_DETERMINISM_LOG, "")
DETERMINISM_SEED :: 38
CHECKPOINT_EVERY :: 1000

Divergence :: struct {
	tick:    u64,
	section: Hash_Section,
	a, b:    string, // the first differing dump line of each
}

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
}

Session :: struct {
	srv:        Server,
	started:    bool,
	pipe:       game.Pipe,
	mirror:     Mirror,
	script_at:  u64, // the server tick the script started after
	hashes:     [dynamic]State_Hash,
	log:        strings.Builder, // (session A, when VX_DETERMINISM_LOG is set)
	logging:    bool,
	seen:       [Hash_Section]map[u64]struct{},
	checkpoint: [dynamic]bool, // per checkpoint: the mirror's chunks hash as the server's
	failures:   [dynamic]string,
}

@(private = "file")
block_of :: proc(data: rawptr, p: game.Block_Pos) -> (game.Block, bool) {
	m := (^Mirror)(data)
	blocks, ok := &m.chunks[game.chunk_of(p)]
	if !ok {return .Air, false}
	return game.chunk_get(blocks, game.local_of(p)), true
}

@(private = "file")
query :: proc(m: ^Mirror) -> game.Block_Query {
	return {m, block_of, test_blocks()}
}

@(private = "file")
mirror_set :: proc(m: ^Mirror, p: game.Block_Pos, b: game.Block) {
	if blocks, ok := &m.chunks[game.chunk_of(p)]; ok {
		game.chunk_set(blocks, &m.arrays, game.local_of(p), b)
	}
}

mirror_send :: proc(m: ^Mirror, msg: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, msg)
	game.send(m.endpoint, w.buf[:])
}

@(private = "file")
mirror_pump :: proc(sess: ^Session) {
	m := &sess.mirror
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(m.endpoint, &packets)
	for p in packets {
		defer game.packet_free(m.endpoint, p)
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
				teleported = teleported,
			)
			m.updates += 1
			knockback := sess.srv.tick - sess.script_at
			if m.prediction.corrections != before && !(knockback >= 6000 && knockback < 6030) { 	// (the rocket's blast moves the player: a correction by design)
				m.corrections += 1
				if m.first_fix == 0 {m.first_fix = sess.srv.tick}
			}
			if v.acked == m.prediction.next_sequence - 1 && m.prediction.state != v.state {
				m.mismatches += 1
			}
		case .Rules:
			m.rules = (^game.Rules)(g.value)^
		case .Entity:
			if g.op == .Create {append(&m.entities, u32(g.key.a))}
		case .Health,
		     .Inventory,
		     .Clock,
		     .Grants,
		     .Variables,
		     .Selection,
		     .Player,
		     .Player_Motion,
		     .Entity_Motion,
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
) -> bool {
	game.pipe_init(&sess.pipe)
	config := Config {
		seed         = DETERMINISM_SEED,
		generator    = .Earth,
		view_radius  = 4,
		view_height  = 2,
		stepped      = true,
		allow_cheats = true,
		max_players  = 1,
		perturb      = perturb,
		no_sheep     = no_sheep,
	}
	if c, given := with.?; given {config = c}
	if !start(&sess.srv, config, {&sess.pipe, .Server}) {return false}
	sess.started = true
	m := &sess.mirror
	m.endpoint = {&sess.pipe, .Client}
	m.scratch = new(game.Block_Array)
	game.block_arrays_init(&m.arrays, 2048)
	m.key = test_key("determinism")
	m.schema = game.game_schema()
	game.receiver_init(&m.rx, &m.schema, sess.srv.registry)
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
	mirror_send(m, test_hello("determinism"))
	return true
}

session_stop :: proc(sess: ^Session) {
	stop(&sess.srv)
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
	game.pipe_destroy(&sess.pipe)
	delete(sess.hashes)
	delete(sess.checkpoint)
	for f in sess.failures {delete(f)}
	delete(sess.failures)
	for sec in Hash_Section {delete(sess.seen[sec])}
	if sess.logging {strings.builder_destroy(&sess.log)}
}

ticks_of :: proc(sess: ^Session) -> u64 {
	return sess.srv.tick - sess.script_at
}

// The script is a pure function of the tick it is on.
@(private = "file")
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

@(private = "file")
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

@(private = "file")
feet_block :: proc(m: ^Mirror) -> game.Block_Pos {
	p := m.prediction.state.position
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

// act: what the script does at its tick, besides walking.
@(private = "file")
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

// session_step: the mirror takes what the last tick sent, plays its part of
// this tick, and the server runs it.
session_step :: proc(sess: ^Session, scripted: bool) -> State_Hash {
	m := &sess.mirror
	mirror_pump(sess)
	if m.welcomed {
		tick := ticks_of(sess)
		in_ := game.Player_Input {
			pitch = -0.7,
		}
		if scripted {in_ = script_input(tick)}
		msg := game.prediction_tick(&m.prediction, in_, &m.rules, query(m))
		msg.snapshot = m.rx.ack
		mirror_send(m, msg)
		if scripted {act(m, tick, msg, in_)}
	}
	h := step(&sess.srv)
	append(&sess.hashes, h)
	for sec in Hash_Section {sess.seen[sec][h.sections[sec]] = {}}
	if sess.logging {log_tick(sess, h)}
	return h
}

@(private = "file")
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

@(private = "file")
Checkpoint :: struct {
	server, mirror: u64,
}

// checkpoint: the chunks the mirror holds, hashed by the server and by the
// mirror from its own copies.
@(private = "file")
checkpoint :: proc(sess: ^Session) -> Checkpoint {
	m := &sess.mirror
	held := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in m.chunks {append(&held, pos)}
	slice.sort_by(held[:], game.chunk_pos_less)
	h := game.hasher_make()
	for pos in held {game.hash_chunk(&h, pos, &m.chunks[pos])}
	return {hash_chunks(sess.srv.home, held[:]), game.hasher_finish(h)}
}

@(private = "file")
dump_sections :: proc(s: ^Server, sections: Hash_Sections) -> string {
	b := strings.builder_make(context.temp_allocator)
	state_dump(s, sections, &b)
	return strings.to_string(b)
}

@(private = "file")
first_difference :: proc(a, b: string) -> (string, string) {
	la, lb :=
		strings.split_lines(a, context.temp_allocator),
		strings.split_lines(b, context.temp_allocator)
	for i in 0 ..< min(len(la), len(lb)) {
		if la[i] != lb[i] {return la[i], lb[i]}
	}
	if len(la) != len(lb) {return "(a line more)", "(a line fewer)"}
	return "", ""
}

// diverged names the first difference between two servers after the same tick.
@(private = "file")
diverged :: proc(a, b: ^Session, ha, hb: State_Hash) -> (d: Divergence, found: bool) {
	for sec in Hash_Section {
		if ha.sections[sec] == hb.sections[sec] {continue}
		la, lb := first_difference(dump_sections(&a.srv, {sec}), dump_sections(&b.srv, {sec}))
		return {tick = ha.tick, section = sec, a = la, b = lb}, true
	}
	return {}, false
}

@(private = "file")
divergence_text :: proc(d: Divergence) -> string {
	return fmt.tprintf("diverged at tick %d: %v: %s vs %s", d.tick, d.section, d.a, d.b)
}

@(private = "file")
maps_apart :: proc(a, b: ^Session) -> bool {
	table :: proc(s: ^Session) -> rawptr {
		return rawptr((^runtime.Raw_Map)(&s.srv.home.chunks.by_pos).data)
	}
	return table(a) != table(b)
}

// run_side_by_side runs two sessions the same way and compares every tick.
// perturb is applied to B only.
@(private = "file")
run_side_by_side :: proc(
	t: ^testing.T,
	ticks: int,
	perturb: Perturb,
	scripted: bool,
	log: bool,
) -> (
	d: Divergence,
	diverged_at: bool,
	a, b: ^Session,
) {
	a, b = new(Session), new(Session)
	if !testing.expect(t, session_start(a, {}, log && DETERMINISM_LOG != "")) {return}
	if !testing.expect(t, session_start(b, perturb, false)) {return}
	for i in 0 ..< 900 { 	// join, and stand until the world is there
		ha := session_step(a, false)
		hb := session_step(b, false)
		if dv, found := diverged(a, b, ha, hb); found {return dv, true, a, b}
		if ready(a) && ready(b) {break}
		if !testing.expect(t, i < 899, "the player never landed") {return}
	}
	for s in ([2]^Session{a, b}) {
		s.script_at = s.srv.tick
		s.mirror.corrections, s.mirror.mismatches, s.mirror.updates = 0, 0, 0
	}
	for _ in 0 ..< ticks {
		ha := session_step(a, scripted)
		hb := session_step(b, scripted)
		if dv, found := diverged(a, b, ha, hb); found {return dv, true, a, b}
		if ticks_of(a) % CHECKPOINT_EVERY == 0 || ticks_of(a) == u64(ticks) {
			ca, cb := checkpoint(a), checkpoint(b)
			append(&a.checkpoint, ca.server == ca.mirror && cb.server == cb.mirror)
			if a.logging {log_checkpoint(a, ca.server)}
		}
	}
	if a.logging {
		fmt.sbprintfln(&a.log, "end %016x", a.hashes[len(a.hashes) - 1].root)
		write_log(a)
	}
	return
}

@(private = "file")
log_checkpoint :: proc(sess: ^Session, world: u64) {
	fmt.sbprintfln(&sess.log, "dump %d", sess.srv.tick)
	all: Hash_Sections
	for sec in Hash_Section {all += {sec}}
	fmt.sbprint(&sess.log, dump_sections(&sess.srv, all))
	fmt.sbprintfln(&sess.log, "world %016x", world_hash(&sess.srv))
}

@(private = "file")
write_log :: proc(sess: ^Session) {
	path := DETERMINISM_LOG
	err := os.write_entire_file(path, strings.to_string(sess.log))
	if err != nil {fmt.eprintfln("determinism: cannot write %s: %v", path, err)}
}

@(private = "file")
finish :: proc(a, b: ^Session) {
	if a != nil && a.started {session_stop(a)}
	if b != nil && b.started {session_stop(b)}
	free(a)
	free(b)
}

// The side-by-side run: the same script on two servers whose maps sit at
// different addresses must hash alike at every tick.
@(test)
test_determinism_session :: proc(t: ^testing.T) {
	d, diverged_at, a, b := run_side_by_side(t, DETERMINISM_TICKS, {}, true, true)
	defer finish(a, b)
	if a == nil || b == nil {return}
	if !testing.expect(t, !diverged_at, divergence_text(d)) {return}
	testing.expect(t, maps_apart(a, b), "the two servers' maps sit at the same address")
	for sec in Hash_Section {
		if sec == .Containers || sec == .Gates {continue}
		if sec == .Rules && DETERMINISM_TICKS <= 7500 {continue} 	// (what the script does later)
		if sec == .Liquids && DETERMINISM_TICKS <= 2500 {continue}
		testing.expectf(t, len(a.seen[sec]) > 1, "the script never changed %v", sec)
	}
	for s in ([2]^Session{a, b}) {
		testing.expectf(
			t,
			s.mirror.mismatches == 0,
			"%d updates where prediction differed",
			s.mirror.mismatches,
		)
		testing.expectf(
			t,
			s.mirror.corrections == 0,
			"%d corrections, the first at tick %d",
			s.mirror.corrections,
			s.mirror.first_fix - s.script_at,
		)
		testing.expect(t, s.mirror.updates > DETERMINISM_TICKS / 2, "the mirror heard few updates")
	}
	for ok, i in a.checkpoint {
		testing.expectf(
			t,
			ok,
			"checkpoint %d: the mirror's chunks hash otherwise than the server's",
			i,
		)
	}
	testing.expect(t, len(a.checkpoint) > 0, "no checkpoint")
	for f in a.failures {testing.expect(t, false, f)}
}

// An introduced nondeterminism is caught by name, at its tick.
@(test)
test_divergence_named :: proc(t: ^testing.T) {
	Case :: struct {
		what:    Perturb_Kind,
		section: Hash_Section,
		path:    string,
	}
	cases := [?]Case {
		{.Entity_Yaw, .Entities, "entities[0].yaw"},
		{.Player_Velocity, .Players, "players[0].player.velocity.x"},
	}
	for c in cases {
		d, found, a, b := run_side_by_side(t, 600, {tick = 500, what = c.what}, true, false)
		defer finish(a, b)
		if !testing.expectf(t, found, "%v: no divergence", c.what) {continue}
		testing.expect_value(t, d.tick, 500)
		testing.expect_value(t, d.section, c.section)
		testing.expectf(
			t,
			strings.has_prefix(d.a, c.path) && strings.has_prefix(d.b, c.path),
			"%v: named %q vs %q, wanted %s",
			c.what,
			d.a,
			d.b,
			c.path,
		)
	}
}

// Two stepped servers hold the same pool slots for the same chunks after
// streaming and unloading.
@(test)
test_stepped_jobs_in_order :: proc(t: ^testing.T) {
	d, found, a, b := run_side_by_side(t, 400, {}, true, false)
	defer finish(a, b)
	if a == nil || b == nil {return}
	testing.expect(t, !found, divergence_text(d))
	slots :: proc(s: ^Session) -> [dynamic]u64 {
		out := make([dynamic]u64, context.temp_allocator)
		it: base.Pool_Iterator
		for c, h in base.pool_next(&s.srv.home.chunks.chunks, &it) {
			append(
				&out,
				u64(h) << 32 |
				u64(u32(c.pos.x)) ~
				u64(u32(c.pos.y)) << 11 ~
				u64(u32(c.pos.z)) << 22,
			)
		}
		return out
	}
	sa, sb := slots(a), slots(b)
	testing.expect(t, len(sa) > 100, "few chunks")
	testing.expect(t, slice.equal(sa[:], sb[:]), "the pool slots differ")
}
