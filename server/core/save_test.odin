package core

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

import "common:access"
import "common:game"
import "common:protocol"
import "common:starmap"
import "common:worldgen"
import "server:store"

// The exit check: save -> quit -> load gives back exactly the world that
// was left (edited blocks, the player, the time, the seed), and edits survive their
// chunks being unloaded and loaded again.

@(private = "file")
Save_Client :: struct {
	key:       access.Account_Key,
	endpoint:  protocol.Endpoint,
	h:         ^Harness, // the ticks it waits on
	scratch:   ^game.Block_Array,
	arrays:    game.Block_Arrays,
	chunks:    map[game.Chunk_Pos]game.Chunk_Blocks,
	welcome:   protocol.Welcome,
	welcomed:  bool,
	player:    protocol.Own_Player,
	rx:        State_Rx,
	teleports: u8,
	turned:    Maybe([2]f32), // yaw, pitch of the first teleported record
	results:   map[u32]protocol.Edit_Result,
	seq:       u32,
	time:      Maybe(f64), // the last Clock received
	look:      [2]f32, // yaw, pitch of the last input sent (idle ones keep it)
}

@(private = "file")
client_open :: proc(c: ^Save_Client, h: ^Harness) {
	c^ = {
		endpoint = harness_local(h),
		h        = h,
		scratch  = new(game.Block_Array),
	}
	game.block_arrays_init(&c.arrays, 4096)
	state_rx_init(&c.rx)
}

@(private = "file")
client_close :: proc(c: ^Save_Client) {
	free(c.scratch)
	state_rx_destroy(&c.rx)
	game.block_arrays_destroy(&c.arrays)
	delete(c.chunks)
	delete(c.results)
}

@(private = "file")
pump :: proc(t: ^testing.T, c: ^Save_Client) {
	packets := make([dynamic]protocol.Packet, context.temp_allocator)
	protocol.receive(c.endpoint, &packets)
	for p in packets {
		defer protocol.packet_free(c.endpoint, p)
		m, ok := protocol.decode_server(p, c.scratch, test_reg())
		if !testing.expect(t, ok) {continue}
		#partial switch v in m {
		case protocol.Challenge:
			send(c, protocol.Proof{access.account_sign(&c.key, v.nonce)})
		case protocol.Welcome:
			c.welcome, c.welcomed = v, true
			rules := v.rules
			protocol.receiver_seed(&c.rx.rx, int(protocol.State_Kind.Rules), &rules)
		case protocol.Chunk_Message:
			b := game.Chunk_Blocks {
				uniform = v.uniform,
			}
			if !v.is_uniform {
				b.array, _ = game.block_arrays_take(&c.arrays)
				b.array^ = c.scratch^
			}
			if old, had := &c.chunks[v.pos]; had {game.chunk_release(old, &c.arrays)}
			c.chunks[v.pos] = b
		case protocol.Unload_Chunk:
			if old, had := &c.chunks[v.pos]; had {
				game.chunk_release(old, &c.arrays)
				delete_key(&c.chunks, v.pos)
			}
		case protocol.State_Message, protocol.Snapshot_Message:
			for g in state_rx_take(t, &c.rx, m) {
				#partial switch protocol.State_Kind(g.kind) {
				case .Own_Player:
					c.player = (^protocol.Own_Player)(g.value)^
					if c.player.teleports != c.teleports && c.turned == nil {
						c.turned = [2]f32{c.player.yaw, c.player.pitch}
					}
					c.teleports = c.player.teleports
				case .Clock:
					c.time = (^protocol.Clock)(g.value).time
				}
			}
		case protocol.Edit_Result:
			c.results[v.id] = v
			if b, had := &c.chunks[game.chunk_of(v.pos)];
			   had {game.chunk_set(b, &c.arrays, game.local_of(v.pos), v.block)}
		}
	}
}

@(private = "file")
send :: proc(c: ^Save_Client, m: protocol.Client_Message) {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	protocol.encode_client(&w, m)
	protocol.send(c.endpoint, w.buf[:])
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
		send(c, protocol.Input{c.seq, input, c.rx.rx.ack})
	}
	harness_step(c.h)
	pump(t, c)
}

// until ticks (sending idle inputs, looking the same way) until done or 15
// seconds' worth of ticks pass.
@(private = "file")
until :: proc(t: ^testing.T, c: ^Save_Client, done: proc(c: ^Save_Client) -> bool) -> bool {
	for _ in 0 ..< 15 * game.TICK_RATE {
		if done(c) {return true}
		tick(t, c, {yaw = c.look[0], pitch = c.look[1]})
	}
	return done(c)
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
	saved_time: f64 // the clock as the server wrote it

	// Session 1: land, edit, walk a little, quit.
	{
		h := new(Harness)
		defer free(h)
		config := Config {
			seed         = 77,
			view_radius  = 3,
			view_height  = 2,
			allow_cheats = true,
			save_dir     = dir,
		}
		testing.expect(t, harness_start(h, config, local = true))
		c: Save_Client
		client_open(&c, h)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		if !testing.expect(t, until(t, &c, landed), "never landed") {
			harness_stop(h)
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
			send(&c, protocol.edit_plain(u32(i + 1), c.seq, e.pos, e.block))
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
		// States are saved and loaded by name: a stair, a slab and a ladder (against a wall).
		{
			reg := test_reg()
			stair, _ := game.state_parse(reg, "stone_stairs[facing=south,half=top]")
			slab, _ := game.state_parse(reg, "planks_slab[type=double]")
			ladder, _ := game.state_parse(reg, "ladder[facing=west]")
			at :: proc(dx, dy, dz: i32, feet: [3]f64) -> game.Block_Pos {
				return {
					i32(math.floor(feet.x)) + dx,
					i32(math.floor(feet.y)) + dy,
					i32(math.floor(feet.z)) + dz,
				}
			}
			put :: proc(
				t: ^testing.T,
				c: ^Save_Client,
				text: string,
				where_: game.Block_Pos,
				want: game.Block,
			) -> bool {
				send(
					c,
					protocol.Command {
						fmt.tprintf(
							"fill %d %d %d %d %d %d %s",
							where_.x,
							where_.y,
							where_.z,
							where_.x,
							where_.y,
							where_.z,
							text,
						),
					},
				)
				@(static) wanted_at: game.Block_Pos
				@(static) wanted_block: game.Block
				wanted_at, wanted_block = where_, want
				return until(t, c, proc(c: ^Save_Client) -> bool {
					b, ok := block_at(c, wanted_at)
					return ok && b == wanted_block
				})
			}
			cases := [?]struct {
				text:   string,
				where_: game.Block_Pos,
				block:  game.Block,
			} {
				{"stone", at(5, 0, 0, feet), .Stone},
				{"ladder[facing=west]", at(4, 0, 0, feet), ladder},
				{"stone_stairs[facing=south,half=top]", at(3, 0, 0, feet), stair},
				{"planks_slab[type=double]", at(3, 0, 1, feet), slab},
			}
			for cs in cases {
				if testing.expectf(t, put(t, &c, cs.text, cs.where_, cs.block), "%s", cs.text) {
					append(&edits, Edit{cs.where_, cs.block})
				}
			}
		}
		send(&c, protocol.Command{"time 0.9"}) // late evening
		c.time = nil
		for _ in 0 ..< 20 {tick(t, &c, {move = {0, 1}, yaw = 0.7, pitch = -0.3})} 	// walk a bit, looking that way
		testing.expect(
			t,
			until(t, &c, proc(c: ^Save_Client) -> bool {return c.player.acked == c.seq}),
		)
		left_at = c.player.state
		left_time = c.time.? or_else -1
		testing.expectf(t, abs(left_time - 0.9) < 0.01, "time %v after setting 0.9", left_time)
		testing.expect(t, harness_stop(h), "the save failed")
		// The clock kept running until the save: what the reload must continue
		// from is the time the server wrote, not the last one the client saw.
		saved_time = saved_clock(dir, 77)
		testing.expectf(
			t,
			saved_time >= left_time && saved_time - left_time < 0.1,
			"saved time %v, last seen %v",
			saved_time,
			left_time,
		)
	}
	testing.expect(
		t,
		os.exists(filepath.join({dir, store.UNIVERSE_FILE}, context.temp_allocator) or_else "") &&
		os.exists(
			filepath.join(
				{home_dir(dir, 77), store.WORLD_FILE},
				context.temp_allocator,
			) or_else "",
		),
	)

	// Session 2: same directory, another seed in the config: the saved world wins.
	{
		h := new(Harness)
		defer free(h)
		srv := &h.srv
		config := Config {
			seed         = 12345,
			view_radius  = 3,
			view_height  = 2,
			allow_cheats = true,
			save_dir     = dir,
		}
		testing.expect(t, harness_start(h, config, local = true))
		defer harness_stop(h)
		testing.expect_value(t, srv.config.seed, 77)
		c: Save_Client
		client_open(&c, h)
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
		// after the one saved).
		testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return c.time != nil}))
		now := c.time.? or_else -1
		testing.expectf(
			t,
			now >= saved_time && now - saved_time < 2.0 / f64(game.RULES_DEFAULTS.day_length),
			"time %v after loading, %v saved",
			now,
			saved_time,
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
	h := new(Harness)
	defer free(h)
	// No directory: unloaded edits are kept in memory for the session.
	testing.expect(
		t,
		harness_start(
			h,
			{
				seed = 8,
				generator = .Classic,
				view_radius = 2,
				view_height = 2,
				allow_cheats = true,
			},
			local = true,
		),
	)
	defer harness_stop(h)
	c: Save_Client
	client_open(&c, h)
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
	send(&c, protocol.edit_plain(1, c.seq, target, .Lamp))
	testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return len(c.results) == 1}))
	testing.expect(t, c.results[1].accepted)

	// Far away (the chunk is unloaded on both sides), then back.
	send(&c, protocol.Teleport{feet + {3000, 0, 0}, 0, 0})
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
	send(&c, protocol.Teleport{feet, 0, 0})
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
		h := new(Harness)
		defer free(h)
		testing.expect(
			t,
			harness_start(
				h,
				{seed = 9, view_radius = 2, view_height = 2, save_dir = dir},
				local = true,
			),
		)
		c: Save_Client
		client_open(&c, h)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		testing.expect(t, until(t, &c, landed))
		feet := c.player.state.position
		send(
			&c,
			protocol.edit_plain(
				1,
				c.seq,
				{i32(math.floor(feet.x)) + 1, i32(math.floor(feet.y)), i32(math.floor(feet.z))},
				.Stone,
			),
		)
		testing.expect(t, until(t, &c, proc(c: ^Save_Client) -> bool {return len(c.results) == 1}))
		testing.expect(t, harness_stop(h))
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
		h := new(Harness)
		defer free(h)
		testing.expect(
			t,
			harness_start(
				h,
				{seed = 9, view_radius = 2, view_height = 2, save_dir = dir},
				local = true,
			),
		)
		c: Save_Client
		client_open(&c, h)
		defer client_close(&c)
		c.key = test_key("test")
		send(&c, test_hello("test"))
		until(t, &c, proc(c: ^Save_Client) -> bool {return c.welcomed})
		testing.expect(t, until(t, &c, landed), "the world did not load past the damaged file")
		testing.expect(t, harness_stop(h))
	}
	entries, _ = os.read_all_directory_by_path(regions, context.temp_allocator)
	aside := 0
	for e in entries {if strings.contains(e.name, ".damaged-") {aside += 1}}
	testing.expect_value(t, aside, damaged)
}

// A world keeps its generator: one made by a generator this game lacks is
// not loaded.
@(test)
test_world_generator_kept :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "generator"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	config := Config {
		seed        = 5,
		view_radius = 2,
		view_height = 1,
		save_dir    = dir,
	}
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	if testing.expect(t, harness_start(h, config)) {
		testing.expect_value(t, srv.home.generator, worldgen.Kind.Earth)
		testing.expect(t, harness_stop(h))
	}
	moved := filepath.join({home_dir(dir, 5), store.WORLD_FILE}, context.temp_allocator) or_else ""
	saved, _ := os.read_entire_file_from_path(moved, context.temp_allocator)
	testing.expect(t, strings.contains(string(saved), "generator = "), "not written")
	text, _ := strings.replace(
		string(saved),
		"generator = earth",
		"generator = moon",
		1,
		context.temp_allocator,
	)
	testing.expect(t, text != string(saved), "no generator line to change")
	_ = os.write_entire_file(moved, transmute([]u8)text)
	{
		context.logger = log.nil_logger() // its error is the point
		testing.expect(t, !harness_start(h, config), "a world from an unknown generator loaded")
	}
}

// home_dir: the home world's directory in a universe of seed.
@(private)
home_dir :: proc(dir: string, seed: i64) -> string {
	return(
		filepath.join(
			{dir, store.WORLDS_DIR, starmap.address_dir(starmap.address_derive(u64(seed)))},
			context.temp_allocator,
		) or_else dir \
	)
}

// saved_clock: the world time in the home world's world.cfg (-1 if unreadable).
@(private = "file")
saved_clock :: proc(dir: string, seed: i64) -> f64 {
	path :=
		filepath.join({home_dir(dir, seed), store.WORLD_FILE}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return -1}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		k, _, v := strings.partition(line, "=")
		if strings.trim_space(k) == "time" {
			f, ok := strconv.parse_f64(strings.trim_space(v))
			return f if ok else -1
		}
	}
	return -1
}

// A universe records the game it is made for: a server playing another game refuses it,
// and one from before games were recorded plays the game it is opened with and records it.
@(test)
test_universe_records_its_game :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "universe_game"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	cfg := filepath.join({dir, store.UNIVERSE_FILE}, context.temp_allocator) or_else ""
	recorded :: proc(cfg: string) -> string {
		data, err := os.read_entire_file_from_path(cfg, context.temp_allocator)
		if err != nil {return "(unreadable)"}
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(line, "game = ") {return line[len("game = "):]}
		}
		return ""
	}
	config := harness_world()
	config.save_dir = dir
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	testing.expect(t, harness_stop(h))
	testing.expect_value(t, recorded(cfg), HARNESS_GAME.id)

	// Another game's server refuses it, and says why.
	other := config
	other.game = {
		info = {id = "other"},
	}
	{
		context.logger = log.nil_logger() // (the refusal is logged: the point)
		testing.expect(t, !harness_start(h, other), "a universe was played by another game")
	}
	testing.expect_value(t, h.srv.refusal, "this universe plays harness, not other")
	testing.expect_value(t, recorded(cfg), HARNESS_GAME.id)

	// From before games were recorded: played by the game it is opened with, recorded.
	data, _ := os.read_entire_file_from_path(cfg, context.temp_allocator)
	before, _ := strings.replace_all(string(data), "game = harness\n", "", context.temp_allocator)
	testing.expect(t, len(before) < len(data))
	testing.expect(t, os.write_entire_file(cfg, transmute([]u8)before) == nil)
	if !testing.expect(t, harness_start(h, other)) {return}
	testing.expect(t, harness_stop(h))
	testing.expect_value(t, recorded(cfg), "other")
}

// A game keeps what it chooses with the universe: its save hook's text is game.cfg,
// written with every save, and its load hook reads it back after start in the next
// session; a game.cfg the game does not understand refuses the universe.
@(private = "file")
Saved_Count :: struct {
	count: int,
}

@(test)
test_game_saves_its_state :: proc(t: ^testing.T) {
	dir :=
		filepath.join({"build", "test", "universe_game_state"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := harness_world()
	config.save_dir = dir
	config.game = Game {
		info = {id = "counter"},
		server_state = Saved_Count,
		save = proc(s: ^Server, out: ^strings.Builder) {
			fmt.sbprintfln(out, "count = %d", game_state(s, Saved_Count).count)
		},
		load = proc(s: ^Server, text: string) -> bool {
			value := strings.trim_space(strings.trim_prefix(strings.trim_space(text), "count ="))
			n, ok := strconv.parse_int(value)
			game_state(s, Saved_Count).count = n
			return ok
		},
	}
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, config)) {return}
	testing.expect_value(t, game_state(&h.srv, Saved_Count).count, 0) // (a new universe: nothing to load)
	game_state(&h.srv, Saved_Count).count = 7
	testing.expect(t, harness_stop(h))
	path := filepath.join({dir, GAME_FILE}, context.temp_allocator) or_else ""
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil, "no game.cfg")
	testing.expect_value(t, string(data), "count = 7\n")

	// The next session loads it after start.
	if !testing.expect(t, harness_start(h, config)) {return}
	testing.expect_value(t, game_state(&h.srv, Saved_Count).count, 7)
	testing.expect(t, harness_stop(h))

	// One the game does not understand: the universe is refused, and says why.
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("count = many\n")) == nil)
	{
		context.logger = log.nil_logger() // (the refusal is logged: the point)
		testing.expect(t, !harness_start(h, config), "a game.cfg not understood was played")
	}
	testing.expect_value(
		t,
		h.srv.refusal,
		"this universe's game.cfg is not one counter understands",
	)
}

// A game's record on each character: kept with the character and saved in its file (its
// `game` member, a field by its path), given back when the character joins again; a file
// from before has none (zero), and a field the type no longer has is skipped.
@(private = "file")
Purse_Kind :: enum u8 {
	Leather,
	Silk,
}

@(private = "file")
Purse :: struct {
	silver: f64,
	kind:   Purse_Kind,
	coins:  [3]struct {
		value: u32,
		worn:  f32,
	},
}

@(test)
test_a_game_keeps_a_record_on_each_character :: proc(t: ^testing.T) {
	rec: Player_Record
	(^Purse)(&rec.character_data.bytes)^ = {12.5, .Silk, {{7, 0.25}, {}, {9, 0}}}
	text := player_json(test_reg(), &rec, Purse)
	testing.expect(t, strings.contains(string(text), `"silver": 12.5`), string(text))
	testing.expect(t, strings.contains(string(text), `"kind": "Silk"`), string(text))
	back, ok := player_parse(test_reg(), text, Purse)
	counters_free(&back.stats)
	testing.expect(t, ok)
	testing.expect_value(
		t,
		(^Purse)(&back.character_data.bytes)^,
		Purse{12.5, .Silk, {{7, 0.25}, {}, {9, 0}}},
	)
	// A file from before (format 4), and one with a field the type has not.
	old, old_ok := player_parse(
		test_reg(),
		transmute([]u8)string(`{"format": 4, "position": [1, 2, 3]}`),
		Purse,
	)
	counters_free(&old.stats)
	testing.expect(t, old_ok)
	testing.expect_value(t, (^Purse)(&old.character_data.bytes)^, Purse{})
	odd, odd_ok := player_parse(
		test_reg(),
		transmute([]u8)string(
			`{"format": 5, "position": [1, 2, 3], "game": {"silver": 3, "gold": 4, "kind": "Iron"}}`,
		),
		Purse,
	)
	counters_free(&odd.stats)
	testing.expect(t, odd_ok)
	testing.expect_value(t, (^Purse)(&odd.character_data.bytes)^, Purse{silver = 3})
	testing.expect(
		t,
		harness_refused(
			{
				game = Game {
					info = {id = "big", name = "Big", description = "x"},
					character_data = [game.MAX_CHARACTER_DATA + 1]u8,
				},
			},
		),
	)

	// Through a session: saved with the character, back when it joins again.
	dir := scratch_dir("character_data")
	defer delete(dir)
	defer os.remove_all(dir)
	cfg := grief_config(dir)
	cfg.game = Game {
		info = {id = "purses", name = "Purses", description = "Each character has a purse."},
		character_data = Purse,
	}
	g, opened := grief_open(t, dir, cfg)
	if opened {
		character_data(grief_srv(g), grief_client(g), Purse).silver = 99
		grief_close_keep(g)
	}
	grief_close(g)
	g2, opened2 := grief_open(t, dir, cfg)
	if opened2 {
		testing.expect_value(t, character_data(grief_srv(g2), grief_client(g2), Purse).silver, 99)
		grief_close_keep(g2)
	}
	grief_close(g2)
}
