package server

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../base"
import "../game"
import "../netcode"

// The authoritative side of a world, on its own thread at game.TICK_RATE.
// Everything it owns lives in its session arena and is freed at once by
// stop. Players reach it through the in-process Pipe (the local player of
// a game that hosts its own world) or over UDP (netcode: a dedicated server,
// or a world opened to the LAN); either way they speak the same messages.
// The rest of the program sees only published Stats.
//
//	server.start(&srv, {seed = 1, view_radius = 12, view_height = 6, workers = 2}, {&pipe, .Server})
//	...
//	ok := server.stop(&srv) // false if it stopped on an error

Config :: struct {
	seed:            i64,
	view_radius:     i32, // chunks, horizontally
	view_height:     i32, // chunks above and below
	workers:         int,
	allow_cheats:    bool, // the local player may Teleport, Set_Rule and Admin
	everyone_cheats: bool, // ... and so may remote players
	save_dir:        string, // the world's directory; "" = not saved (its seed and rules win over these)
	rules:           game.Rules, // zero: the defaults
	max_players:     int, // seats (0: DEFAULT_MAX_PLAYERS)
	listen:          bool, // take remote players from the start (else only after Admin "open_lan")
	port:            int, // ... on this UDP port (0: any free one)
	password:        string, // remote players must know it ("": none)
	name:            string, // what LAN discovery shows
	capture:         string, // write every packet to this pcap file once listening ("": no)
	conditions:      netcode.Conditions, // simulated loss etc. on what the server sends (tests)
}

DEFAULT_MAX_PLAYERS :: 8

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
	port:              int, // listening on (0: not)
}

Server :: struct {
	config:      Config,
	capacity:    int, // chunks
	local:       game.Endpoint, // the in-process player's pipe (none: a dedicated server)
	thread:      ^thread.Thread,
	stopping:    bool, // (atomic)
	frozen:      bool, // (atomic) the local player paused: time and entities stand still
	failed:      bool, // (atomic)
	stats_mutex: sync.Mutex,
	stats:       Stats,
	log_tag:     base.Log_Tag,
	rules:       game.Rules, // server thread only
	clock:       f64, // world time (game/time.odin); server thread only after start
	tops:        map[[2]i32]i32, // edited column tops (columns.odin)
	store:       Store, // saving (save.odin)
	// Server thread only, after start:
	arena:       virtual.Arena,
	world:       World,
	clients:     []Client, // index = player id
	host:        netcode.Host, // remote players (listening when host_open)
	listening:   bool,
	capture:     netcode.Capture, // (config.capture)
	entities:    Entities, // (entities.odin)
	offsets:     []game.Chunk_Pos, // the interest area around a client, nearest first
	writer:      game.Writer,
	tick:        u64,
}

// Chunks sent to a client per tick (at 30 Hz: 1440 per second).
@(private)
SEND_BUDGET :: 48
// A remote client with this much unacknowledged reliable data gets no more
// chunks until it catches up (the rest wait: streaming is nearest first).
@(private)
MAX_BACKLOG :: 512 * 1024
// Ticks between one player's rockets, at least.
@(private)
FIRE_EVERY :: game.TICK_RATE / 4

// A rejected remote client is told why and dropped this many ticks later.
@(private)
KICK_DELAY :: game.TICK_RATE

// start sets up the session and starts the server thread. s must stay at
// its address until stop. local: the in-process player's end of a pipe
// ({} for none).
start :: proc(s: ^Server, config: Config, local: game.Endpoint) -> bool {
	assert(config.view_radius > 0 && config.view_radius <= game.MAX_VIEW_RADIUS)
	assert(
		config.view_height > 0 && config.view_height <= game.MAX_VIEW_HEIGHT && config.workers > 0,
	)
	s^ = {
		config = config,
		local  = local,
		rules  = config.rules if config.rules != {} else game.RULES_DEFAULTS,
		clock  = game.NEW_WORLD_TIME,
	}
	if s.config.max_players <= 0 {s.config.max_players = DEFAULT_MAX_PLAYERS}
	s.config.max_players = min(s.config.max_players, game.MAX_PLAYERS)
	if err := virtual.arena_init_growing(&s.arena); err != nil {
		log.errorf("server cannot reserve its memory: %v", err)
		return false
	}
	arena := virtual.arena_allocator(&s.arena)
	s.config.password = strings.clone(config.password, arena)
	s.config.name = strings.clone(config.name, arena)
	s.config.capture = strings.clone(config.capture, arena)
	// A saved world's seed and rules replace the config's.
	if !store_open(s, config.save_dir) {
		store_close(s)
		virtual.arena_destroy(&s.arena)
		return false
	}
	s.offsets = game.interest_offsets(config.view_radius, config.view_height, arena)
	// Loaded chunks stay within the unload distance of some player, plus
	// chunks still generating that were requested before they moved.
	per_player := game.interest_count(
		config.view_radius + game.SERVER_UNLOAD_MARGIN,
		config.view_height + game.SERVER_UNLOAD_MARGIN,
	)
	capacity := per_player * s.config.max_players + config.workers * MAX_IN_FLIGHT_PER_WORKER
	s.capacity = capacity
	if err := world_init(&s.world, s.config.seed, capacity, config.workers, arena); err != nil {
		log.errorf("server cannot allocate the world: %v", err)
		store_close(s)
		virtual.arena_destroy(&s.arena)
		return false
	}
	s.clients = make([]Client, s.config.max_players, arena)
	for &c in s.clients {
		if err := client_init(&c, s.config, arena); err != nil {
			log.errorf("server cannot allocate client state: %v", err)
			world_destroy(&s.world)
			store_close(s)
			virtual.arena_destroy(&s.arena)
			return false
		}
	}
	game.writer_init(&s.writer, arena)
	entities_init(&s.entities, s.config.seed)
	load_entities(s)
	if local.pipe != nil {
		s.clients[0].state = .Connecting
		s.clients[0].link = Local{}
		s.clients[0].can_cheat = config.allow_cheats
	}
	if config.listen && !listen(s, config.port, config.port) {
		world_destroy(&s.world)
		store_close(s)
		virtual.arena_destroy(&s.arena)
		return false
	}

	s.thread = thread.create(server_main)
	s.thread.data = s
	s.thread.init_context = context
	thread.start(s.thread)
	log.infof(
		"server started seed=%d view=%dx%d workers=%d capacity=%d seats=%d",
		s.config.seed,
		config.view_radius,
		config.view_height,
		config.workers,
		capacity,
		s.config.max_players,
	)
	return true
}

// stop finishes the current tick, stops the thread, saves, says goodbye to
// remote players and frees the session. False if the server stopped
// because of an error (or the last save failed).
stop :: proc(s: ^Server) -> bool {
	sync.atomic_store(&s.stopping, true)
	thread.join(s.thread)
	thread.destroy(s.thread)
	if !save(s) {sync.atomic_store(&s.failed, true)} 	// the last save must not fail quietly
	if s.listening {netcode.host_close(&s.host, "the server stopped")}
	netcode.capture_close(&s.capture)
	store_close(s)
	world_destroy(&s.world)
	entities_destroy(&s.entities)
	delete(s.tops)
	used := s.arena.total_used
	virtual.arena_destroy(&s.arena)
	log.infof("server stopped ticks=%d arena=%v", s.tick, base_bytes(used))
	failed := sync.atomic_load(&s.failed)
	s^ = {}
	return !failed
}

// freeze stops (or restarts) time and entities while the local player is
// paused. Ignored while anyone else could be playing: remote players, or
// the world open to the LAN.
freeze :: proc(s: ^Server, on: bool) {
	sync.atomic_store(&s.frozen, on)
}

// block_capacity is the most chunk arrays the server can ever hold.
block_capacity :: proc(s: ^Server) -> int {
	return s.capacity
}

stats :: proc(s: ^Server) -> Stats {
	sync.guard(&s.stats_mutex)
	return s.stats
}

// listen opens the UDP port for remote players: the first free one from
// first to last. False (logged) if none could be opened.
@(private)
listen :: proc(s: ^Server, first, last: int) -> bool {
	if s.listening {return true}
	err: net.Network_Error
	for port in first ..= last {
		err = netcode.host_open(&s.host, port, s.config.max_players, s.config.password)
		if err == nil {
			s.listening = true
			s.host.socket.conditions = s.config.conditions
			if s.config.capture != "" {
				if netcode.capture_open(&s.capture, s.config.capture) {
					s.host.socket.capture = &s.capture
					log.infof("server capturing packets path=%s", s.config.capture)
				} else {
					log.errorf("server cannot write the capture path=%s", s.config.capture)
				}
			}
			log.infof("server listening port=%d password=%v", port, s.config.password != "")
			update_info(s)
			return true
		}
	}
	log.errorf("server cannot listen ports=%d..%d error=%v", first, last, err)
	return false
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
	if time.duration_seconds(time.tick_since(s.store.last_save)) >= AUTOSAVE_SECONDS {save(s)}
	world_collect(&s.world, proc(pos: game.Chunk_Pos, data: rawptr) -> bool {
			return anyone_wants((^Server)(data), pos, game.SERVER_UNLOAD_MARGIN)
		}, s)
	receive_messages(s)
	frozen := sync.atomic_load(&s.frozen) && !s.listening
	if !frozen {s.clock = game.advance_time(s.clock, f64(game.TICK_SECONDS), &s.rules)}
	moved := false
	for &c in s.clients {
		if c.state != .Playing {continue}
		if s.tick % game.TICK_RATE == 0 {send_message(s, &c, game.Time{s.clock})}
		simulate_player(s, &c)
		if c.moved {
			c.moved = false
			moved = true
			drop_far(s, &c)
		}
	}
	if moved {unload_unwanted(s)}
	if !frozen {entities_tick(s)}
	for &c in s.clients {
		if c.state != .Playing {continue}
		send_players(s, &c)
		replicate(s, &c)
		stream(s, &c)
	}
	kick_due(s)
	if s.listening {
		if s.tick % game.TICK_RATE == 0 {update_info(s)}
		netcode.host_flush(&s.host, time.tick_now())
	}
}

// receive_messages handles what every player sent since the last tick: the
// local player's pipe, then the network.
@(private = "file")
receive_messages :: proc(s: ^Server) {
	if s.local.pipe != nil {
		packets := make([dynamic]game.Packet, context.temp_allocator)
		game.receive(s.local, &packets)
		defer for p in packets {game.packet_free(s.local, p)}
		for p in packets {handle(s, &s.clients[0], p)}
	}
	if !s.listening {return}
	netcode.host_update(&s.host, time.tick_now())
	for e in s.host.events {
		switch v in e {
		case netcode.Peer_Connected:
			slot := -1
			for c, i in s.clients {
				if c.state == .Free {
					slot = i
					break
				}
			}
			if slot < 0 { 	// the host's seats are ours, but the local player has one too
				netcode.host_kick(&s.host, v.peer, "the server is full", time.tick_now())
				continue
			}
			c := &s.clients[slot]
			c.state = .Connecting
			c.link = v.peer
			c.can_cheat = s.config.everyone_cheats
			log.infof(
				"server connection player=%d from=%s",
				slot,
				net.endpoint_to_string(v.address),
			)
		case netcode.Peer_Message:
			if c := client_of_peer(s, v.peer); c != nil {handle(s, c, v.data)}
		case netcode.Peer_Disconnected:
			if c := client_of_peer(s, v.peer); c != nil {
				c.link = nil // gone already: nothing to send it
				leave(s, c, fmt.tprint(v.reason))
			}
		}
	}
}

@(private = "file")
client_of_peer :: proc(s: ^Server, peer: netcode.Peer_Id) -> ^Client {
	for &c in s.clients {
		if p, ok := c.link.(netcode.Peer_Id); ok && p == peer {return &c}
	}
	return nil
}

// handle one message from a client.
@(private = "file")
handle :: proc(s: ^Server, c: ^Client, p: []u8) {
	if c.state == .Free || c.state == .Gone {return}
	m, ok := game.decode_client(p)
	if !ok {
		disconnect(s, c, "invalid message")
		return
	}
	switch v in m {
	case game.Hello:
		if c.state != .Connecting {
			disconnect(s, c, "unexpected hello")
			return
		}
		if v.protocol != game.PROTOCOL_VERSION {
			disconnect(s, c, "protocol version mismatch")
			return
		}
		if !game.name_valid(v.name) {
			disconnect(s, c, "names are 1 to 16 letters, digits, _ or -")
			return
		}
		for &other in s.clients {
			if other.state == .Playing && client_name(&other) == v.name {
				disconnect(s, c, "someone with that name is playing")
				return
			}
		}
		join(s, c, v.name)
	case game.Input:
		if c.state != .Playing {
			disconnect(s, c, "input before hello")
			return
		}
		game.input_queue_push(&c.inputs, v)
	case game.Teleport:
		if !c.can_cheat || c.state != .Playing {
			disconnect(s, c, "cheats are not allowed")
			return
		}
		c.player = {
			position = v.position,
		}
		c.teleport = {v.yaw, v.pitch}
		c.teleported = true
	case game.Set_Rule:
		if !c.can_cheat {
			disconnect(s, c, "cheats are not allowed")
			return
		}
		switch err := base.var_set(game.rules_table(), &s.rules, v.name, v.value); err {
		case .None, .Out_Of_Range:
			if err ==
			   .Out_Of_Range {log.warnf("server rule clamped name=%q value=%q", v.name, v.value)}
			log.infof(
				"server rule changed name=%s value=%s by=%s",
				v.name,
				v.value,
				client_name(c),
			)
			broadcast(s, game.Rules_Changed{s.rules})
		case .Unknown_Name, .Bad_Value:
			log.warnf("server rule not changed name=%q value=%q problem=%v", v.name, v.value, err)
		}
	case game.Ping:
		send_message(s, c, game.Pong{v.id})
	case game.Admin:
		if !c.can_cheat {
			disconnect(s, c, "cheats are not allowed")
			return
		}
		admin(s, c, v.command)
	case game.Edit:
		if c.state != .Playing {
			disconnect(s, c, "edit before hello")
			return
		}
		queue_edit(s, c, v)
	case game.Attack:
		if c.state != .Playing {
			disconnect(s, c, "attack before hello")
			return
		}
		attack(s, c, v)
	case game.Fire:
		// The rocket launcher is a creative tool: a cheat.
		if !c.can_cheat || c.state != .Playing {
			disconnect(s, c, "cheats are not allowed")
			return
		}
		if s.tick >= c.fired_at + FIRE_EVERY {
			c.fired_at = s.tick
			fire(s, c, v.yaw, v.pitch)
		}
	}
}

// join: a client said hello with a free name. It is welcomed where it left
// off (in a saved world) or above the terrain, introduced to the others and
// they to it.
@(private = "file")
join :: proc(s: ^Server, c: ^Client, name: string) {
	c.state = .Playing
	c.name_len = copy(c.name_buf[:], name)
	saved, has_saved := s.store.players[name]
	c.player = saved.state if has_saved else {position = spawn_point(s.config.seed)}
	if has_saved {
		// Look where they looked: sent like a teleport's direction.
		c.look = {saved.yaw, saved.pitch}
		c.teleport = c.look
		c.teleported = true
	}
	set_position(c, c.player.position)
	send_message(
		s,
		c,
		game.Welcome {
			protocol = game.PROTOCOL_VERSION,
			tick_rate = game.TICK_RATE,
			player = player_id(s, c),
			cheats = c.can_cheat,
			spawn = c.player.position,
			view_radius = u32(s.config.view_radius),
			view_height = u32(s.config.view_height),
			rules = s.rules,
		},
	)
	send_message(s, c, game.Time{s.clock})
	for &other in s.clients {
		if &other == c || other.state != .Playing {continue}
		send_message(s, c, game.Player_Joined{player_id(s, &other), client_name(&other)})
		send_message(s, &other, game.Player_Joined{player_id(s, c), name})
	}
	log.infof("server player joined player=%d name=%q", player_id(s, c), name)
}

// leave: a client is gone (left, timed out or was dropped): its player is
// kept for the save and the others are told.
@(private = "file")
leave :: proc(s: ^Server, c: ^Client, reason: string) {
	farewell(s, c, reason)
	if p, ok := c.link.(netcode.Peer_Id);
	   ok {netcode.host_kick(&s.host, p, reason, time.tick_now())}
	client_reset(c)
}

// farewell: a playing client's player is kept for the save, and the others
// are told it left.
@(private = "file")
farewell :: proc(s: ^Server, c: ^Client, reason: string) {
	if c.state != .Playing {return}
	keep_player(s, c)
	for &other in s.clients {
		if &other != c && other.state == .Playing {
			send_message(s, &other, game.Player_Left{player_id(s, c)})
		}
	}
	log.infof(
		"server player left player=%d name=%q reason=%s",
		player_id(s, c),
		client_name(c),
		reason,
	)
}

// admin runs a server command: "save", "time <0..1>" (time of day),
// "open_lan" (listen for players on the LAN).
@(private = "file")
admin :: proc(s: ^Server, c: ^Client, command: string) {
	switch {
	case command == "save":
		save(s)
		return
	case strings.has_prefix(command, "time "):
		if f, ok := game.parse_time_of_day(command[len("time "):]); ok {
			s.clock = game.set_time_of_day(s.clock, f)
			log.infof("server time set time=%.4f", s.clock)
			broadcast(s, game.Time{s.clock})
			return
		}
	case strings.has_prefix(command, "fill "),
	     strings.has_prefix(command, "replace "),
	     strings.has_prefix(command, "sphere "),
	     strings.has_prefix(command, "explode "):
		bulk_command(s, c, command)
		return
	case command == "hash":
		// The chunks this client has, as the server has them (blast_test).
		sum: u64
		for pos in c.has {
			if chunk := world_get(&s.world, pos); chunk != nil && chunk.state == .Ready {
				game.chunks_hash_add(&sum, pos, &chunk.blocks)
			}
		}
		notice(s, c, fmt.tprintf("hash %d %x", len(c.has), sum))
		return
	case strings.has_prefix(command, "summon"):
		if !summon(s, c, .Critter) {notice(s, c, "Nowhere to put it (look at open ground nearby)")}
		return
	case command == "open_lan":
		if s.listening {
			notice(s, c, fmt.tprintf("Already open on port %d", s.host.socket.port))
		} else if listen(
			s,
			netcode.DEFAULT_PORT,
			netcode.DEFAULT_PORT + netcode.DISCOVERY_PORTS - 1,
		) {
			notice(s, c, fmt.tprintf("Open to LAN on port %d", s.host.socket.port))
		} else {
			notice(s, c, "Could not open to LAN: no free port (see the log)")
		}
		return
	}
	log.warnf("server unknown admin command command=%q", command)
}

// simulate_player applies this tick's inputs and tells the client where
// its player is.
@(private = "file")
simulate_player :: proc(s: ^Server, c: ^Client) {
	buf: [game.INPUT_BUDGET_MAX]game.Input
	query := game.Block_Query{&s.world, world_block}
	run_due_edits(s, c) // edits after inputs applied in earlier ticks
	for msg in game.input_queue_tick(&c.inputs, &buf) {
		game.player_step(&c.player, msg.input, &s.rules, query, game.TICK_SECONDS)
		c.look = {msg.input.yaw, msg.input.pitch}
		run_due_edits(s, c)
	}
	set_position(c, c.player.position)
	update := game.Player_Update {
		acked      = c.inputs.last,
		state      = c.player,
		teleported = c.teleported,
		yaw        = c.teleport[0],
		pitch      = c.teleport[1],
	}
	// A teleport must arrive (the player is told where to look); the rest
	// are states, the newest of which wins.
	send_message(s, c, update, reliable = c.teleported)
	c.teleported = false
}

// send_players tells a client where the other players near it are.
@(private = "file")
send_players :: proc(s: ^Server, c: ^Client) {
	m := game.Players {
		tick = u32(s.tick),
	}
	near := f64((s.config.view_radius + 1) * game.CHUNK_SIZE)
	for &other in s.clients {
		if &other == c || other.state != .Playing {continue}
		d := other.player.position - c.player.position
		if d.x * d.x + d.z * d.z > near * near {continue}
		m.entries[m.count] = {
			player   = player_id(s, &other),
			position = other.player.position,
			yaw      = other.look[0],
			pitch    = other.look[1],
			flying   = other.player.flying,
		}
		m.count += 1
	}
	if m.count > 0 {send_message(s, c, m)}
}

// queue_edit holds an edit until the input it follows has been applied
// (refusing it outright if too many are waiting).
@(private = "file")
queue_edit :: proc(s: ^Server, c: ^Client, e: game.Edit) {
	if c.edit_count == MAX_QUEUED_EDITS {
		current, _ := world_block(&s.world, e.pos)
		send_message(s, c, game.Edit_Result{id = e.id, pos = e.pos, block = current})
		return
	}
	c.edits[c.edit_count] = e
	c.edit_count += 1
	run_due_edits(s, c)
}

// run_due_edits applies queued edits whose input has been applied, in order.
@(private = "file")
run_due_edits :: proc(s: ^Server, c: ^Client) {
	n := 0
	for n < c.edit_count && game.sequence_before_or_at(c.edits[n].after, c.inputs.last) {
		send_message(s, c, apply_edit(s, c, c.edits[n]))
		n += 1
	}
	copy(c.edits[:], c.edits[n:c.edit_count])
	c.edit_count -= n
}

// apply_edit checks an edit against the shared rules, from where the server
// has the player, and applies it if it passes. Everyone else who has the
// chunk hears of it.
@(private = "file")
apply_edit :: proc(s: ^Server, c: ^Client, e: game.Edit) -> game.Edit_Result {
	current, loaded := world_block(&s.world, e.pos)
	result := game.Edit_Result {
		id    = e.id,
		pos   = e.pos,
		block = current,
	}
	if !loaded {return result}
	player := c.player
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
			game.can_place_at(current, e.pos, player) &&
			!anyone_else_in(s, c, e.pos)
	}
	if !allowed || !world_set_block(&s.world, e.pos, e.block) {return result}
	result.accepted, result.block = true, e.block
	chunk := game.chunk_of(e.pos)
	mark_edited(s, chunk)
	for &other in s.clients {
		if &other != c && other.state == .Playing && chunk in other.has {
			send_message(s, &other, game.Block_Changed{e.pos, e.block})
		}
	}
	column := [2]i32{e.pos.x >> game.CHUNK_SHIFT, e.pos.z >> game.CHUNK_SHIFT}
	if column_edited(s, e.pos, e.block) {
		m := column_message(s, column)
		for &other in s.clients {
			if other.state == .Playing && other.columns[column] > 0 {send_message(s, &other, m)}
		}
	}
	return result
}

// bulk_command runs a bulk edit command (block coordinates):
//
//	fill x1 y1 z1 x2 y2 z2 block
//	replace x1 y1 z1 x2 y2 z2 from to
//	sphere x y z radius block
//	explode x y z radius
@(private = "file")
bulk_command :: proc(s: ^Server, c: ^Client, command: string) {
	f := strings.fields(command, context.temp_allocator)
	ints :: proc(words: []string, out: []i32) -> bool {
		for w, i in words {
			n, ok := strconv.parse_int(w)
			if !ok || abs(n) >= game.WORLD_LIMIT {return false}
			out[i] = i32(n)
		}
		return true
	}
	block_named :: proc(name: string) -> (game.Block, bool) {
		for b in game.Block {if game.BLOCK_INFO[b].name == name && b != .Bedrock {return b, true}}
		return .Air, false
	}
	e: Bulk_Edit
	ok := false
	switch f[0] {
	case "fill", "replace":
		n: [6]i32
		want := 8 if f[0] == "fill" else 9
		if len(f) == want && ints(f[1:7], n[:]) {
			e.shape = Box{{n[0], n[1], n[2]}, {n[3], n[4], n[5]}}
			if f[0] == "fill" {
				e.op = .Set
				e.block, ok = block_named(f[7])
			} else {
				from, ok1 := block_named(f[7])
				to, ok2 := block_named(f[8])
				e.op, e.from, e.block, ok = .Replace, from, to, ok1 && ok2
			}
		}
	case "sphere", "explode":
		n: [3]i32
		r: f64
		rok := false
		if len(f) > 4 {r, rok = strconv.parse_f64(f[4])}
		if rok && r > 0 && r <= 32 && ints(f[1:4], n[:]) {
			center := [3]f64{f64(n[0]) + 0.5, f64(n[1]) + 0.5, f64(n[2]) + 0.5}
			if f[0] == "explode" {
				explode(s, center, r)
				return
			}
			if len(f) == 6 {
				e.shape, e.op = Sphere{center, r}, .Set
				e.block, ok = block_named(f[5])
			}
		}
	}
	if !ok {
		notice(s, c, fmt.tprintf("%s: bad arguments", f[0]))
		return
	}
	changed, result := bulk_edit(s, e)
	switch result {
	case .Done:
		notice(s, c, fmt.tprintf("%s: %d blocks changed", f[0], changed))
	case .Too_Big:
		notice(s, c, fmt.tprintf("%s: too big (at most %d blocks)", f[0], MAX_BULK_VOLUME))
	case .Not_Loaded:
		notice(s, c, fmt.tprintf("%s: part of it is not loaded", f[0]))
	}
}

// attack: a player hits an entity, if it is within reach of where the
// server has the player (with the same slack as edits). The client chose it
// by its own ray; the server only checks it was possible.
@(private = "file")
attack :: proc(s: ^Server, c: ^Client, a: game.Attack) {
	ent, index := entity_find(s, a.entity)
	if ent == nil {return} 	// gone already: a late click
	eye := game.player_eye(c.player)
	lo, hi := game.entity_box(ent.kind, ent.body.position)
	closest := [3]f64{clamp(eye.x, lo.x, hi.x), clamp(eye.y, lo.y, hi.y), clamp(eye.z, lo.z, hi.z)}
	d := closest - eye
	reach := f64(s.rules.reach) + game.EDIT_REACH_SLACK
	if d.x * d.x + d.y * d.y + d.z * d.z > reach * reach {return}
	if entity_attack(s, ent, c.player.position) {
		log.debugf("server entity died id=%d by=%s", a.entity, client_name(c))
		entity_died(s, index)
	} else {
		entity_hurt_shown(s, a.entity)
	}
}

// anyone_else_in: a block at pos would be inside another player.
@(private = "file")
anyone_else_in :: proc(s: ^Server, c: ^Client, pos: game.Block_Pos) -> bool {
	for &other in s.clients {
		if &other != c && other.state == .Playing && !game.can_place_at(.Air, pos, other.player) {
			return true
		}
	}
	return false
}

// disconnect refuses a client (a protocol error is the client's bug or an
// attack; either way it is logged): it is told why, then dropped.
@(private = "file")
disconnect :: proc(s: ^Server, c: ^Client, reason: string) {
	log.warnf("server disconnecting client player=%d reason=%q", player_id(s, c), reason)
	send_message(s, c, game.Reject{reason})
	switch l in c.link {
	case Local:
		game.close(s.local)
		leave(s, c, reason)
		c.state = .Gone // the pipe is closed: this seat stays shut
	case netcode.Peer_Id:
		// The Reject goes out with the next flushes; the connection ends after.
		farewell(s, c, reason)
		c.state = .Gone
		c.kick_at = s.tick + KICK_DELAY
		c.kick_reason = reason
	}
}

// kick_due drops refused remote clients whose Reject has had time to go.
@(private = "file")
kick_due :: proc(s: ^Server) {
	for &c in s.clients {
		if c.state == .Gone && c.kick_at != 0 && s.tick >= c.kick_at {
			leave(s, &c, c.kick_reason)
		}
	}
}

// send_message encodes m for a client: down the pipe, or over the network
// (reliably unless the kind is a state that the next one replaces).
@(private)
send_message :: proc(
	s: ^Server,
	c: ^Client,
	m: game.Server_Message,
	blocks: ^game.Chunk_Blocks = nil,
	reliable := false,
) {
	if c.link == nil {return}
	clear(&s.writer.buf)
	game.encode_server(&s.writer, m, blocks)
	data := s.writer.buf[:]
	switch l in c.link {
	case Local:
		game.send(s.local, data)
	case netcode.Peer_Id:
		netcode.host_send(&s.host, l, data, reliable || game.message_reliable(.Server, data[0]))
	}
}

// broadcast sends m to every player.
@(private)
broadcast :: proc(s: ^Server, m: game.Server_Message) {
	for &c in s.clients {
		if c.state == .Playing {send_message(s, &c, m)}
	}
}

@(private = "file")
notice :: proc(s: ^Server, c: ^Client, text: string) {
	log.info("server notice ", text)
	send_message(s, c, game.Notice{text})
}

@(private)
player_id :: proc(s: ^Server, c: ^Client) -> u16 {
	return u16(mem.ptr_sub(c, &s.clients[0]))
}

// update_info refreshes what LAN discovery answers.
@(private = "file")
update_info :: proc(s: ^Server) {
	players := 0
	for c in s.clients {if c.state == .Playing {players += 1}}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	name := s.config.name if s.config.name != "" else "Voxiverse server"
	game.encode_server_info(
		&w,
		{
			protocol = game.PROTOCOL_VERSION,
			name = name[:min(len(name), game.MAX_SERVER_NAME)],
			players = players,
			max_players = s.config.max_players,
			password = s.config.password != "",
		},
	)
	netcode.host_set_info(&s.host, w.buf[:])
}

// spawn_point is above the terrain at the origin.
@(private = "file")
spawn_point :: proc(seed: i64) -> [3]f64 {
	h := game.column_height(seed, 0, 0)
	return {0.5, f64(h) + 3, 0.5}
}

@(private = "file")
publish_stats :: proc(s: ^Server, tick_ms: f32) {
	playing := 0
	for c in s.clients {if c.state == .Playing {playing += 1}}
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
		clients           = playing,
		port              = s.host.socket.port if s.listening else 0,
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
