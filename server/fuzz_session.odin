package server

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

import "common:base"
import "common:base/fuzz"
import "common:game"

// The stateful fuzz targets (Q2b, docs/fuzzing.md): what happens after a message decodes.
// A stepped server (the harness's flat world) has one seat, the session's mirror on the
// pipe, which a case drives by hand: `net.server_session` sends it a sequence of client
// messages, `commands.player` runs one command line as an operator or as a guest. The server
// lives across cases (building one is a world start); it is built again after
// FUZZ_REBUILD_CASES cases, or at once when a case ended the seat.
//
// A case runs under the server's own allocator, not the case's: the server's memory is the
// fixture's, kept between cases, so the per-case leak check has nothing to say here (the
// server's own leak checks are the harness's). The temp allocator is emptied after each case.

FUZZ_REBUILD_CASES :: 50
FUZZ_SESSION_TICKS :: 64 // the most ticks a case sends messages on

Fuzz_Fixture :: struct {
	sess:  Session,
	up:    bool,
	cases: int, // run on this server
}

@(thread_local)
fuzz_fixture: Fuzz_Fixture

// fuzz_seat: the fixture's server with its seat welcomed and playing; made (again) when
// there is none, when the last case ended the seat, or after FUZZ_REBUILD_CASES cases.
fuzz_seat :: proc() -> ^Fuzz_Fixture {
	fx := &fuzz_fixture
	if fx.up {
		c := fuzz_client(&fx.sess.h.srv)
		if fx.cases < FUZZ_REBUILD_CASES && c != nil && c.state == .Playing {
			fx.cases += 1
			return fx
		}
		fuzz_seat_stop(fx)
	}
	context.allocator = runtime.heap_allocator()
	cfg := harness_world()
	cfg.max_players = 2
	if !session_start(&fx.sess, {}, false, no_sheep = true, with = cfg) {
		fuzz.fail("the fixture's server did not start")
		return fx
	}
	fx.up = true
	fx.cases = 1
	_, ok := harness_step_until(
		&fx.sess.h,
		proc(data: rawptr) -> bool {return (^Session)(data).mirror.welcomed},
		&fx.sess,
		200,
	)
	if !ok {fuzz.fail("the fixture's seat was never welcomed")}
	fx.sess.manual = true // (the case sends; mirror_receive keeps the pipe drained)
	for _ in 0 ..< 3 {harness_step(&fx.sess.h)}
	return fx
}

fuzz_seat_stop :: proc(fx: ^Fuzz_Fixture) {
	context.allocator = runtime.heap_allocator()
	session_stop(&fx.sess)
	fx^ = {}
}

// fuzz_client: the seat of the local player.
fuzz_client :: proc(s: ^Server) -> ^Client {
	for &c in s.clients {
		if _, local := c.link.(Local); local {return &c}
	}
	return nil
}

// fuzz_check_server: what must hold after any case on the fixture.
fuzz_check_server :: proc(fx: ^Fuzz_Fixture) {
	h := &fx.sess.h
	s := &h.srv
	harness_step(h)
	mirror_receive(&fx.sess)
	if len(fx.sess.failures) > 0 {
		reason := fx.sess.failures[0]
		clear(&fx.sess.failures) // (literals: not freed)
		fuzz.fail("the test client: %s", reason)
	}
	for n in fx.sess.mirror.notices {delete(n)}
	clear(&fx.sess.mirror.notices)
	state_hash(s)
	if lines := audit(s); len(lines) > 0 {
		fuzz.fail("the ledger does not balance after the case: %d items off", len(lines))
	}
	// The seat is playing, or it was ended whole: its slot reset (kicked for what it sent),
	// never half removed.
	for &c in s.clients {
		if c.state == .Free && c.name_len != 0 {fuzz.fail("a freed seat still has a name")}
	}
}

// ---- net.server_session: the case is frames (a length byte, then that many bytes of one
// client message), one frame a tick.

fuzz_server_session :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	context.allocator = runtime.heap_allocator()
	defer free_all(context.temp_allocator)
	fx := fuzz_seat()
	sess := &fx.sess
	h := &sess.h
	rest := data
	ticks, sent, ended := 0, 0, 0
	for ticks < FUZZ_SESSION_TICKS && len(rest) > 0 {
		n := min(int(rest[0]), len(rest) - 1)
		msg := rest[1:][:n]
		rest = rest[1 + n:]
		if n > 0 {
			game.send(sess.mirror.endpoint, msg)
			sent += 1
		}
		harness_step(h)
		mirror_receive(sess)
		ticks += 1
		if ended == 0 {
			if c := fuzz_client(&h.srv); c == nil || c.state != .Playing {ended = ticks}
		}
	}
	harness_step(h)
	mirror_receive(sess)
	told := len(sess.mirror.notices)
	fuzz_check_server(fx)
	return fuzz.sig_mix(
		3,
		fuzz.sig_bucket(ended),
		fuzz.sig_bucket(sent),
		fuzz.sig_bucket(told),
		fuzz.sig_bucket(len(sess.mirror.entities)),
	)
}

// The recorded session: what the scripted mirror sends in its first FUZZ_RECORD_TICKS ticks.
FUZZ_RECORD_TICKS :: 1400

@(thread_local)
fuzz_recording: [dynamic][]u8

fuzz_record :: proc() -> [][]u8 {
	if len(fuzz_recording) > 0 {return fuzz_recording[:]}
	context.allocator = runtime.heap_allocator()
	sess: Session
	cfg := harness_world()
	cfg.max_players = 2
	sess.mirror.sent = &fuzz_recording
	if !session_start(&sess, {}, false, no_sheep = true, with = cfg) {return nil}
	for _ in 0 ..< FUZZ_RECORD_TICKS {session_step(&sess, true)}
	sess.mirror.sent = nil
	session_stop(&sess)
	free_all(context.temp_allocator)
	return fuzz_recording[:]
}

// fuzz_generate_session: a run of consecutive recorded messages, each left as it was, with one
// to three bytes changed, or replaced by raw bytes; framed by a length byte.
fuzz_generate_session :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	rec := fuzz_record()
	if len(rec) == 0 {return}
	start := 2 + base.rng_int_max(rng, max(len(rec) - 2, 1)) // (after the Hello and the Proof)
	count := 1 + base.rng_int_max(rng, FUZZ_SESSION_TICKS)
	interesting := [?]u8{0, 1, 2, 0x7f, 0x80, 0xfe, 0xff}
	for i in 0 ..< count {
		if start + i >= len(rec) {break}
		msg := make([dynamic]u8, context.temp_allocator)
		switch base.rng_int_max(rng, 40) {
		case 0:
			for _ in 0 ..< 1 + base.rng_int_max(rng, 40) {append(&msg, u8(base.rng_u32(rng)))}
		case 1, 2, 3, 4:
			append(&msg, ..rec[start + i])
			for _ in 0 ..< 1 + base.rng_int_max(rng, 3) {
				at := base.rng_int_max(rng, len(msg))
				if base.rng_int_max(rng, 2) == 0 {
					msg[at] = interesting[base.rng_int_max(rng, len(interesting))]
				} else {
					msg[at] = u8(base.rng_u32(rng))
				}
			}
		case:
			append(&msg, ..rec[start + i])
		}
		if len(msg) > 255 {continue}
		append(out, u8(len(msg)))
		append(out, ..msg[:])
	}
}

// ---- commands.player: the first byte's low bit says who runs the line (1: an operator, 0:
// a guest with the default role's grants), the rest is the line.

fuzz_commands_player :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	if len(data) == 0 {return 0}
	context.allocator = runtime.heap_allocator()
	defer free_all(context.temp_allocator)
	fx := fuzz_seat()
	h := &fx.sess.h
	s := &h.srv
	c := fuzz_client(s)
	if c == nil {return 1}
	operator := data[0] & 1 == 1
	// What `decode_client` lets through as a Command: valid UTF-8, at most MAX_ADMIN_TEXT bytes
	// (the edge validates text; a notice that echoes it is then text the client accepts).
	line, _ := strings.to_valid_utf8(
		string(data[1:min(len(data), game.MAX_ADMIN_TEXT + 1)]),
		"?",
		context.temp_allocator,
	)
	line = line[:min(len(line), game.MAX_ADMIN_TEXT)]
	for len(line) > 0 && !utf8.valid_string(line) {line = line[:len(line) - 1]}
	rest := line
	name, _ := strings.split_iterator(&rest, " ") // (the first word)

	owned := c.grants
	guest: [dynamic]game.Grant
	if !operator {
		resolve(&s.perms, "fuzz-guest", nil, false, &guest)
		c.grants = guest
	}
	_, node, known := command_usage(name)
	refused := !operator && known && node != "" && !allowed(s, c, node)
	before := state_hash(s)
	j := &c.world.journal
	head := j.head
	admin(s, c, line)
	after := state_hash(s)
	if !operator {
		c.grants = owned
		for g in guest {delete(g.pattern)}
		delete(guest)
	}
	// (not the Journal's section: reading it starts its next tick's hash over)
	moved: bool
	for sec in Hash_Section {
		if sec != .Journal && before.sections[sec] != after.sections[sec] {moved = true}
	}
	if refused && (moved || j.head != head) {
		fuzz.fail("%q, refused to a guest (%s), changed the world", line, node)
	}
	if operator && before.sections[.Chunks] != after.sections[.Chunks] {
		if j.head == head {fuzz.fail("%q changed the chunks without a journal entry", line)}
		for i in head ..< j.head {
			e := ring_at(j, i)
			a, live := action_info(j, e.action)
			if !live {continue}
			if a.kind != .Character || a.actor != client_name(c) {
				fuzz.fail("%q was journaled by %q, not the operator", line, a.actor)
			}
		}
	}
	fuzz_check_server(fx)
	return fuzz.sig_mix(
		4,
		u64(operator),
		fuzz.sig_text(name) if known else 0,
		u64(refused),
		u64(moved),
		u64(j.head != head),
	)
}

fuzz_generate_commands :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	pick :: proc(rng: ^base.Rng, options: []string) -> string {
		return options[base.rng_int_max(rng, len(options))]
	}
	b := strings.builder_make(context.temp_allocator)
	append(out, u8(base.rng_int_max(rng, 2)))
	name, usage, limits, _ := command_at(base.rng_int_max(rng, command_count()))
	strings.write_string(&b, name)
	shape := strings.clone(usage, context.temp_allocator)
	shape, _ = strings.replace_all(shape, "|", " ", context.temp_allocator)
	for r in "<>[](),;" {shape, _ = strings.replace_all(shape, string([]u8{u8(r)}), " ", context.temp_allocator)}
	words := strings.fields(shape, context.temp_allocator)
	numbers := []string {
		"0",
		"1",
		"-1",
		"2",
		"16",
		"31",
		"32",
		"33",
		"255",
		"256",
		"65536",
		"2147483647",
		"-2147483648",
		"4294967296",
		"99999999999999999999",
		"1e999",
		"-1e999",
		"nan",
		"inf",
		"0.5",
		"-0",
		"1.5e300",
		"~",
		"~1",
		"~-1",
		"~~",
		"~0.5",
		"~1e999",
		"~99999999",
	}
	things := []string {
		"@s",
		"@a",
		"@p",
		"@e",
		"@r",
		"@",
		"fuzz",
		"determinism",
		"nobody",
		"*",
		"stone",
		"voxiverse:stone",
		"voxiverse:oak_door[facing=north]",
		"voxiverse:nothing",
		"wheat_0",
		"water",
		"air",
		"sheep",
		"all",
		"default",
		"world.edit",
		"-world.edit",
		"midnight",
		"30m",
		"7d",
		"on",
		"off",
		"true",
		"false",
		"list",
		"info",
		"add",
		"remove",
		"set",
		"reload",
		"clear",
		"sel",
		"status",
		"cancel",
		"player",
		"system",
		"area",
		"radius",
		"world",
		"..",
		"../x",
		"/",
		"&cred",
		"%s",
		"\"",
		"é",
	}
	n := base.rng_int_range(rng, limits[0], limits[1] + 2)
	if limits[1] > 12 {n = base.rng_int_range(rng, limits[0], 12)}
	for _ in 0 ..< n {
		strings.write_byte(&b, ' ')
		switch base.rng_int_max(rng, 8) {
		case 0, 1, 2:
			strings.write_string(&b, pick(rng, numbers))
		case 3, 4:
			strings.write_string(&b, pick(rng, things))
		case 5, 6:
			if len(words) > 0 {strings.write_string(&b, pick(rng, words))}
		case:
			for _ in 0 ..< 1 + base.rng_int_max(rng, 400) {strings.write_byte(&b, 'a')}
		}
	}
	append(out, ..transmute([]u8)strings.to_string(b))
}

// fuzz_heard: the packets a stepped server sends one client in its first `ticks` ticks (the
// client session's generator replays them, mutated). Heap; the caller keeps them.
fuzz_heard :: proc(ticks: int) -> [][]u8 {
	context.allocator = runtime.heap_allocator()
	heard: [dynamic][]u8
	sess: Session
	cfg := harness_world()
	cfg.max_players = 2
	sess.mirror.heard = &heard
	if !session_start(&sess, {}, false, no_sheep = true, with = cfg) {return nil}
	for _ in 0 ..< ticks {session_step(&sess, true)}
	sess.mirror.heard = nil
	session_stop(&sess)
	free_all(context.temp_allocator)
	return heard[:]
}
