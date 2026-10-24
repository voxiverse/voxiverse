package server

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../game"
import "../worldgen"

// M5's exit check: save -> quit -> load gives back exactly the world that
// was left (edited blocks, the player, the time, the seed), and edits survive their
// chunks being unloaded and loaded again.

@(private = "file")
Save_Client :: struct {
	key:      game.Account_Key,
	endpoint: game.Endpoint,
	scratch:  ^game.Block_Array,
	arrays:   game.Block_Arrays,
	chunks:   map[game.Chunk_Pos]game.Chunk_Blocks,
	welcome:  game.Welcome,
	welcomed: bool,
	player:   game.Player_Update,
	turned:   Maybe([2]f32), // yaw, pitch of the first teleported update
	results:  map[u32]game.Edit_Result,
	seq:      u32,
	time:     Maybe(f64), // the last Time received
	look:     [2]f32, // yaw, pitch of the last input sent (idle ones keep it)
}

@(private = "file")
client_open :: proc(c: ^Save_Client, pipe: ^game.Pipe) {
	c^ = {
		endpoint = {pipe, .Client},
		scratch  = new(game.Block_Array),
	}
	game.block_arrays_init(&c.arrays, 4096)
}

@(private = "file")
client_close :: proc(c: ^Save_Client) {
	free(c.scratch)
	game.block_arrays_destroy(&c.arrays)
	delete(c.chunks)
	delete(c.results)
}

@(private = "file")
pump :: proc(t: ^testing.T, c: ^Save_Client) {
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(c.endpoint, &packets)
	for p in packets {
		defer game.packet_free(c.endpoint, p)
		m, ok := game.decode_server(p, c.scratch)
		if !testing.expect(t, ok) {continue}
		#partial switch v in m {
		case game.Challenge:
			send(c, game.Proof{game.account_sign(&c.key, v.nonce)})
		case game.Welcome:
			c.welcome, c.welcomed = v, true
		case game.Chunk_Message:
			b := game.Chunk_Blocks {
				uniform = v.uniform,
			}
			if !v.is_uniform {
				b.array, _ = game.block_arrays_take(&c.arrays)
				b.array^ = c.scratch^
			}
			if old, had := &c.chunks[v.pos]; had {game.chunk_release(old, &c.arrays)}
			c.chunks[v.pos] = b
		case game.Unload_Chunk:
			if old, had := &c.chunks[v.pos]; had {
				game.chunk_release(old, &c.arrays)
				delete_key(&c.chunks, v.pos)
			}
		case game.Player_Update:
			c.player = v
			if v.teleported && c.turned == nil {c.turned = [2]f32{v.yaw, v.pitch}}
		case game.Time:
			c.time = v.time
		case game.Edit_Result:
			c.results[v.id] = v
			if b, had := &c.chunks[game.chunk_of(v.pos)];
			   had {game.chunk_set(b, &c.arrays, game.local_of(v.pos), v.block)}
		}
	}
}

@(private = "file")
send :: proc(c: ^Save_Client, m: game.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	game.encode_client(&w, m)
	game.send(c.endpoint, w.buf[:])
}

@(private = "file")
block_at :: proc(c: ^Save_Client, p: game.Block_Pos) -> (game.Block, bool) {
	b, ok := &c.chunks[game.chunk_of(p)]
	if !ok {return .Air, false}
	return game.chunk_get(b, game.local_of(p)), true
}

// tick sends one input and waits a tick, pumping messages.
@(private = "file")
tick :: proc(t: ^testing.T, c: ^Save_Client, input: game.Player_Input = {}) {
	if c.welcomed { 	// (nothing before: the handshake)
		c.seq += 1
		c.look = {input.yaw, input.pitch}
		send(c, game.Input{c.seq, input})
	}
	time.sleep(game.TICK_DURATION)
	pump(t, c)
}

// until ticks (sending idle inputs, looking the same way) until done or 15
// seconds pass.
@(private = "file")
until :: proc(t: ^testing.T, c: ^Save_Client, done: proc(c: ^Save_Client) -> bool) -> bool {
	deadline := time.tick_add(time.tick_now(), 15 * time.Second)
	for !done(c) {
		if time.tick_diff(time.tick_now(), deadline) < 0 {return false}
		tick(t, c, {yaw = c.look[0], pitch = c.look[1]})
	}
	return true
}

@(private = "file")
fresh_dir :: proc(name: string) -> string {
	dir := filepath.join({"build", "test", name}, context.temp_allocator) or_else name
	os.remove_all(dir)
	return dir
}

@(private = "file")
landed :: proc(c: ^Save_Client) -> bool {
	return c.welcomed && c.player.acked == c.seq && c.player.state.on_ground && len(c.chunks) > 50
}

@(test)
test_save_round_trip :: proc(t: ^testing.T) {
	dir := fresh_dir("save_round_trip")
	defer os.remove_all(dir)
	Edit :: struct {
		pos:   game.Block_Pos,
		block: game.Block,
	}
	edits: [dynamic]Edit
	defer delete(edits)
	left_at: game.Player_State
	left_time: f64

	// Session 1: land, edit, walk a little, quit.
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		config := Config {
			seed         = 77,
			view_radius  = 3,
			view_height  = 2,
			workers      = 2,
			allow_cheats = true,
			save_dir     = dir,
		}
		testing.expect(t, start(&srv, config, {&pipe, .Server}))
		c: Save_Client
		client_open(&c, &pipe)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		if !testing.expect(t, until(t, &c, landed), "never landed") {
			stop(&srv)
			return
		}
		feet := c.player.state.position
		below := game.Block_Pos {
			i32(math.floor(feet.x)),
			i32(math.floor(feet.y)) - 1,
			i32(math.floor(feet.z)),
		}
		wanted := []Edit {
			{below, .Air}, // the ground under the player, and under that
			{below + {0, -1, 0}, .Air},
			{below + {0, 1, 2}, .Stone},
			{below + {0, 2, 2}, .Lamp},
			{below + {-2, 1, 0}, .Gravel},
		}
		for e, i in wanted {
			send(&c, game.Edit{u32(i + 1), c.seq, e.pos, e.block})
		}
		@(static) count: int
		count = len(wanted)
		testing.expect(
			t,
			until(t, &c, proc(c: ^Save_Client) -> bool {return len(c.results) == count}),
		)
		for e, i in wanted {
			r := c.results[u32(i + 1)]
			if testing.expectf(t, r.accepted, "edit %d refused", i + 1) {append(&edits, e)}
		}
		send(&c, game.Command{"time 0.9"}) // late evening
		c.time = nil
		for _ in 0 ..< 20 {tick(t, &c, {move = {0, 1}, yaw = 0.7, pitch = -0.3})} 	// walk a bit, looking that way
		testing.expect(
			t,
			until(t, &c, proc(c: ^Save_Client) -> bool {return c.player.acked == c.seq}),
		)
		left_at = c.player.state
		left_time = c.time.? or_else -1
		testing.expectf(t, abs(left_time - 0.9) < 0.01, "time %v after setting 0.9", left_time)
		testing.expect(t, stop(&srv), "the save failed")
	}
	testing.expect(
		t,
		os.exists(filepath.join({dir, UNIVERSE_FILE}, context.temp_allocator) or_else "") &&
		os.exists(
			filepath.join({home_dir(dir, 77), WORLD_FILE}, context.temp_allocator) or_else "",
		),
	)

	// Session 2: same directory, another seed in the config: the saved world wins.
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		config := Config {
			seed         = 12345,
			view_radius  = 3,
			view_height  = 2,
			workers      = 2,
			allow_cheats = true,
			save_dir     = dir,
		}
		testing.expect(t, start(&srv, config, {&pipe, .Server}))
		defer stop(&srv)
		testing.expect_value(t, srv.config.seed, 77)
		c: Save_Client
		client_open(&c, &pipe)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		testing.expect(
			t,
			until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed && len(c.chunks) > 100}),
		)
		d := c.welcome.spawn - left_at.position
		testing.expectf(
			t,
			abs(d.x) + abs(d.y) + abs(d.z) < 1e-4,
			"joined at %v, left at %v",
			c.welcome.spawn,
			left_at.position,
		)
		// The clock goes on from when they left (it ran up to a second
		// after the last Time they saw).
		testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return c.time != nil}))
		now := c.time.? or_else -1
		testing.expectf(
			t,
			now >= left_time && now - left_time < 2.0 / f64(game.RULES_DEFAULTS.day_length),
			"time %v after loading, %v before quitting",
			now,
			left_time,
		)
		// Looking where they looked when they left.
		testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return c.turned != nil}))
		look := c.turned.? or_else {}
		testing.expectf(
			t,
			abs(look[0] - 0.7) < 1e-5 && abs(look[1] + 0.3) < 1e-5,
			"looking at %v after loading, %v before",
			look,
			[2]f32{0.7, -0.3},
		)
		for e in edits {
			got, ok := block_at(&c, e.pos)
			testing.expectf(
				t,
				ok && got == e.block,
				"block %v: %v after loading, %v before quitting",
				e.pos,
				got,
				e.block,
			)
		}
	}
}

@(test)
test_edits_survive_unloading :: proc(t: ^testing.T) {
	pipe: game.Pipe
	game.pipe_init(&pipe)
	defer game.pipe_destroy(&pipe)
	srv: Server
	// No directory: unloaded edits are kept in memory for the session.
	testing.expect(
		t,
		start(
			&srv,
			{
				seed = 8,
				generator = .Classic,
				view_radius = 2,
				view_height = 2,
				workers = 2,
				allow_cheats = true,
			},
			{&pipe, .Server},
		),
	)
	defer stop(&srv)
	c: Save_Client
	client_open(&c, &pipe)
	defer client_close(&c)
	c.key = test_key("test")
	send(&c, test_hello("test"))
	until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
	testing.expect(t, until(t, &c, landed))
	feet := c.player.state.position
	target := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)) + 1,
		i32(math.floor(feet.z)),
	}
	send(&c, game.Edit{1, c.seq, target, .Lamp})
	testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return len(c.results) == 1}))
	testing.expect(t, c.results[1].accepted)

	// Far away (the chunk is unloaded on both sides), then back.
	send(&c, game.Teleport{feet + {3000, 0, 0}, 0, 0})
	@(static) far: game.Block_Pos
	far = target
	testing.expect(
		t,
		until(
			t,
			&c,
			proc(c: ^Save_Client) -> bool {return(
					game.chunk_of(far) not_in c.chunks &&
					c.player.state.position.x > 2000 \
				)},
		),
	)
	send(&c, game.Teleport{feet, 0, 0})
	testing.expect(
		t,
		until(t, &c, proc(c: ^Save_Client) -> bool {return game.chunk_of(far) in c.chunks}),
	)
	got, _ := block_at(&c, target)
	testing.expectf(t, got == .Lamp, "the edit was forgotten: %v", got)
}

@(test)
test_damaged_region_is_moved_aside :: proc(t: ^testing.T) {
	dir := fresh_dir("save_damaged")
	defer os.remove_all(dir)
	// A world with one edit, saved.
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		testing.expect(
			t,
			start(
				&srv,
				{seed = 9, view_radius = 2, view_height = 2, workers = 2, save_dir = dir},
				{&pipe, .Server},
			),
		)
		c: Save_Client
		client_open(&c, &pipe)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		testing.expect(t, until(t, &c, landed))
		feet := c.player.state.position
		send(
			&c,
			game.Edit {
				1,
				c.seq,
				{i32(math.floor(feet.x)) + 1, i32(math.floor(feet.y)), i32(math.floor(feet.z))},
				.Stone,
			},
		)
		testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return len(c.results) == 1}))
		testing.expect(t, stop(&srv))
	}
	// Damage every region file.
	regions := filepath.join({home_dir(dir, 9), "regions"}, context.temp_allocator) or_else dir
	entries, _ := os.read_all_directory_by_path(regions, context.temp_allocator)
	damaged := 0
	for e in entries {
		data, err := os.read_entire_file_from_path(e.fullpath, context.temp_allocator)
		if err != nil || len(data) < 20 {continue}
		data[len(data) / 2] ~= 0xff
		testing.expect(t, os.write_entire_file(e.fullpath, data) == nil)
		damaged += 1
	}
	testing.expect(t, damaged > 0, "no region file was written")
	// Loading reports it (an error, quieted here) and carries on without it.
	quiet := context.logger
	quiet.lowest_level = .Fatal
	context.logger = quiet
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		testing.expect(
			t,
			start(
				&srv,
				{seed = 9, view_radius = 2, view_height = 2, workers = 2, save_dir = dir},
				{&pipe, .Server},
			),
		)
		c: Save_Client
		client_open(&c, &pipe)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		testing.expect(t, until(t, &c, landed), "the world did not load past the damaged file")
		testing.expect(t, stop(&srv))
	}
	entries, _ = os.read_all_directory_by_path(regions, context.temp_allocator)
	aside := 0
	for e in entries {if strings.contains(e.name, ".damaged-") {aside += 1}}
	testing.expect_value(t, aside, damaged)
}

// A world keeps its generator: one saved before generators had names is
// classic; one made by a generator this game lacks is not loaded.
@(test)
test_world_generator_kept :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "generator"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	path := filepath.join({dir, WORLD_FILE}, context.temp_allocator) or_else ""
	config := Config {
		seed        = 5,
		view_radius = 2,
		view_height = 1,
		workers     = 1,
		save_dir    = dir,
	}
	write :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]u8)text)}

	write(path, "format = 2\nseed = 9\n")
	srv: Server
	if testing.expect(t, start(&srv, config, {})) {
		testing.expect_value(t, srv.home.generator, worldgen.Kind.Classic)
		testing.expect(t, stop(&srv))
	}
	moved := filepath.join({home_dir(dir, 9), WORLD_FILE}, context.temp_allocator) or_else ""
	saved, _ := os.read_entire_file_from_path(moved, context.temp_allocator)
	testing.expect(t, strings.contains(string(saved), "generator = classic"), "not written back")

	os.remove_all(dir)
	os.make_directory_all(dir)
	write(path, "format = 2\nseed = 9\ngenerator = moon\n")
	{
		context.logger = log.nil_logger() // its error is the point
		testing.expect(t, !start(&srv, config, {}), "a world from an unknown generator loaded")
	}
}

// home_dir: the home world's directory in a universe of seed.
@(private)
home_dir :: proc(dir: string, seed: i64) -> string {
	return(
		filepath.join(
			{dir, WORLDS_DIR, game.address_dir(game.address_derive(u64(seed)))},
			context.temp_allocator,
		) or_else dir \
	)
}
