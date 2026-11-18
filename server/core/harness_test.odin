package core

import "core:strings"
import "core:testing"

import "common:game"
import "common:netcode"
import "common:protocol"

@(private = "file")
HARNESS_INTEREST :: 39 // the chunks a player holds in the harness world: 13 columns, 3 high

// The fixed world is still: nobody to spawn, no random tick, no daylight, so
// what a test sees is what the test did.
@(test)
test_harness_world_is_still :: proc(t: ^testing.T) {
	sess: Session
	defer session_stop(&sess)
	if !testing.expect(t, session_start(&sess, {}, false, with = harness_world())) {return}
	_, landed := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			m := &(^Session)(data).mirror
			s := m.last_update.state
			return s.on_ground && m.last_update.acked > 0 && m.prediction.state == s
		}, &sess, 300)
	if !testing.expect(t, landed, "the player never landed") {return}
	m := &sess.mirror
	testing.expect_value(t, m.last_update.state.position.y, 0)
	clock := sess.h.srv.home.clock
	for i in 0 ..< 600 {
		session_step(&sess, false)
		if sess.h.srv.home.clock != clock {
			testing.expectf(t, false, "the clock moved at step %d", i)
			break
		}
	}
	// The world is whole (39 chunks: 13 columns of the radius 2, three high) and does not change.
	testing.expect_value(t, len(m.chunks), HARNESS_INTEREST)
	world := world_hash(&sess.h.srv)
	for _ in 0 ..< 60 {session_step(&sess, false)}
	testing.expect_value(t, entity_count(sess.h.srv.home), 0)
	testing.expect_value(t, world_hash(&sess.h.srv), world)
	testing.expect_value(t, sess.h.srv.home.clock, clock)
	testing.expect(t, chunks_agree(&sess), "the mirror's chunks differ from the server's")
	for f in sess.failures {testing.expect(t, false, f)}
}

@(test)
test_harness_refusals :: proc(t: ^testing.T) {
	net: netcode.Simnet
	netcode.simnet_init(&net)
	defer netcode.simnet_destroy(&net)
	config := harness_world()
	config.net = &net
	config.workers = 0
	// Not stepped.
	testing.expect(t, harness_refused(config), "a simulated network without stepped was taken")
	// With conditions of its own.
	config.stepped = true
	config.conditions = {
		loss = 0.1,
	}
	testing.expect(t, harness_refused(config), "a simulated network with conditions was taken")
}

// A second player joins beside the mirror over the harness's network: it is welcomed and
// plays, is told the game's records and the notices sent to it, and leaving ends its
// client as any leaving does.
@(private = "file")
Probe_Score :: struct {
	points: u32,
}

@(test)
test_harness_player_joins :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.listen = true
	config.game = Game {
		info = {id = "probe"},
		kinds = {states = {{name = "probe.score", value = Probe_Score}}},
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	p := new(Harness_Player)
	defer free(p)
	defer harness_player_free(p)
	defer session_stop(sess)
	harness_player_join(&sess.h, p, "guest")
	joined :: proc(data: rawptr) -> bool {
		sess := (^Session)(data)
		c := client_by_name(&sess.h.srv, "guest")
		return sess.mirror.welcomed && c != nil && c.state == .Playing
	}
	_, ok := harness_step_until(&sess.h, joined, sess, 600)
	if !testing.expect(t, ok, "the second player never joined") {return}
	harness_step(&sess.h, 2)
	testing.expect(t, p.welcomed)
	s := &sess.h.srv
	c := harness_player_client(p)
	testing.expect(t, c != nil && c != &s.clients[0], "the guest is the mirror's seat")

	score := Probe_Score{42}
	game_put(s, c, &score)
	notice(s, c, "hello guest")
	harness_step(&sess.h, 3)
	got := harness_player_record(p, Probe_Score)
	testing.expect(t, got != nil && got.points == 42, "the guest was not told its record")
	testing.expect(t, len(p.notices) == 1 && p.notices[0] == "hello guest")
	testing.expect(
		t,
		mirror_game_record(&sess.mirror, Probe_Score) == nil,
		"the mirror was told the guest's",
	)

	harness_player_leave(p)
	harness_step(&sess.h, 3 * game.TICK_RATE)
	testing.expect(
		t,
		harness_player_client(p) == nil || c.state != .Playing,
		"the guest is still playing",
	)
}

// A listening server tells whoever asks (LAN discovery, a saved server's status) the game
// it plays, by id and by name, and its players: what a Discover is answered decodes so.
@(test)
test_server_tells_its_game :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.listen = true
	config.name = "Probe night"
	config.game = Game {
		info = {id = "probe", name = "Probe"},
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	defer session_stop(sess)
	harness_step(&sess.h, game.TICK_RATE) // (the info is refreshed once a second)
	info, ok := protocol.decode_server_info(sess.h.srv.host.info[:])
	if !testing.expect(t, ok, "the server's info does not decode") {return}
	testing.expect_value(t, info.protocol, protocol.PROTOCOL_VERSION)
	testing.expect_value(t, info.name, "Probe night")
	testing.expect_value(t, info.game, "probe")
	testing.expect_value(t, info.game_name, "Probe")
	testing.expect_value(t, info.players, 1) // (the mirror)
	testing.expect_value(t, info.max_players, config.max_players)
}

// A server's name too long for the info is cut at a whole letter: cut in the middle of
// one, the info would carry text that is no UTF-8.
@(test)
test_server_info_cuts_at_a_letter :: proc(t: ^testing.T) {
	s := new(Server)
	defer free(s)
	name := strings.concatenate(
		{strings.repeat("a", protocol.MAX_SERVER_NAME - 1, context.temp_allocator), "é"},
		context.temp_allocator,
	)
	s.config.name = name
	s.config.game.info = {
		id   = "probe",
		name = name,
	}
	info := server_info(s)
	testing.expect_value(t, info.name, name[:protocol.MAX_SERVER_NAME - 1])
	testing.expect_value(t, info.game_name, name[:protocol.MAX_SERVER_NAME - 1])
}

// The mirror reads blocks and modes by the server's registry, as a client that took the
// server's packs does: it stands on a block of the game's pack and knows the game's mode
// (by the base registry alone it read past the end of its block table).
@(test)
test_mirror_stands_on_a_games_blocks :: proc(t: ^testing.T) {
	PACK :: `{"format": 1, "namespace": "floors", "version": "1.0.0", "title": "Floors", "requires": ["voxiverse"]}`
	BLOCKS :: `{"tile": {"textures": {"all": "voxiverse:cobblestone"}, "sound": "voxiverse:stone"}}`
	MODES :: `{"walker": {"abilities": ["health"], "kit": [], "rules": {}}}`
	files := [3]game.Pack_File {
		{"pack.json", transmute([]u8)string(PACK)},
		{"data/blocks/floors.json", transmute([]u8)string(BLOCKS)},
		{"data/game_modes/modes.json", transmute([]u8)string(MODES)},
	}
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.mode = "floors:walker"
	config.game = {
		info = {id = "floors", name = "Floors"},
		pack = {"floors", files[:]},
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {
		session_stop(sess)
		return
	}
	defer session_stop(sess)
	s := &sess.h.srv
	tile, _ := game.registry_block(s.registry, "floors:tile")
	testing.expect(t, int(tile) >= len(test_blocks().collision), "the tile is the base registry's")
	bulk_edit(
		s.home,
		{shape = Box{{-4, -1, -4}, {4, -1, 4}}, op = .Set, block = tile, partial = true},
		world_act(s.home, .Structure),
	)
	_, ok := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok) {return}
	harness_step(&sess.h, 30)
	testing.expect(t, sess.mirror.mode_known, "the mirror does not know the game's mode")
	testing.expect_value(t, sess.mirror.mismatches, 0)
}
