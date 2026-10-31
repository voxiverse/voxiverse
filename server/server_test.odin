package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "common:game"

// A scripted client: joins, then flies in a straight line, keeping the
// chunks it is sent (and dropping those it is told to), as the real client
// does. Checks the protocol flow and that memory on both sides stays bounded.

@(private)
Fake_Client :: struct {
	endpoint:       game.Endpoint,
	stepper:        ^Harness, // wait_until steps this harness's ticks (nil: real time)
	key:            game.Account_Key, // (fake_hello)
	has:            map[game.Chunk_Pos]struct{},
	welcome:        game.Welcome,
	welcomed:       bool,
	rejected:       string,
	scratch:        ^game.Block_Array,
	chunks:         int, // chunk messages received
	packs_changed:  u64, // the content of the last Packs_Changed
	unloads:        int,
	player:         game.Own_Player, // the latest
	rx:             State_Rx, // (made when first needed, in the temp allocator)
	rules:          game.Rules,
	results:        [dynamic]game.Edit_Result,
	columns:        map[[2]i32]game.Column,
	column_updates: int,
	clock:          f64, // the world time, derived from the Clock record and the newest tick
	anchor:         Maybe(game.Clock), // the last Clock record
	notices:        [dynamic]string, // (temp allocator)
	bulk_left:      int, // chunks a bulk edit sends again (after Bulk_Begin)
	variables:      string, // the last Variables (temp allocator)
	selection:      [2]Maybe(game.Block_Pos), // the last Selection
}

// fake_hello: c joins as the character name (of the account test_key(name)),
// waiting until it is welcomed (as a real client sends nothing before).
@(private)
fake_hello :: proc(t: ^testing.T, c: ^Fake_Client, name: string) -> bool {
	c.key = test_key(name)
	fake_send(c, test_hello(name))
	return wait_until(t, c, proc(c: ^Fake_Client) -> bool {return c.welcomed || c.rejected != ""})
}

@(private)
fake_send :: proc(c: ^Fake_Client, m: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, m)
	game.send(c.endpoint, w.buf[:])
}

@(private = "file")
fake_receive :: proc(t: ^testing.T, c: ^Fake_Client) {
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(c.endpoint, &packets)
	for p in packets {
		defer game.packet_free(c.endpoint, p)
		m, ok := game.decode_server(p, c.scratch, test_reg())
		if !testing.expect(t, ok, "server sent an invalid message") {continue}
		if c.rx.schema.kinds == nil {state_rx_init(&c.rx, context.temp_allocator)}
		switch v in m {
		case game.Challenge:
			fake_send(c, game.Proof{game.account_sign(&c.key, v.nonce)})
		case game.Characters: // (tests name their character in Hello)
		case game.Packs, game.Pack_Part: // (no packs in these universes)
		case game.Packs_Changed:
			c.packs_changed = v.content
		case game.Welcome:
			c.welcome, c.welcomed, c.rules = v, true, v.rules
			rules := v.rules
			game.receiver_seed(&c.rx.rx, int(game.State_Kind.Rules), &rules)
		case game.Reject:
			c.rejected = v.reason
		case game.Chunk_Message:
			testing.expectf(
				t,
				[2]i32{v.pos.x, v.pos.z} in c.columns,
				"chunk %v before its column",
				v.pos,
			)
			if c.bulk_left > 0 {
				c.bulk_left -= 1
			} else {
				testing.expectf(t, v.pos not_in c.has, "chunk %v sent twice", v.pos)
			}
			c.has[v.pos] = {}
			c.chunks += 1
		case game.State_Message, game.Snapshot_Message:
			for g in state_rx_take(t, &c.rx, m) {
				if g.op == .Event {
					#partial switch game.Event_Kind(g.kind - len(game.State_Kind)) {
					case .Notice:
						if c.notices ==
						   nil {c.notices = make([dynamic]string, context.temp_allocator)}
						append(
							&c.notices,
							strings.clone((^game.Notice)(g.value).text, context.temp_allocator),
						)
					}
					continue
				}
				#partial switch game.State_Kind(g.kind) {
				case .Own_Player:
					c.player = (^game.Own_Player)(g.value)^
				case .Rules:
					c.rules = (^game.Rules)(g.value)^
				case .Clock:
					c.anchor = (^game.Clock)(g.value)^
				case .Variables:
					c.variables = strings.clone(
						(^game.Variables)(g.value).text,
						context.temp_allocator,
					)
				case .Selection:
					c.selection = (^game.Selection)(g.value).corners
				}
			}
			if a, anchored := c.anchor.?; anchored {
				behind := f64(c.rx.rx.tick - a.tick) * f64(game.TICK_SECONDS)
				c.clock = game.advance_time(a.time, max(behind, 0), &c.rules)
			}
		case game.Edit_Result:
			append(&c.results, v)
		case game.Column:
			if v.pos in c.columns {c.column_updates += 1}
			c.columns[v.pos] = v
		case game.Bulk_Begin:
			c.bulk_left = int(v.count)
		case game.Pong, game.Stats_Page, game.Telemetry_Ack, game.World_Changed: // not checked here
		case game.Unload_Chunk:
			testing.expectf(t, v.pos in c.has, "unload of chunk %v the client lacks", v.pos)
			delete_key(&c.has, v.pos)
			c.unloads += 1
		}
	}
}

@(private)
wait_until :: proc(
	t: ^testing.T,
	c: ^Fake_Client,
	done: proc(c: ^Fake_Client) -> bool,
	timeout := 10 * time.Second,
) -> bool {
	h := c.stepper
	assert(h != nil, "wait_until steps a harness: give the client its stepper")
	// (ticks, not time: the same on every machine)
	for _ in 0 ..< int(time.duration_seconds(timeout) * game.TICK_RATE) {
		if done(c) {return true}
		harness_step(h)
		fake_receive(t, c)
	}
	return done(c)
}

@(test)
test_server_streams_and_unloads :: proc(t: ^testing.T) {
	RADIUS :: 3
	HEIGHT :: 2
	h: Harness
	srv := &h.srv
	testing.expect(
		t,
		harness_start(
			&h,
			{seed = 5, view_radius = RADIUS, view_height = HEIGHT, allow_cheats = true},
			local = true,
		),
	)

	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)

	fake_hello(t, &c, "test")
	testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed}))
	testing.expect_value(t, c.welcome.tick_rate, game.TICK_RATE)
	testing.expect(t, c.welcome.view_radius == RADIUS && c.welcome.view_height == HEIGHT)

	// The whole interest area arrives.
	area := game.interest_count(RADIUS, HEIGHT)
	@(static) want: int // test-local: wait_until takes a plain proc
	want = area
	testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return len(c.has) >= want}))
	testing.expect_value(t, len(c.has), area)

	// Fly 1500 blocks along x, two chunks at a time, letting each step fill in.
	pos := c.welcome.spawn
	arena_after_first_stretch: uint
	max_client, max_server := 0, 0
	STEP :: 2 * game.CHUNK_SIZE
	for step in 1 ..= 1500 / STEP {
		pos.x += STEP
		fake_send(&c, game.Teleport{pos, 0, 0})
		@(static) step_x: f64
		step_x = pos.x
		ok := wait_until(
		t,
		&c,
		proc(c: ^Fake_Client) -> bool {
			// Everything within the area of the new center (where the
			// player landed: out of the ground) has arrived.
			p := c.player.state.position
			if abs(p.x - step_x) > 0.01 {return false}
			step_center := game.chunk_of({i32(p.x), i32(p.y), i32(p.z)})
			for z in i32(-RADIUS) ..= RADIUS {
				for y in i32(-HEIGHT) ..= HEIGHT {
					for x in i32(-RADIUS) ..= RADIUS {
						if x * x + z * z > RADIUS * RADIUS {continue}
						if step_center + {x, y, z} not_in c.has {return false}
					}
				}
			}
			return true
		},
		)
		if !testing.expectf(t, ok, "step %d: area not filled", step) {break}
		st := stats(srv)
		max_client = max(max_client, len(c.has))
		max_server = max(max_server, st.chunks_loaded)
		if step == 1 {arena_after_first_stretch = st.arena_used}
		testing.expect(t, st.arrays_allocated <= block_capacity(srv))
	}
	// Bounded: the client holds at most its area plus the drop margin, the
	// server at most its pool, and the session arena stopped growing early.
	testing.expectf(
		t,
		max_client <= game.interest_count(RADIUS + 1, HEIGHT + 1),
		"client held %d chunks",
		max_client,
	)
	final := stats(srv)
	testing.expectf(
		t,
		final.arena_used == arena_after_first_stretch,
		"session arena grew from %d to %d bytes while flying",
		arena_after_first_stretch,
		final.arena_used,
	)
	testing.expect(t, c.unloads > 0)
	log.debugf(
		"flight: %d chunks sent, %d unloaded, server arena %d bytes",
		c.chunks,
		c.unloads,
		final.arena_used,
	)
	testing.expect(t, harness_stop(&h))
}

@(test)
test_server_rejects_bad_clients :: proc(t: ^testing.T) {
	Case :: struct {
		first:  game.Client_Message,
		raw:    []u8,
		reason: string,
		cheats: bool, // the client may cheat
		hello:  bool, // say hello first
	}
	cases := []Case {
		{
			first = game.Hello{game.PROTOCOL_VERSION + 1, test_key("old").account, "old", 0},
			reason = "protocol version mismatch",
		},
		{first = game.Input{}, reason = "message before hello"},
		{first = game.Teleport{}, reason = "message before hello"},
		// Commands are for players: not before hello, even where allowed.
		{first = game.Command{"summon"}, reason = "message before hello", cheats = true},
		{raw = {0xee, 1, 2}, reason = "invalid message"},
	}
	for tc in cases {
		h: Harness
		testing.expect(
			t,
			harness_start(
				&h,
				{seed = 1, view_radius = 2, view_height = 1, allow_cheats = tc.cheats},
				local = true,
			),
		)
		c := Fake_Client {
			endpoint = harness_local(&h),
			stepper  = &h,
			scratch  = new(game.Block_Array),
		}
		if tc.raw != nil {
			game.send(c.endpoint, tc.raw)
		} else {
			if tc.hello {fake_hello(t, &c, "tester")}
			fake_send(&c, tc.first)
		}
		testing.expect(
			t,
			wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.rejected != ""}),
		)
		testing.expect_value(t, c.rejected, tc.reason)
		testing.expect(t, game.is_closed(c.endpoint))
		testing.expect(t, harness_stop(&h)) // a bad client is not a server failure
		free(c.scratch)
		delete(c.has)
		delete(c.columns)
	}
}

// A player without the permission is told no, and stays.
@(test)
test_server_refuses_without_permission :: proc(t: ^testing.T) {
	h: Harness
	testing.expect(
		t,
		harness_start(&h, {seed = 1, view_radius = 2, view_height = 1}, local = true),
	)
	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	fake_hello(t, &c, "tester")
	fake_send(&c, game.Command{"summon"})
	fake_send(&c, game.Teleport{})
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return len(c.notices) >= 2}),
	)
	if len(c.notices) >= 2 {
		testing.expect_value(t, c.notices[0], "You may not use summon here (world.summon)")
		testing.expect_value(t, c.notices[1], "You may not do that here (teleport.tp)")
	}
	testing.expect_value(t, c.rejected, "")
	testing.expect(t, !game.is_closed(c.endpoint))
	testing.expect(t, harness_stop(&h))
}

// The server moves the player from inputs, at most one per tick however
// fast they arrive, and acknowledges them.
@(test)
test_server_moves_player_from_inputs :: proc(t: ^testing.T) {
	h: Harness
	srv := &h.srv
	testing.expect(
		t,
		harness_start(
			&h,
			{seed = 5, generator = .Classic, view_radius = 2, view_height = 2},
			local = true,
		),
	)
	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	fake_hello(t, &c, "test")
	// Joined, and standing on the ground once its chunks exist.
	testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed}))
	for i in 1 ..= 60 { 	// a second of standing still lets it fall and land
		fake_send(&c, game.Input{u32(i), {}, 0})
		harness_step(&h)
		fake_receive(t, &c)
	}
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.player.acked == 60}),
	)
	testing.expect(t, c.player.state.on_ground, "never landed")
	start_x := c.player.state.position.x
	defer delete(c.results)

	// Edits, checked from where the server has the player.
	feet := c.player.state.position
	below := game.Block_Pos {
		i32(math.floor(feet.x)),
		i32(math.floor(feet.y)) - 1,
		i32(math.floor(feet.z)),
	}
	head := below + {0, 2, 0}
	edits := []game.Edit {
		game.edit_plain(1, 60, below, .Air), // break the block underfoot: fine
		game.edit_plain(2, 60, head, .Stone), // place inside the player: no
		game.edit_plain(3, 60, below + {0, 0, 30}, .Air), // out of reach: no
		game.edit_plain(4, 60, below + {0, -200, 0}, .Stone), // not loaded: no
	}
	for e in edits {fake_send(&c, e)}
	// The results come at once; the column at the end of the tick.
	wait_until(t, &c, proc(c: ^Fake_Client) -> bool {
		return len(c.results) == 4 && c.column_updates >= 1
	})
	if len(c.results) == 4 {
		testing.expect(t, c.results[0].accepted && c.results[0].block == .Air)
		// Breaking the top block lowered the column: an update came.
		testing.expect(t, c.column_updates >= 1, "no column update after breaking the top block")
		for r in c.results[1:] {testing.expectf(t, !r.accepted, "edit %d accepted", r.id)}
		testing.expect(t, c.results[1].block == .Air) // the actual block, to undo a prediction
	}

	// 90 inputs walking +x, all at once: no faster than one per tick (the
	// server's ticks: a busy machine's server runs late ticks back to back).
	sent_at := stats(srv).tick
	for i in 61 ..= 150 {
		fake_send(&c, game.Input{u32(i), {move = {0, 1}, yaw = -math.PI / 2}, 0})
	}
	harness_step(&h, game.TICK_RATE)
	fake_receive(t, &c)
	ticks := f64(stats(srv).tick - sent_at)
	applied := f64(c.player.acked - 60)
	testing.expectf(
		t,
		applied <= ticks + game.INPUT_BUDGET_MAX + 1,
		"applied %v inputs in %v ticks",
		applied,
		ticks,
	)
	testing.expectf(
		t,
		c.player.state.position.x > start_x + 0.5,
		"did not walk: x %v -> %v",
		start_x,
		c.player.state.position.x,
	)
	testing.expect(t, harness_stop(&h))
}

// An edit waits for the input it follows: one sent before the inputs that
// bring the player into reach is judged from where those inputs put him.
@(test)
test_edit_follows_its_input :: proc(t: ^testing.T) {
	h: Harness
	testing.expect(
		t,
		harness_start(
			&h,
			{seed = 5, view_radius = 2, view_height = 2, allow_cheats = true},
			local = true,
		),
	)
	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	defer delete(c.results)
	fake_hello(t, &c, "test")
	testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed}))

	// Hover in open air at y 100 (flying), where the chunks are all air.
	fake_send(&c, game.Teleport{{0.5, 100, 0.5}, 0, 0})
	seq: u32 = 0
	for i in 0 ..< 45 {
		seq += 1
		fake_send(&c, game.Input{seq, {buttons = {.Toggle_Fly} if i == 0 else {}}, 0})
		harness_step(&h)
		fake_receive(t, &c)
	}
	@(static) want: u32
	want = seq
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.player.acked == want}),
	)
	testing.expect(t, c.player.state.flying, "not flying")
	start_x := c.player.state.position.x

	// Place a block 12 blocks ahead (out of reach now), after the 30 inputs
	// that fly there, sent before them.
	target := game.Block_Pos{12, 101, 0}
	fake_send(&c, game.edit_plain(1, seq + 30, target, .Stone))
	for _ in 0 ..< 30 {
		seq += 1
		fake_send(&c, game.Input{seq, {move = {0, 1}, yaw = -math.PI / 2}, 0})
		harness_step(&h)
		fake_receive(t, &c)
	}
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return len(c.results) == 1}),
	)
	testing.expectf(
		t,
		len(c.results) == 1 && c.results[0].accepted,
		"refused: judged before the inputs that brought it into reach (x %v -> %v)",
		start_x,
		c.player.state.position.x,
	)
	testing.expect(t, harness_stop(&h))
}

// Paused alone, the world stands still (time, entities); open to the LAN,
// a freeze is ignored: someone else could be playing.
@(test)
test_server_freezes_for_the_local_player :: proc(t: ^testing.T) {
	h: Harness
	srv := &h.srv
	ok := harness_start(
		&h,
		{seed = 5, view_radius = 2, view_height = 1, allow_cheats = true},
		local = true,
	)
	if !testing.expect(t, ok) {return}
	defer harness_stop(&h)
	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	defer delete(c.results)
	fake_hello(t, &c, "solo")
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed && c.clock > 0}),
	)
	@(static) before: f64
	// (a client that sends no inputs gets no snapshots: its time is carried on
	// from the newest tick it has heard, so each look pokes the server with one)
	seq: u32
	look :: proc(t: ^testing.T, h: ^Harness, c: ^Fake_Client, seq: ^u32) {
		seq^ += 1
		fake_send(c, game.Input{seq^, {}, 0})
		harness_step(h, 2)
		fake_receive(t, c)
	}
	freeze(srv, true)
	harness_step(&h, 33)
	look(t, &h, &c, &seq)
	before = c.clock
	harness_step(&h, 63)
	look(t, &h, &c, &seq)
	testing.expectf(t, c.clock == before, "time went on while frozen: %v -> %v", before, c.clock)

	freeze(srv, false)
	for _ in 0 ..< 3 * game.TICK_RATE {
		if c.clock > before {break}
		look(t, &h, &c, &seq)
	}
	testing.expect(t, c.clock > before, "time did not go on after the freeze")

	// Open to the LAN: freezing does nothing.
	fake_send(&c, game.Command{"open_lan"})
	harness_step(&h, 3)
	freeze(srv, true)
	harness_step(&h, 33)
	look(t, &h, &c, &seq)
	before = c.clock
	harness_step(&h, 63)
	look(t, &h, &c, &seq)
	testing.expectf(t, c.clock > before, "a world open to the LAN froze at %v", before)
}

// Admin commands answer: what they did, how to use them when the
// arguments are wrong, and that an unknown one is unknown.
@(test)
test_admin_commands :: proc(t: ^testing.T) {
	h: Harness
	ok := harness_start(
		&h,
		{seed = 5, view_radius = 2, view_height = 1, allow_cheats = true},
		local = true,
	)
	if !testing.expect(t, ok) {return}
	defer harness_stop(&h)
	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	fake_hello(t, &c, "admin")
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed && c.chunks > 10}),
	)
	// Beside the player: loaded.
	p := c.welcome.spawn
	x, y, z := i32(p.x) + 2, i32(p.y), i32(p.z)
	Case :: struct {
		command, answer: string,
	}
	cases := []Case {
		{
			fmt.tprintf("fill %d %d %d %d %d %d lamp", x, y, z, x + 1, y + 1, z + 1),
			"fill: 8 blocks changed",
		},
		{"fill 0 60 0 1 61 1 bedrock", "Usage: fill [x1 y1 z1 x2 y2 z2] <block>"},
		{"sphere 0 0 0 99 air", "Usage: sphere [x y z] <radius> <block> (no x y z: at pos1)"},
		{
			"time",
			"Usage: time set <0..1 | sunrise | day | noon | sunset | night | midnight> | add <hours> | query",
		},
		{
			"time teatime",
			"Usage: time set <0..1 | sunrise | day | noon | sunset | night | midnight> | add <hours> | query",
		},
		{"summonx", "Unknown server command: summonx"},
		{"summon rocket", "Usage: summon [kind] [count]"},
		{"fill -100 0 -100 100 60 100 dirt", "fill: too big (at most 262144 blocks)"},
		// World editing on the selection, kept by the server.
		{"sel", "Selection cleared"},
		{"fill stone", "&cSelect a box first (/pos1, /pos2), or give its corners"},
		{fmt.tprintf("pos1 %d %d %d", x, y, z), fmt.tprintf("pos1 %d %d %d", x, y, z)},
		{
			fmt.tprintf("pos2 %d %d %d", x + 1, y + 1, z + 1),
			fmt.tprintf("pos2 %d %d %d", x + 1, y + 1, z + 1),
		},
		{"fill glass", "fill: 8 blocks changed"},
		{"replace glass stone", "replace: 8 blocks changed"},
		{"sphere 1 air", "sphere: 4 blocks changed"}, // (a ball of 7 at a corner of the cube: 3 of it already air)
	}
	for tc in cases {
		clear(&c.notices)
		fake_send(&c, game.Command{tc.command})
		@(static) want: string
		want = tc.answer
		got := wait_until(
			t,
			&c,
			proc(c: ^Fake_Client) -> bool {return len(c.notices) > 0},
			2 * time.Second,
		)
		testing.expectf(t, got, "%q: no answer", tc.command)
		if got {testing.expectf(t, c.notices[0] == tc.answer, "%q: %q", tc.command, c.notices[0])}
	}
	// The client was told the selection (to draw it), and told it cleared.
	want_selection := [2]Maybe(game.Block_Pos) {
		game.Block_Pos{x, y, z},
		game.Block_Pos{x + 1, y + 1, z + 1},
	}
	testing.expect_value(t, c.selection, want_selection)
	fake_send(&c, game.Command{"sel"})
	cleared := wait_until(
		t,
		&c,
		proc(c: ^Fake_Client) -> bool {return c.selection == {}},
		2 * time.Second,
	)
	testing.expect(t, cleared, "the selection was not cleared")
}

// A server that cannot listen (the port is taken) fails to start, cleanly:
// nothing leaks, and the first one runs on.
@(test)
test_server_start_fails_cleanly :: proc(t: ^testing.T) {
	config := Config {
		rules       = quiet_rules(),
		seed        = 3,
		view_radius = 2,
		view_height = 1,
		listen      = true,
	}
	h: Harness
	if !testing.expect(t, harness_start(&h, config)) {return}
	defer testing.expect(t, harness_stop(&h))
	config.port = h.srv.host.socket.port
	config.stepped, config.net = true, &h.net // (the same simulated network)
	testing.expect(
		t,
		harness_refused(config),
		"two servers on one port, or a failed start left state",
	)
}

// The generator's settings: a player is told them when joining and when
// they change; they are saved with the world; regen remakes the land near.
@(test)
test_worldgen_settings :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "worldgen_settings"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		rules        = quiet_rules(),
		seed         = 11,
		view_radius  = 2,
		view_height  = 1,
		allow_cheats = true,
		save_dir     = dir,
	}
	{
		h: Harness
		if !testing.expect(t, harness_start(&h, config, local = true)) {return}
		c := Fake_Client {
			endpoint = harness_local(&h),
			stepper  = &h,
			scratch  = new(game.Block_Array),
		}
		defer free(c.scratch)
		defer delete(c.has)
		defer delete(c.columns)
		fake_hello(t, &c, "tuner")
		testing.expect(
			t,
			wait_until(
				t,
				&c,
				proc(c: ^Fake_Client) -> bool {return c.chunks > 20 && c.variables != ""},
			),
		)
		testing.expect(t, strings.contains(c.variables, "worldgen.tree_density = 1"), c.variables)
		fake_send(&c, game.Set_Rule{"worldgen.tree_density", "0"})
		testing.expect(
			t,
			wait_until(
				t,
				&c,
				proc(c: ^Fake_Client) -> bool {return strings.contains(
						c.variables,
						"worldgen.tree_density = 0",
					)},
			),
		)
		clear(&c.notices)
		fake_send(&c, game.Command{"regen 2"})
		testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {
				for n in c.notices {if strings.has_prefix(n, "regen: ") {return true}}
				return false
			}))
		made := false
		for n in c.notices {made ||= strings.has_prefix(n, "regen: ") && n != "regen: 0 chunks made again"}
		testing.expect(t, made, "regen made nothing")
		testing.expect(t, harness_stop(&h))
	}
	// Kept by the save.
	h: Harness
	srv := &h.srv
	if !testing.expect(t, harness_start(&h, config)) {return}
	testing.expect_value(t, srv.home.params.tree_density, 0)
	testing.expect_value(t, srv.home.chunks.gen.params.tree_density, 0)
	testing.expect(t, harness_stop(&h))
}

// Structures: save a build, paste it elsewhere, save that: the same file;
// turned a quarter and back: the same again.
@(test)
test_structures_round_trip :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "structures"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	h: Harness
	config := Config {
		rules        = quiet_rules(),
		seed         = 5,
		generator    = .Classic,
		view_radius  = 3,
		view_height  = 2,
		allow_cheats = true,
		save_dir     = dir,
	}
	if !testing.expect(t, harness_start(&h, config, local = true)) {return}
	defer harness_stop(&h)
	c := Fake_Client {
		endpoint = harness_local(&h),
		stepper  = &h,
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	fake_hello(t, &c, "builder")
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed && c.chunks > 100}),
	)
	y := i32(c.welcome.spawn.y) + 6
	@(static) answers: int
	answers = 0
	run :: proc(t: ^testing.T, c: ^Fake_Client, command: string) -> string {
		clear(&c.notices)
		fake_send(c, game.Command{command})
		got := wait_until(
			t,
			c,
			proc(c: ^Fake_Client) -> bool {return len(c.notices) > 0},
			5 * time.Second,
		)
		testing.expectf(t, got, "%q: no answer", command)
		return c.notices[0] if got else ""
	}
	// A little build in the air: a stone base, a lamp and glass on it.
	run(t, &c, fmt.tprintf("fill 0 %d 0 4 %d 2 stone", y, y))
	run(t, &c, fmt.tprintf("fill 1 %d 1 1 %d 1 lamp", y + 1, y + 1))
	run(t, &c, fmt.tprintf("fill 3 %d 0 3 %d 0 glass", y + 1, y + 2))
	answer := run(t, &c, fmt.tprintf("structure save hut 0 %d 0 4 %d 2", y, y + 2))
	testing.expectf(t, strings.has_prefix(answer, "structure hut saved: 5 x 3 x 3"), "%q", answer)
	file :: proc(dir, name: string) -> string {
		data, _ := os.read_entire_file_from_path(
			filepath.join(
				{dir, STRUCTURES_DIR, strings.concatenate({name, ".vxs"}, context.temp_allocator)},
				context.temp_allocator,
			) or_else "",
			context.temp_allocator,
		)
		return string(data)
	}
	testing.expect(t, len(file(dir, "hut")) > 0, "no file")
	// Pasted 10 east and saved again: the same file.
	answer = run(t, &c, fmt.tprintf("structure paste hut 10 %d 0", y))
	testing.expectf(t, strings.has_prefix(answer, "structure hut pasted"), "%q", answer)
	run(t, &c, fmt.tprintf("structure save copy 10 %d 0 14 %d 2", y, y + 2))
	testing.expect(t, file(dir, "copy") == file(dir, "hut"), "save, paste, save: a different file")
	// A quarter turn (3 wide, 5 deep), saved, and three more: home again.
	run(t, &c, fmt.tprintf("structure paste hut -10 %d 0 1", y))
	run(t, &c, fmt.tprintf("structure save turned -10 %d 0 -8 %d 4", y, y + 2))
	run(t, &c, fmt.tprintf("structure paste turned -20 %d 0 3", y))
	run(t, &c, fmt.tprintf("structure save back -20 %d 0 -16 %d 2", y, y + 2))
	testing.expect(
		t,
		file(dir, "back") == file(dir, "hut"),
		"four quarter turns: a different file",
	)
	testing.expect(t, strings.contains(run(t, &c, "structure list"), "hut"))
	testing.expect(
		t,
		strings.has_prefix(
			run(t, &c, "structure paste nothing 0 0 0"),
			"structure paste: no structure",
		),
	)
}
