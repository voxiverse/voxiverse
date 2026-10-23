package server

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "core:time"

import "../base"
import "../game"

// The authoritative side of a world, on its own thread at game.TICK_RATE.
// Everything it owns lives in its session arena and is freed at once by
// stop. The rest of the program talks to it only through its Endpoint (and
// reads published Stats).
//
//	server.start(&srv, {seed = 1, view_radius = 12, view_height = 6, workers = 2}, {&pipe, .Server})
//	...
//	ok := server.stop(&srv) // false if it stopped on an error

Config :: struct {
	seed:         i64,
	view_radius:  i32, // chunks, horizontally
	view_height:  i32, // chunks above and below
	workers:      int,
	allow_cheats: bool, // honour Teleport and Set_Rule (singleplayer)
	rules:        game.Rules, // zero: the defaults
}

// Stats is a snapshot, published at the end of every tick.
Stats :: struct {
	tick:              u64,
	tick_ms:           f32,
	chunks_loaded:     int,
	chunks_generating: int,
	arrays_allocated:  int,
	arrays_in_use:     int,
	arrays_bytes:      int, // committed for chunk arrays
	arena_used:        uint,
	arena_reserved:    uint,
	clients:           int,
}

Server :: struct {
	config:      Config,
	capacity:    int, // chunks
	endpoint:    game.Endpoint,
	thread:      ^thread.Thread,
	stopping:    bool, // (atomic)
	failed:      bool, // (atomic)
	stats_mutex: sync.Mutex,
	stats:       Stats,
	log_tag:     base.Log_Tag,
	rules:       game.Rules, // server thread only
	tops:        map[[2]i32]i32, // edited column tops (columns.odin)
	// Server thread only, after start:
	arena:       virtual.Arena,
	world:       World,
	client:      Client,
	offsets:     []game.Chunk_Pos, // the interest area around a client, nearest first
	writer:      game.Writer,
	tick:        u64,
}

// Chunks sent to a client per tick (at 30 Hz: 1440 per second).
@(private)
SEND_BUDGET :: 48

// start sets up the session and starts the server thread. s must stay at
// its address until stop.
start :: proc(s: ^Server, config: Config, endpoint: game.Endpoint) -> bool {
	assert(config.view_radius > 0 && config.view_radius <= game.MAX_VIEW_RADIUS)
	assert(
		config.view_height > 0 && config.view_height <= game.MAX_VIEW_HEIGHT && config.workers > 0,
	)
	s^ = {
		config   = config,
		endpoint = endpoint,
		rules    = config.rules if config.rules != {} else game.RULES_DEFAULTS,
	}
	if err := virtual.arena_init_growing(&s.arena); err != nil {
		log.errorf("server cannot reserve its memory: %v", err)
		return false
	}
	arena := virtual.arena_allocator(&s.arena)
	s.offsets = game.interest_offsets(config.view_radius, config.view_height, arena)
	// Loaded chunks stay within the unload distance of a client, plus
	// chunks still generating that were requested before it moved.
	capacity := game.interest_count(
		config.view_radius + game.SERVER_UNLOAD_MARGIN,
		config.view_height + game.SERVER_UNLOAD_MARGIN,
	)
	capacity += config.workers * MAX_IN_FLIGHT_PER_WORKER
	s.capacity = capacity
	if err := world_init(&s.world, config.seed, capacity, config.workers, arena); err != nil {
		log.errorf("server cannot allocate the world: %v", err)
		virtual.arena_destroy(&s.arena)
		return false
	}
	if err := client_init(&s.client, config, arena); err != nil {
		log.errorf("server cannot allocate client state: %v", err)
		world_destroy(&s.world)
		virtual.arena_destroy(&s.arena)
		return false
	}
	game.writer_init(&s.writer, arena)

	s.thread = thread.create(server_main)
	s.thread.data = s
	s.thread.init_context = context
	thread.start(s.thread)
	log.infof(
		"server started seed=%d view=%dx%d workers=%d capacity=%d",
		config.seed,
		config.view_radius,
		config.view_height,
		config.workers,
		capacity,
	)
	return true
}

// stop finishes the current tick, stops the thread and frees the session.
// False if the server stopped because of an error.
stop :: proc(s: ^Server) -> bool {
	sync.atomic_store(&s.stopping, true)
	thread.join(s.thread)
	thread.destroy(s.thread)
	world_destroy(&s.world)
	delete(s.tops)
	used := s.arena.total_used
	virtual.arena_destroy(&s.arena)
	log.infof("server stopped ticks=%d arena=%v", s.tick, base_bytes(used))
	failed := sync.atomic_load(&s.failed)
	s^ = {}
	return !failed
}

// block_capacity is the most chunk arrays the server can ever hold.
block_capacity :: proc(s: ^Server) -> int {
	return s.capacity
}

stats :: proc(s: ^Server) -> Stats {
	sync.guard(&s.stats_mutex)
	return s.stats
}

@(private = "file")
server_main :: proc(t: ^thread.Thread) {
	s := (^Server)(t.data)
	context.logger = base.log_retag(&s.log_tag, context.logger, "server")
	base.profile_thread_start("server")
	next := time.tick_now()
	for !sync.atomic_load(&s.stopping) {
		start := time.tick_now()
		tick(s)
		free_all(context.temp_allocator)
		publish_stats(s, f32(time.duration_milliseconds(time.tick_since(start))))

		next = time.tick_add(next, game.TICK_DURATION)
		left := time.tick_diff(time.tick_now(), next)
		if left < -5 * game.TICK_DURATION {
			log.debugf("server behind, skipping ticks behind=%v", -left)
			next = time.tick_now()
		} else if left > 0 {
			time.sleep(left)
		}
	}
	base.profile_thread_stop()
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
}

@(private = "file")
tick :: proc(s: ^Server) {
	base.profile_scope("server tick")
	s.tick += 1
	world_collect(&s.world, proc(pos: game.Chunk_Pos, data: rawptr) -> bool {
			s := (^Server)(data)
			return client_wants(&s.client, pos, s.config, game.SERVER_UNLOAD_MARGIN)
		}, s)
	receive_messages(s)
	if s.client.state == .Playing {
		simulate_player(s)
		if s.client.moved {
			s.client.moved = false
			unload_far(s)
		}
		stream(s)
	}
}

@(private = "file")
receive_messages :: proc(s: ^Server) {
	packets := make([dynamic]game.Packet, context.temp_allocator)
	game.receive(s.endpoint, &packets)
	defer for p in packets {game.packet_free(s.endpoint, p)}
	for p in packets {
		if s.client.state == .Gone {return}
		m, ok := game.decode_client(p)
		if !ok {
			disconnect(s, "invalid message")
			return
		}
		switch v in m {
		case game.Hello:
			if s.client.state != .Connecting {
				disconnect(s, "unexpected hello")
				return
			}
			if v.protocol != game.PROTOCOL_VERSION {
				disconnect(s, "protocol version mismatch")
				return
			}
			s.client.state = .Playing
			spawn := spawn_point(s.config.seed)
			s.client.player = {
				position = spawn,
			}
			set_position(&s.client, spawn)
			send_message(
				s,
				game.Welcome {
					protocol = game.PROTOCOL_VERSION,
					tick_rate = game.TICK_RATE,
					spawn = spawn,
					view_radius = u32(s.config.view_radius),
					view_height = u32(s.config.view_height),
					rules = s.rules,
				},
			)
			log.infof("server player joined name=%q", v.name)
		case game.Input:
			if s.client.state != .Playing {
				disconnect(s, "input before hello")
				return
			}
			game.input_queue_push(&s.client.inputs, v)
		case game.Teleport:
			if !s.config.allow_cheats || s.client.state != .Playing {
				disconnect(s, "cheats are not allowed")
				return
			}
			s.client.player = {
				position = v.position,
			}
			s.client.teleport = {v.yaw, v.pitch}
			s.client.teleported = true
		case game.Set_Rule:
			if !s.config.allow_cheats {
				disconnect(s, "cheats are not allowed")
				return
			}
			switch err := base.var_set(game.rules_table(), &s.rules, v.name, v.value); err {
			case .None, .Out_Of_Range:
				if err ==
				   .Out_Of_Range {log.warnf("server rule clamped name=%q value=%q", v.name, v.value)}
				log.infof("server rule changed name=%s value=%s", v.name, v.value)
				send_message(s, game.Rules_Changed{s.rules})
			case .Unknown_Name, .Bad_Value:
				log.warnf(
					"server rule not changed name=%q value=%q problem=%v",
					v.name,
					v.value,
					err,
				)
			}
		case game.Ping:
			send_message(s, game.Pong{v.id})
		case game.Edit:
			if s.client.state != .Playing {
				disconnect(s, "edit before hello")
				return
			}
			queue_edit(s, v)
		}
	}
}

// simulate_player applies this tick's inputs and tells the client where
// its player is.
@(private = "file")
simulate_player :: proc(s: ^Server) {
	c := &s.client
	buf: [game.INPUT_BUDGET_MAX]game.Input
	query := game.Block_Query{&s.world, world_block}
	run_due_edits(s) // edits after inputs applied in earlier ticks
	for msg in game.input_queue_tick(&c.inputs, &buf) {
		game.player_step(&c.player, msg.input, &s.rules, query, game.TICK_SECONDS)
		run_due_edits(s)
	}
	set_position(c, c.player.position)
	send_message(
		s,
		game.Player_Update {
			acked = c.inputs.last,
			state = c.player,
			teleported = c.teleported,
			yaw = c.teleport[0],
			pitch = c.teleport[1],
		},
	)
	c.teleported = false
}

// queue_edit holds an edit until the input it follows has been applied
// (refusing it outright if too many are waiting).
@(private = "file")
queue_edit :: proc(s: ^Server, e: game.Edit) {
	c := &s.client
	if c.edit_count == MAX_QUEUED_EDITS {
		current, _ := world_block(&s.world, e.pos)
		send_message(s, game.Edit_Result{id = e.id, pos = e.pos, block = current})
		return
	}
	c.edits[c.edit_count] = e
	c.edit_count += 1
	run_due_edits(s)
}

// run_due_edits applies queued edits whose input has been applied, in order.
@(private = "file")
run_due_edits :: proc(s: ^Server) {
	c := &s.client
	n := 0
	for n < c.edit_count && game.sequence_before_or_at(c.edits[n].after, c.inputs.last) {
		send_message(s, apply_edit(s, c.edits[n]))
		n += 1
	}
	copy(c.edits[:], c.edits[n:c.edit_count])
	c.edit_count -= n
}

// apply_edit checks an edit against the shared rules, from where the server
// has the player, and applies it if it passes.
@(private = "file")
apply_edit :: proc(s: ^Server, e: game.Edit) -> game.Edit_Result {
	current, loaded := world_block(&s.world, e.pos)
	result := game.Edit_Result {
		id    = e.id,
		pos   = e.pos,
		block = current,
	}
	if !loaded {return result}
	player := s.client.player
	if !game.in_reach(
		game.player_eye(player),
		e.pos,
		f64(s.rules.reach) + game.EDIT_REACH_SLACK,
	) {return result}
	allowed := false
	if e.block == .Air {
		allowed = game.can_break(current)
	} else {
		allowed =
			e.block != .Bedrock &&
			game.block_solid(e.block) &&
			game.can_place_at(current, e.pos, player)
	}
	if !allowed || !world_set_block(&s.world, e.pos, e.block) {return result}
	result.accepted, result.block = true, e.block
	column := [2]i32{e.pos.x >> game.CHUNK_SHIFT, e.pos.z >> game.CHUNK_SHIFT}
	if column_edited(s, e.pos, e.block) && s.client.columns[column] > 0 {
		send_message(s, column_message(s, column))
	}
	return result
}

// disconnect rejects the client and closes the connection (a protocol
// error is the client's bug or an attack; either way it is logged).
@(private = "file")
disconnect :: proc(s: ^Server, reason: string) {
	log.warnf("server disconnecting client reason=%q", reason)
	send_message(s, game.Reject{reason})
	game.close(s.endpoint)
	s.client.state = .Gone
}

@(private)
send_message :: proc(s: ^Server, m: game.Server_Message, blocks: ^game.Chunk_Blocks = nil) {
	clear(&s.writer.buf)
	game.encode_server(&s.writer, m, blocks)
	game.send(s.endpoint, s.writer.buf[:])
}

// spawn_point is above the terrain at the origin.
@(private = "file")
spawn_point :: proc(seed: i64) -> [3]f64 {
	h := game.column_height(seed, 0, 0)
	return {0.5, f64(h) + 3, 0.5}
}

@(private = "file")
publish_stats :: proc(s: ^Server, tick_ms: f32) {
	st := Stats {
		tick              = s.tick,
		tick_ms           = tick_ms,
		chunks_loaded     = s.world.chunks.count,
		chunks_generating = s.world.in_flight,
		arrays_allocated  = s.world.arrays.allocated,
		arrays_in_use     = game.block_arrays_in_use(&s.world.arrays),
		arrays_bytes      = s.world.arrays.committed,
		arena_used        = s.arena.total_used,
		arena_reserved    = s.arena.total_reserved,
		clients           = 1 if s.client.state == .Playing else 0,
	}
	sync.guard(&s.stats_mutex)
	s.stats = st
}

@(private = "file")
base_bytes :: proc(n: uint) -> string {
	switch {
	case n >= mem.Megabyte:
		return fmt.tprintf("%.1f MiB", f64(n) / mem.Megabyte)
	case n >= mem.Kilobyte:
		return fmt.tprintf("%.1f KiB", f64(n) / mem.Kilobyte)
	}
	return fmt.tprintf("%d B", n)
}
