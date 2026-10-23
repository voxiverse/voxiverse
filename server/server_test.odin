package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

import "../game"

// A scripted client: joins, then flies in a straight line, keeping the
// chunks it is sent (and dropping those it is told to), as the real client
// does. Checks the protocol flow and that memory on both sides stays bounded.

@(private = "file")
Fake_Client :: struct {
	endpoint:       game.Endpoint,
	has:            map[game.Chunk_Pos]struct{},
	welcome:        game.Welcome,
	welcomed:       bool,
	rejected:       string,
	scratch:        ^game.Block_Array,
	chunks:         int, // chunk messages received
	unloads:        int,
	player:         game.Player_Update, // the latest
	rules:          game.Rules,
	results:        [dynamic]game.Edit_Result,
	columns:        map[[2]i32]game.Column,
	column_updates: int,
	clock:          f64, // the last Time
	notices:        [dynamic]string, // (temp allocator)
	bulk_left:      int, // chunks a bulk edit sends again (after Bulk_Begin)
}

@(private = "file")
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
		m, ok := game.decode_server(p, c.scratch)
		if !testing.expect(t, ok, "server sent an invalid message") {continue}
		switch v in m {
		case game.Welcome:
			c.welcome, c.welcomed = v, true
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
		case game.Player_Update:
			c.player = v
		case game.Rules_Changed:
			c.rules = v.rules
		case game.Edit_Result:
			append(&c.results, v)
		case game.Column:
			if v.pos in c.columns {c.column_updates += 1}
			c.columns[v.pos] = v
		case game.Time:
			c.clock = v.time
		case game.Bulk_Begin:
			c.bulk_left = int(v.count)
		case game.Explosion,
		     game.Block_Changed,
		     game.Pong,
		     game.Player_Joined,
		     game.Player_Left,
		     game.Players,
		     game.Entity_Spawn,
		     game.Entity_Despawn,
		     game.Entities,
		     game.Entity_Hurt: // not checked here
		case game.Notice:
			if c.notices == nil {c.notices = make([dynamic]string, context.temp_allocator)}
			append(&c.notices, strings.clone(v.text, context.temp_allocator))
		case game.Unload_Chunk:
			testing.expectf(t, v.pos in c.has, "unload of chunk %v the client lacks", v.pos)
			delete_key(&c.has, v.pos)
			c.unloads += 1
		}
	}
}

@(private = "file")
wait_until :: proc(
	t: ^testing.T,
	c: ^Fake_Client,
	done: proc(c: ^Fake_Client) -> bool,
	timeout := 10 * time.Second,
) -> bool {
	deadline := time.tick_add(time.tick_now(), timeout)
	for !done(c) {
		if time.tick_diff(time.tick_now(), deadline) < 0 {return false}
		time.sleep(2 * time.Millisecond)
		fake_receive(t, c)
	}
	return true
}

@(test)
test_server_streams_and_unloads :: proc(t: ^testing.T) {
	RADIUS :: 3
	HEIGHT :: 2
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	srv: Server
	testing.expect(
		t,
		start(
			&srv,
			{
				seed = 5,
				view_radius = RADIUS,
				view_height = HEIGHT,
				workers = 2,
				allow_cheats = true,
			},
			{&pipe, .Server},
		),
	)

	c := Fake_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)

	fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "test"})
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
		center := game.chunk_of({i32(pos.x), i32(pos.y), i32(pos.z)})
		@(static) step_center: game.Chunk_Pos
		step_center = center
		ok := wait_until(
		t,
		&c,
		proc(c: ^Fake_Client) -> bool {
			// Everything within the area of the new center has arrived.
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
		st := stats(&srv)
		max_client = max(max_client, len(c.has))
		max_server = max(max_server, st.chunks_loaded)
		if step == 1 {arena_after_first_stretch = st.arena_used}
		testing.expect(t, st.arrays_allocated <= block_capacity(&srv))
	}
	// Bounded: the client holds at most its area plus the drop margin, the
	// server at most its pool, and the session arena stopped growing early.
	testing.expectf(
		t,
		max_client <= game.interest_count(RADIUS + 1, HEIGHT + 1),
		"client held %d chunks",
		max_client,
	)
	final := stats(&srv)
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
	testing.expect(t, stop(&srv))
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
			first = game.Hello{game.PROTOCOL_VERSION + 1, "old"},
			reason = "protocol version mismatch",
		},
		{first = game.Input{}, reason = "message before hello"},
		{first = game.Teleport{}, reason = "message before hello"},
		// Cheats are for players: not before hello, even where allowed.
		{first = game.Admin{"explode 0 0 0 8"}, reason = "message before hello", cheats = true},
		{first = game.Admin{"explode 0 0 0 8"}, reason = "cheats are not allowed", hello = true},
		{first = game.Fire{}, reason = "cheats are not allowed", hello = true},
		{raw = {0xee, 1, 2}, reason = "invalid message"},
	}
	for tc in cases {
		pipe: game.Pipe
		game.pipe_init(&pipe)
		srv: Server
		testing.expect(
			t,
			start(
				&srv,
				{
					seed = 1,
					view_radius = 2,
					view_height = 1,
					workers = 1,
					allow_cheats = tc.cheats,
				},
				{&pipe, .Server},
			),
		)
		c := Fake_Client {
			endpoint = {&pipe, .Client},
			scratch  = new(game.Block_Array),
		}
		if tc.raw != nil {
			game.send(c.endpoint, tc.raw)
		} else {
			if tc.hello {fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "tester"})}
			fake_send(&c, tc.first)
		}
		testing.expect(
			t,
			wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.rejected != ""}),
		)
		testing.expect_value(t, c.rejected, tc.reason)
		testing.expect(t, game.is_closed(c.endpoint))
		testing.expect(t, stop(&srv)) // a bad client is not a server failure
		free(c.scratch)
		delete(c.has)
		delete(c.columns)
		game.pipe_destroy(&pipe)
	}
}

// The server moves the player from inputs, at most one per tick however
// fast they arrive, and acknowledges them.
@(test)
test_server_moves_player_from_inputs :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	srv: Server
	testing.expect(
		t,
		start(&srv, {seed = 5, view_radius = 2, view_height = 2, workers = 2}, {&pipe, .Server}),
	)
	c := Fake_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "test"})
	// Joined, and standing on the ground once its chunks exist.
	testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed}))
	for i in 1 ..= 60 { 	// a second of standing still lets it fall and land
		fake_send(&c, game.Input{u32(i), {}})
		time.sleep(game.TICK_DURATION)
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
		{1, 60, below, .Air}, // break the block underfoot: fine
		{2, 60, head, .Stone}, // place inside the player: no
		{3, 60, below + {0, 0, 30}, .Air}, // out of reach: no
		{4, 60, below + {0, -200, 0}, .Stone}, // not loaded: no
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

	// 90 inputs walking +x, all at once: no faster than one per tick.
	sent_at := time.tick_now()
	for i in 61 ..= 150 {
		fake_send(&c, game.Input{u32(i), {move = {0, 1}, yaw = -math.PI / 2}})
	}
	time.sleep(time.Second)
	fake_receive(t, &c)
	ticks := time.duration_seconds(time.tick_since(sent_at)) * game.TICK_RATE
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
	testing.expect(t, stop(&srv))
}

// An edit waits for the input it follows: one sent before the inputs that
// bring the player into reach is judged from where those inputs put him.
@(test)
test_edit_follows_its_input :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	srv: Server
	testing.expect(
		t,
		start(
			&srv,
			{seed = 5, view_radius = 2, view_height = 2, workers = 2, allow_cheats = true},
			{&pipe, .Server},
		),
	)
	c := Fake_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	defer delete(c.results)
	fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "test"})
	testing.expect(t, wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed}))

	// Hover in open air at y 100 (flying), where the chunks are all air.
	fake_send(&c, game.Teleport{{0.5, 100, 0.5}, 0, 0})
	seq: u32 = 0
	for i in 0 ..< 45 {
		seq += 1
		fake_send(&c, game.Input{seq, {buttons = {.Toggle_Fly} if i == 0 else {}}})
		time.sleep(game.TICK_DURATION)
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
	fake_send(&c, game.Edit{id = 1, after = seq + 30, pos = target, block = .Stone})
	for _ in 0 ..< 30 {
		seq += 1
		fake_send(&c, game.Input{seq, {move = {0, 1}, yaw = -math.PI / 2}})
		time.sleep(game.TICK_DURATION)
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
	testing.expect(t, stop(&srv))
}

// Paused alone, the world stands still (time, entities); open to the LAN,
// a freeze is ignored: someone else could be playing.
@(test)
test_server_freezes_for_the_local_player :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	srv: Server
	ok := start(
		&srv,
		{seed = 5, view_radius = 2, view_height = 1, workers = 1, allow_cheats = true},
		{&pipe, .Server},
	)
	if !testing.expect(t, ok) {return}
	defer stop(&srv)
	c := Fake_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	defer delete(c.results)
	fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "solo"})
	testing.expect(
		t,
		wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return c.welcomed && c.clock > 0}),
	)
	@(static) before: f64
	freeze(&srv, true)
	time.sleep(1100 * time.Millisecond) // a Time sent after the freeze
	fake_receive(t, &c)
	before = c.clock
	time.sleep(2100 * time.Millisecond) // two more Time messages
	fake_receive(t, &c)
	testing.expectf(t, c.clock == before, "time went on while frozen: %v -> %v", before, c.clock)

	freeze(&srv, false)
	testing.expect(
		t,
		wait_until(
			t,
			&c,
			proc(c: ^Fake_Client) -> bool {return c.clock > before},
			3 * time.Second,
		),
		"time did not go on after the freeze",
	)

	// Open to the LAN: freezing does nothing.
	fake_send(&c, game.Admin{"open_lan"})
	time.sleep(100 * time.Millisecond)
	freeze(&srv, true)
	time.sleep(1100 * time.Millisecond)
	fake_receive(t, &c)
	before = c.clock
	time.sleep(2100 * time.Millisecond)
	fake_receive(t, &c)
	testing.expectf(t, c.clock > before, "a world open to the LAN froze at %v", before)
}

// Admin commands answer: what they did, how to use them when the
// arguments are wrong, and that an unknown one is unknown.
@(test)
test_admin_commands :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	srv: Server
	ok := start(
		&srv,
		{seed = 5, view_radius = 2, view_height = 1, workers = 1, allow_cheats = true},
		{&pipe, .Server},
	)
	if !testing.expect(t, ok) {return}
	defer stop(&srv)
	c := Fake_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)
	defer delete(c.columns)
	fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "admin"})
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
		{"fill 0 60 0 1 61 1 bedrock", "Usage: fill <x1 y1 z1 x2 y2 z2> <block>"},
		{"sphere 0 0 0 99 air", "Usage: sphere <x y z> <radius> <block>"},
		{"time", "Usage: time <0..1 | sunrise | day | noon | sunset | night | midnight>"},
		{"time teatime", "Usage: time <0..1 | sunrise | day | noon | sunset | night | midnight>"},
		{"summonx", "Unknown server command: summonx"},
		{"summon rocket", "Usage: summon [kind]"},
		{"fill -100 0 -100 100 60 100 dirt", "fill: too big (at most 262144 blocks)"},
	}
	for tc in cases {
		clear(&c.notices)
		fake_send(&c, game.Admin{tc.command})
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
}

// A server that cannot listen (the port is taken) fails to start, cleanly:
// nothing leaks, and the first one runs on.
@(test)
test_server_start_fails_cleanly :: proc(t: ^testing.T) {
	config := Config {
		seed        = 3,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		listen      = true,
	}
	first: Server
	if !testing.expect(t, start(&first, config, {})) {return}
	defer testing.expect(t, stop(&first))
	config.port = first.host.socket.port
	second: Server
	{
		context.logger = log.nil_logger() // its error is the point
		testing.expect(t, !start(&second, config, {}), "two servers on one port")
	}
	testing.expect(
		t,
		mem.check_zero(mem.ptr_to_bytes(&second)),
		"a failed start left state behind",
	)
}
