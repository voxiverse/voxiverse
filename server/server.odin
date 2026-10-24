package server

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../base"
import "../game"
import "../netcode"
import "../worldgen"

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
	generator:       worldgen.Kind, // for a new world (a saved one keeps its own)
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
	spawn:           Maybe([3]f64), // a new world's spawn (lands on the ground there), not the generator's
	world_idle:      f64, // seconds a world with nobody in it stays loaded (0: WORLD_IDLE_SECONDS)
	gate_open:       f64, // seconds a dialed gate stays open (0: GATE_OPEN_TICKS)
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
	generate:          base.Frame_Summary, // ms per chunk, on the workers (updated each second)
	updates_waiting:   int, // scheduled block updates (flowing water)
	worlds:            int, // loaded
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
	store:       Store, // saving (save.odin)
	// Server thread only, after start:
	arena:       virtual.Arena,
	home:        ^World, // the universe's first world (always loaded)
	worlds:      [dynamic]^World, // loaded (home first)
	clients:     []Client, // index = player id
	host:        netcode.Host, // remote players (listening when host_open)
	listening:   bool,
	capture:     netcode.Capture, // (config.capture)
	perms:       Permissions, // who may do what (permissions.odin)
	community:   Community, // nicknames, mutes, homes, warps, bans (community.odin)
	chat:        Chat_State, // (chat.odin)
	kit:         [dynamic]game.Stack, // what new players are given (player_data.odin; world.cfg)
	offsets:     []game.Chunk_Pos, // the interest area around a client, nearest first
	writer:      game.Writer,
	tick:        u64,
}

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
	kit_default(&s.kit)
	s.home = world_make(s)
	append(&s.worlds, s.home)
	// A saved world's seed and rules replace the config's.
	if !store_open(s, config.save_dir) {
		teardown(s, world = false)
		return false
	}
	permissions_open(s)
	community_open(s)
	characters_open(s)
	s.offsets = game.interest_offsets(config.view_radius, config.view_height, arena)
	// Loaded chunks stay within the unload distance of some player, plus
	// chunks still generating that were requested before they moved.
	per_player := game.interest_count(
		config.view_radius + game.SERVER_UNLOAD_MARGIN,
		config.view_height + game.SERVER_UNLOAD_MARGIN,
	)
	capacity := per_player * s.config.max_players + config.workers * MAX_IN_FLIGHT_PER_WORKER
	s.capacity = capacity
	if !world_start(s.home) {
		teardown(s, world = false)
		return false
	}
	s.clients = make([]Client, s.config.max_players, arena)
	for &c in s.clients {
		if err := client_init(&c, s.config, arena); err != nil {
			log.errorf("server cannot allocate client state: %v", err)
			teardown(s, world = true)
			return false
		}
	}
	game.writer_init(&s.writer, arena, game.MAX_MESSAGE_SIZE) // never grows: the arena stays flat
	if local.pipe != nil {
		s.clients[0].state = .Connecting
		s.clients[0].link = Local{}
	}
	if config.listen && !listen(s, config.port, config.port) {
		teardown(s, world = true)
		return false
	}

	s.thread = thread.create(server_main, name = "server")
	s.thread.data = s
	s.thread.init_context = context
	thread.start(s.thread)
	log.infof(
		"server started seed=%d generator=%s view=%dx%d workers=%d capacity=%d seats=%d",
		s.config.seed,
		worldgen.KIND_NAMES[s.config.generator],
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
	used := s.arena.total_used
	ticks := s.tick
	failed := sync.atomic_load(&s.failed)
	teardown(s, world = true)
	log.infof("server stopped ticks=%d arena=%v", ticks, base_bytes(used))
	return !failed
}

// teardown frees the session, started (stop) or partly (a start that
// failed: what was not set up yet is zero; world: whether it was).
@(private = "file")
teardown :: proc(s: ^Server, world: bool) {
	netcode.capture_close(&s.capture)
	store_close(s)
	permissions_destroy(&s.perms)
	community_destroy(&s.community)
	delete(s.kit)
	for &c in s.clients {client_reset(&c)}
	for w in s.worlds {world_close(w)}
	delete(s.worlds)
	virtual.arena_destroy(&s.arena)
	s^ = {}
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
	for w in s.worlds {
		chunks_collect(
			&w.chunks,
			proc(pos: game.Chunk_Pos, data: rawptr) -> bool {
				w := (^World)(data)
				if !anyone_wants(w, pos, game.SERVER_UNLOAD_MARGIN) {return false}
				// Water next door that stopped at this chunk's edge flows on.
				origin := game.chunk_origin(pos)
				wake_water_box(w, origin, origin + game.CHUNK_SIZE - 1, only_border = true)
				return true
			},
			w,
		)
		naturals_take(w)
	}
	{
		base.profile_scope("receive")
		receive_messages(s)
	}
	frozen := sync.atomic_load(&s.frozen) && !s.listening
	if !frozen {
		for w in s.worlds {w.clock = game.advance_time(w.clock, f64(game.TICK_SECONDS), &w.rules)}
	}
	moved := false
	for &c in s.clients {
		if c.state != .Playing {continue}
		if s.tick % game.TICK_RATE == 0 {send_message(s, &c, game.Time{c.world.clock})}
		simulate_player(s, &c)
		if c.moved {
			base.profile_scope("drop far")
			c.moved = false
			moved = true
			drop_far(s, &c)
		}
	}
	worlds_unload_idle(s)
	for w in s.worlds {
		if moved {
			base.profile_scope("unload unwanted")
			unload_unwanted(w)
		}
		if !frozen {
			updates_run(w)
			entities_tick(w)
		}
		gates_tick(w)
		base.profile_scope("changes flush")
		changes_flush(w)
	}
	for &c in s.clients {
		if c.state != .Playing {continue}
		send_players(s, &c)
		replicate(s, &c)
		if c.inv_changed {
			send_message(s, &c, game.Inventory_Update{c.inv_acked, c.inventory})
			c.inv_changed = false
		}
		base.profile_scope("stream")
		stream(s, &c)
	}
	kick_due(s)
	if s.listening {
		if s.tick % game.TICK_RATE == 0 {update_info(s)}
		base.profile_scope("network flush")
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
			c.address = strings.clone(
				net.address_to_string(v.address.address, context.temp_allocator),
			)
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

// enter: a proved account plays its character name (a new one if the name
// is free), or is told why not.
@(private = "file")
enter :: proc(s: ^Server, c: ^Client, name: string) {
	if owner, taken := s.store.characters[name]; taken && owner != c.account {
		disconnect(s, c, "that name is another account's")
		return
	}
	for &other in s.clients {
		if other.state == .Playing && client_name(&other) == name {
			disconnect(s, c, "someone with that name is playing")
			return
		}
	}
	if _, mine := s.store.characters[name];
	   !mine && len(characters_of(s, c.account)) >= game.MAX_CHARACTERS {
		disconnect(s, c, "this account has as many characters as it may here")
		return
	}
	if why, banned := banned(s, name, c.address, c.account); banned {
		log.infof("server banned player refused name=%s address=%s", name, c.address)
		disconnect(s, c, why)
		return
	}
	character_claim(s, name, c.account)
	join(s, c, name)
}

// handle one message from a client.
@(private = "file")
handle :: proc(s: ^Server, c: ^Client, p: []u8) {
	w := c.world
	if c.state == .Free || c.state == .Gone {return}
	m, ok := game.decode_client(p)
	if !ok {
		disconnect(s, c, "invalid message")
		return
	}
	// Before playing only the handshake (or a ping) makes sense.
	if c.state != .Playing {
		handshake: bool
		#partial switch _ in m {
		case game.Hello, game.Proof, game.Choose, game.Ping:
			handshake = true
		}
		if !handshake {
			disconnect(s, c, "message before hello")
			return
		}
	}
	// What needs permission (refused with a word; commands check their own).
	node := ""
	#partial switch v in m {
	case game.Teleport:
		node = "teleport.tp"
	case game.Set_Rule:
		node = "world.gen" if strings.has_prefix(v.name, "worldgen.") else "world.rules"
	case game.Fire:
		node = "world.fire"
	case game.Edit:
		node = "world.edit"
	case game.Chat:
		node = "chat.send"
	}
	if node != "" && !allowed(s, c, node) {
		if e, edit := m.(game.Edit); edit {
			current, _ := chunks_block(&w.chunks, e.pos)
			send_message(s, c, game.Edit_Result{id = e.id, pos = e.pos, block = current})
		}
		notice(s, c, fmt.tprintf("You may not do that here (%s)", node))
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
		if v.character != "" && !game.name_valid(v.character) {
			disconnect(s, c, "names are 1 to 16 letters, digits, _ or -")
			return
		}
		c.account = v.account
		c.wanted_len = copy(c.wanted[:], v.character)
		c.nonce = game.nonce_make()
		c.state = .Proving
		send_message(s, c, game.Challenge{c.nonce})
	case game.Proof:
		if c.state != .Proving {
			disconnect(s, c, "unexpected proof")
			return
		}
		if !game.account_verify(c.account, c.nonce, v.signature) {
			log.warnf("server account proof failed account=%s", game.account_text(c.account))
			disconnect(s, c, "the account's proof is wrong")
			return
		}
		c.nonce = {} // (used: a proof is for one nonce)
		if c.wanted_len == 0 {
			c.state = .Choosing
			names := characters_of(s, c.account)
			send_message(s, c, game.Characters{strings.join(names, " ", context.temp_allocator)})
			return
		}
		enter(s, c, string(c.wanted[:c.wanted_len]))
	case game.Choose:
		if c.state != .Choosing || !game.name_valid(v.character) {
			disconnect(s, c, "unexpected choice")
			return
		}
		enter(s, c, v.character)
	case game.Input:
		game.input_queue_push(&c.inputs, v)
	case game.Teleport:
		land(s, c, v.position, {v.yaw, v.pitch}, .Exact)
	case game.Set_Rule:
		if strings.has_prefix(v.name, "worldgen.") {
			set_worldgen(s, c, v.name, v.value)
			return
		}
		switch err := base.var_set(game.rules_table(), &w.rules, v.name, v.value); err {
		case .None, .Out_Of_Range:
			if err ==
			   .Out_Of_Range {log.warnf("server rule clamped name=%q value=%q", v.name, v.value)}
			log.infof(
				"server rule changed name=%s value=%s by=%s",
				v.name,
				v.value,
				client_name(c),
			)
			broadcast(s, game.Rules_Changed{w.rules}, w)
		case .Unknown_Name, .Bad_Value:
			log.warnf("server rule not changed name=%q value=%q problem=%v", v.name, v.value, err)
		}
	case game.Ping:
		send_message(s, c, game.Pong{v.id})
	case game.Command:
		admin(s, c, v.command)
	case game.Chat:
		chat_say(s, c, v.text)
	case game.Inventory_Request:
		inventory_request(s, c, v)
	case game.Dial:
		notice_if(s, c, gate_dial(s, c, v))
	case game.Edit:
		queue_action(s, c, v)
	case game.Attack:
		queue_action(s, c, v)
	case game.Fire:
		queue_action(s, c, v)
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
) -> (
	bytes: int,
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
	return len(data)
}

// broadcast sends m to every player (in world, if given: its news).
@(private)
broadcast :: proc(s: ^Server, m: game.Server_Message, world: ^World = nil) {
	for &c in s.clients {
		if c.state == .Playing && (world == nil || c.world == world) {send_message(s, &c, m)}
	}
}

@(private)
notice :: proc(s: ^Server, c: ^Client, text: string) {
	log.info("server notice ", text)
	text := text
	if len(text) > game.MAX_NOTICE_TEXT {
		cut := game.MAX_NOTICE_TEXT
		for cut > 0 && text[cut] & 0xc0 == 0x80 {cut -= 1} 	// (a whole letter)
		text = text[:cut]
	}
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

@(private = "file")
publish_stats :: proc(s: ^Server, tick_ms: f32) {
	playing := 0
	for c in s.clients {if c.state == .Playing {playing += 1}}
	st := Stats {
		tick           = s.tick,
		tick_ms        = tick_ms,
		arena_used     = s.arena.total_used,
		arena_reserved = s.arena.total_reserved,
		clients        = playing,
		port           = s.host.socket.port if s.listening else 0,
		worlds         = len(s.worlds),
	}
	for w in s.worlds {
		st.chunks_loaded += w.chunks.chunks.count
		st.chunks_generating += w.chunks.in_flight
		st.arrays_allocated += w.chunks.arrays.allocated
		st.arrays_in_use += game.block_arrays_in_use(&w.chunks.arrays)
		st.arrays_bytes += w.chunks.arrays.committed
		st.arena_used += w.arena.total_used
		st.arena_reserved += w.arena.total_reserved
		st.updates_waiting += w.updates.count
	}
	sync.guard(&s.stats_mutex)
	// Sorting the window for percentiles: once a second is enough (the
	// home world's: where the tests and the F3 numbers look).
	st.generate =
		base.frame_stats_summary(&s.home.chunks.gen_times) if s.tick % game.TICK_RATE == 0 else s.stats.generate
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
