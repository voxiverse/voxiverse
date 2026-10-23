package server

import "core:log"
import "core:testing"
import "core:time"

import "../game"

// A scripted client: joins, then flies in a straight line, keeping the
// chunks it is sent (and dropping those it is told to), as the real client
// does. Checks the protocol flow and that memory on both sides stays bounded.

@(private = "file")
Fake_Client :: struct {
	endpoint: game.Endpoint,
	has:      map[game.Chunk_Pos]struct{},
	welcome:  game.Welcome,
	welcomed: bool,
	rejected: string,
	scratch:  ^game.Block_Array,
	chunks:   int, // chunk messages received
	unloads:  int,
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
			testing.expectf(t, v.pos not_in c.has, "chunk %v sent twice", v.pos)
			c.has[v.pos] = {}
			c.chunks += 1
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
			{seed = 5, view_radius = RADIUS, view_height = HEIGHT, workers = 2},
			{&pipe, .Server},
		),
	)

	c := Fake_Client {
		endpoint = {&pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	defer free(c.scratch)
	defer delete(c.has)

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
		fake_send(&c, game.Move{pos})
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
	}
	cases := []Case {
		{
			first = game.Hello{game.PROTOCOL_VERSION + 1, "old"},
			reason = "protocol version mismatch",
		},
		{first = game.Move{}, reason = "move before hello"},
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
				{seed = 1, view_radius = 2, view_height = 1, workers = 1},
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
		game.pipe_destroy(&pipe)
	}
}
