package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../base"
import "../game"
import "../gpu"
import "../netcode"
import "../platform"
import "../render"
import "../server"

// A Session is one visit to a world: from choosing Singleplayer until
// leaving. It owns the connection (to its own in-process server, or over
// the network to someone else's), the client's world copy, the predicted
// player and what it knows of the other players; everything it allocates
// long-term is in its arena, freed at once by session_end. The client talks
// to the server only through messages, the same either way: it sends
// inputs, predicts their effect (game/prediction.odin), and the server's
// Player_Updates have the last word.

Session_Config :: struct {
	name:        string, // the player's
	join:        Maybe(Join), // play on that server; otherwise host the world here
	seed:        i64,
	view_radius: i32,
	view_height: i32,
	trace:       bool, // record every message to net.trace from the start (hosting only)
	capture:     bool, // write every packet to net.pcap (joining only)
	save_dir:    string, // the world's directory; "" = scratch, not saved
}

// Join: a server to play on.
Join :: struct {
	address:  net.Endpoint,
	password: string,
}

Session_State :: enum u8 {
	Connecting, // Hello sent, waiting for Welcome
	Playing,
	Failed, // see failure; the caller ends the session
}

Session :: struct {
	state:       Session_State,
	failure:     string, // why it failed (in the arena)
	arena:       virtual.Arena,
	pipe:        game.Pipe, // to our own server (hosting)
	endpoint:    game.Endpoint,
	server:      server.Server,
	remote:      bool, // playing on someone else's server, through link
	link:        netcode.Link,
	capture:     netcode.Capture,
	last_flush:  time.Tick,
	traffic:     [game.Side]game.Traffic, // counted here when remote (the pipe counts its own)
	others:      map[u16]Other_Player, // the other players, by player id (players.odin)
	entities:    map[u32]Other_Entity, // near us, by id (entities.odin)
	puffs:       [dynamic]Puff, // dying entities' particles
	newest_tick: u32, // of the newest Players or Entities message
	newest_at:   time.Tick, // when it came
	notices:     [dynamic]string, // from the server, for the console (heap: the App prints and frees them)
	welcome:     game.Welcome,
	world:       World, // set up from Welcome
	world_init:  bool,
	camera:      View, // the eyes, from the prediction; looking turns it every frame
	teleport:    Maybe(game.Teleport), // requested before joining: sent on Welcome
	prediction:  game.Prediction,
	rules:       game.Rules, // the server's, as last announced
	clock:       f64, // world time: the server's last word, carried on since (game/time.odin)
	cloud_drift: f64, // blocks the clouds have moved
	tick_time:   f32, // seconds into the current client tick
	toggle_fly:  bool, // a double-tapped jump waits for the next tick
	last_jump:   time.Tick, // for double-tap detection
	autopilot:   Maybe(game.Player_Input), // overrides the controls (fly_test)
	aim:         Maybe(game.Ray_Hit), // the block under the crosshair, within reach
	aim_entity:  Maybe(u32), // an entity under the crosshair, nearer than that block
	edits:       [dynamic]game.Edit, // predicted, waiting for Edit_Result
	next_edit:   u32,
	edit_timer:  f32, // seconds until a held button edits again
	sounds:      [dynamic]Sound_Event, // this frame's; the App plays and clears them
	walked:      f32, // blocks on the ground since the last footstep
	hotbar:      int, // index into HOTBAR
	writer:      game.Writer,
	scratch:     ^game.Block_Array, // decoding target for chunk messages
	received:    [dynamic]game.Packet,
	last_acked:  u32, // the newest Player_Update applied
	frozen:      bool, // paused, the world standing still (session_freeze)
	selection:   [2]Maybe(game.Block_Pos), // pos1, pos2 (bulk edit commands)
	stats:       Session_Stats,
	config:      Session_Config,
	net:         Net_Stats,
}

// Net_Stats: what the F3 overlay shows about the connection.
Net_Stats :: struct {
	rtt_ms:       f32, // last ping round trip (includes the server's tick wait)
	ping_id:      u32,
	ping_sent:    time.Tick,
	ping_pending: bool,
	ping_timer:   f32,
	rate_timer:   f32,
	last:         [game.Side]game.Traffic, // counters at the last rate update
	rates:        [game.Side]game.Traffic, // per second, over the last second
}

Session_Stats :: struct {
	chunks_received: int,
	unloads:         int,
	bytes_received:  int,
}

// session_start starts the server and connects to it. On failure the
// caller still calls session_end.
session_start :: proc(s: ^Session, config: Session_Config) -> bool {
	s^ = {
		config = config,
	}
	if err := virtual.arena_init_growing(&s.arena); err != nil {
		log.errorf("session cannot reserve memory: %v", err)
		return false
	}
	arena := virtual.arena_allocator(&s.arena)
	game.pipe_init(&s.pipe) // heap: both threads allocate and free packets
	s.endpoint = {&s.pipe, .Client}
	s.scratch = new(game.Block_Array, arena)
	game.writer_init(&s.writer, arena)
	s.received = make([dynamic]game.Packet, 0, 256)
	s.edits = make([dynamic]game.Edit, 0, MAX_PENDING_EDITS, arena)
	s.sounds = make([dynamic]Sound_Event, 0, 64, arena)
	s.notices = make([dynamic]string, 0, 16) // heap: notices come and go (an arena would only grow)
	s.others = make(map[u16]Other_Player, arena)
	s.entities = make(map[u32]Other_Entity, 64)
	s.puffs = make([dynamic]Puff, 0, MAX_PUFFS, arena) // never grows: appends check the room
	s.config.name = strings.clone(config.name, arena)

	if join, remote := config.join.?; remote {
		s.remote = true
		if err := netcode.link_connect(&s.link, join.address, join.password, time.tick_now());
		   err != nil {
			fail(s, fmt.tprintf("cannot open a network socket (%v)", err))
			return false
		}
		if config.capture {
			path := path_next_to_exe("net.pcap")
			if netcode.capture_open(&s.capture, path) {
				s.link.socket.capture = &s.capture
				log.infof("session capturing packets path=%s", path)
			}
		}
		log.infof("session connecting to=%s", net.endpoint_to_string(join.address))
		return true // Hello goes once the link is up
	}
	cores := os.get_processor_core_count()
	if !server.start(
	&s.server,
	{
		seed         = config.seed,
		view_radius  = config.view_radius,
		view_height  = config.view_height,
		workers      = max(1, cores / 4),
		allow_cheats = true, // our own world
		save_dir     = config.save_dir,
		name         = filepath.base(config.save_dir) if config.save_dir != "" else "Scratch world",
	},
	{&s.pipe, .Server},
	) {
		fail(s, "the server did not start")
		return false
	}
	if config.trace {session_trace(s)}
	send_message(s, game.Hello{game.PROTOCOL_VERSION, s.config.name})
	return true
}

// session_hosting: the world runs here (else on a remote server).
session_hosting :: proc(s: ^Session) -> bool {
	return !s.remote
}

// session_freeze stops the world while we are paused, if it is ours and
// nobody else can be in it (no remote server, not open to the LAN); then
// the server stands still and so do we. Unpausing lets both go on.
session_freeze :: proc(s: ^Session, paused: bool) {
	want := paused && !s.remote && s.state == .Playing && server.stats(&s.server).port == 0
	if want == s.frozen {return}
	s.frozen = want
	server.freeze(&s.server, want)
}

// session_can_cheat: the server lets this player teleport, change rules and
// run admin commands (sending one otherwise ends the connection).
session_can_cheat :: proc(s: ^Session) -> bool {
	return s.state == .Playing && s.welcome.cheats
}

// session_end stops everything and frees the session; false if the server
// stopped on an error. Call after gpu.wait_idle (meshes are removed).
session_end :: proc(s: ^Session, pass: ^render.World_Pass, g: ^gpu.Gpu) -> bool {
	ok := true
	if s.server.thread != nil {ok = server.stop(&s.server)}
	if s.remote {netcode.link_close(&s.link, "left the game")}
	delete(s.entities) // the heap: entities come and go
	for n in s.notices {delete(n)}
	delete(s.notices)
	netcode.capture_close(&s.capture)
	if s.world_init {
		world_remove_all_meshes(&s.world)
		for h in s.world.mesh_removals {render.world_remove_mesh(pass, g, h)}
		world_destroy(&s.world)
	}
	for p in s.received {game.packet_free(s.endpoint, p)}
	delete(s.received)
	if s.pipe.allocator.procedure != nil {game.pipe_destroy(&s.pipe)}
	log.infof(
		"session ended chunks_received=%d received_mib=%.1f arena_mib=%.1f",
		s.stats.chunks_received,
		f64(s.stats.bytes_received) / (1 << 20),
		f64(s.arena.total_used) / (1 << 20),
	)
	virtual.arena_destroy(&s.arena)
	s^ = {}
	return ok
}

// session_update handles messages, turns the view (when look is true: the
// mouse is captured), runs the client's ticks (inputs: sent and predicted)
// and starts meshing. Every frame, drawn or not.
session_update :: proc(
	s: ^Session,
	input: ^Input_State,
	settings: Settings,
	conditions: game.Conditions,
	dt: f32,
	look: bool,
) {
	base.profile_scope("session")
	if s.remote {
		s.link.socket.conditions = {
			loss       = conditions.loss_percent / 100,
			duplicate  = conditions.dup_percent / 100,
			latency_ms = conditions.latency_ms,
			jitter_ms  = conditions.jitter_ms,
		}
	} else {
		game.pipe_set_conditions(&s.pipe, conditions)
	}
	net_update(s, dt)
	receive(s)
	defer flush(s)
	if s.state != .Playing {return}
	if s.frozen {
		s.tick_time = 0 // and no inputs: the server's player waits too
		world_update(&s.world, camera_chunk(&s.camera)) // what arrives still meshes
		return
	}
	s.clock = game.advance_time(s.clock, f64(dt), &s.rules)
	s.cloud_drift += f64(dt) * render.CLOUD_SPEED
	if look {
		look_update(&s.camera, input, settings)
		if .Space in input.pressed {
			if time.duration_seconds(time.tick_since(s.last_jump)) <
			   DOUBLE_TAP_SECONDS {s.toggle_fly = true}
			s.last_jump = time.tick_now()
		}
	}
	// Fixed ticks, like the server's; a long hitch is not caught up on.
	s.tick_time += dt
	if s.tick_time > 4 * game.TICK_SECONDS {s.tick_time = game.TICK_SECONDS}
	query := game.Block_Query{&s.world, world_block}
	for s.tick_time >= game.TICK_SECONDS {
		s.tick_time -= game.TICK_SECONDS
		in_ :=
			s.autopilot.? or_else (player_input(input, s.camera) if look else game.Player_Input{yaw = s.camera.yaw, pitch = s.camera.pitch})
		if s.toggle_fly {
			in_.buttons += {.Toggle_Fly}
			s.toggle_fly = false
		}
		send_message(s, game.prediction_tick(&s.prediction, in_, &s.rules, query))
		movement_sounds(s)
	}
	if look {edit_controls(s, input, dt)}
	game.prediction_decay(&s.prediction, dt)
	eyes := game.prediction_view(&s.prediction, s.tick_time / game.TICK_SECONDS)
	s.camera.position = eyes + {0, game.PLAYER_EYE, 0}
	s.aim = nil
	f := render.forward(s.camera.yaw, s.camera.pitch)
	if hit, ok := game.raycast(
		query,
		s.camera.position,
		{f64(f.x), f64(f.y), f64(f.z)},
		f64(s.rules.reach),
	); ok {
		s.aim = hit
	}
	// An entity in front of the aimed block takes the click instead.
	s.aim_entity = nil
	nearest := s.aim.?.distance if s.aim != nil else f64(s.rules.reach)
	if id, _, ok := entity_aimed(s, s.camera.position, {f64(f.x), f64(f.y), f64(f.z)}, nearest);
	   ok {
		s.aim_entity = id
	}
	world_update(&s.world, camera_chunk(&s.camera))
}

// session_attack hits the aimed entity; false if none is aimed at.
session_attack :: proc(s: ^Session) -> bool {
	id, ok := s.aim_entity.?
	if !ok {return false}
	send_message(s, game.Attack{id, s.prediction.next_sequence - 1})
	return true
}

// session_apply does the session's GPU work for this frame; between
// render.world_begin and world_draw.
session_apply :: proc(s: ^Session, pass: ^render.World_Pass, g: ^gpu.Gpu) {
	if s.world_init {world_apply(&s.world, pass, g)}
}

// session_teleport asks the server to move the player (feet at position;
// now, or as soon as we have joined).
session_teleport :: proc(s: ^Session, t: game.Teleport) {
	if s.state == .Playing {
		send_message(s, t)
	} else {
		s.teleport = t
	}
}

// session_set_rule asks the server to change a rule (rules.* name).
session_set_rule :: proc(s: ^Session, name, value: string) {
	send_message(s, game.Set_Rule{name, value})
}

@(private = "file")
receive :: proc(s: ^Session) {
	if s.remote {
		was := s.link.state
		netcode.link_update(&s.link, time.tick_now())
		if s.link.state == .Failed {
			fail(s, s.link.reason)
			return
		}
		if was != .Connected && s.link.state == .Connected {
			log.info("session connected")
			send_message(s, game.Hello{game.PROTOCOL_VERSION, s.config.name})
		}
		netcode.link_receive(&s.link, &s.received)
		for p in s.received {
			s.traffic[.Server].messages[p[0]] += 1
			s.traffic[.Server].bytes[p[0]] += len(p)
		}
	} else {
		game.receive(s.endpoint, &s.received)
	}
	defer {
		for p in s.received {
			if s.remote {netcode.link_free(&s.link, p)} else {game.packet_free(s.endpoint, p)}
		}
		clear(&s.received)
	}
	for p in s.received {
		if s.state == .Failed {return}
		s.stats.bytes_received += len(p)
		m, ok := game.decode_server(p, s.scratch)
		if !ok {
			fail(s, "the server sent an invalid message")
			return
		}
		switch v in m {
		case game.Welcome:
			welcome(s, v)
		case game.Reject:
			fail(
				s,
				strings.concatenate({"the server refused: ", v.reason}, context.temp_allocator),
			)
		case game.Chunk_Message:
			if s.state != .Playing {
				fail(s, "the server sent a chunk before welcoming us")
				return
			}
			if !world_set_chunk(&s.world, v, s.scratch) {
				fail(s, "too many chunks: the server sent more than its interest area")
				return
			}
			s.stats.chunks_received += 1
		case game.Pong:
			if s.net.ping_pending && v.id == s.net.ping_id {
				s.net.rtt_ms = f32(time.duration_milliseconds(time.tick_since(s.net.ping_sent)))
				s.net.ping_pending = false
			}
		case game.Unload_Chunk:
			if s.state != .Playing {
				fail(s, "the server unloaded a chunk before welcoming us")
				return
			}
			world_remove_chunk(&s.world, v.pos)
			s.stats.unloads += 1
		case game.Player_Update:
			// States can overtake the Welcome over the network (they travel
			// unreliably, apart from it); newer ones follow every tick.
			if s.state != .Playing {continue}
			// Over the network a teleport (sent reliably) may arrive after a
			// newer update: then only its direction still matters.
			if v.acked != 0 && game.sequence_before(v.acked, s.last_acked) {
				if v.teleported {s.camera.yaw, s.camera.pitch = v.yaw, v.pitch}
				continue
			}
			s.last_acked = v.acked
			game.prediction_reconcile(&s.prediction, v, &s.rules, {&s.world, world_block})
			if v.teleported {s.camera.yaw, s.camera.pitch = v.yaw, v.pitch}
		case game.Rules_Changed:
			s.rules = v.rules
		case game.Time:
			s.clock = v.time
		case game.Player_Joined:
			s.others[v.player] = {
				name = strings.clone(v.name, virtual.arena_allocator(&s.arena)),
			}
			notice(s, fmt.tprintf("%s joined", v.name))
		case game.Player_Left:
			if o, known := s.others[v.player]; known {notice(s, fmt.tprintf("%s left", o.name))}
			delete_key(&s.others, v.player)
		case game.Players:
			if s.newest_at == {} || game.sequence_before(s.newest_tick, v.tick) {
				s.newest_tick, s.newest_at = v.tick, time.tick_now()
			}
			for i in 0 ..< v.count {
				e := v.entries[i]
				if o, known := &s.others[e.player]; known {other_snapshot(o, v.tick, e)}
			}
		case game.Notice:
			notice(s, v.text)
		case game.Bulk_Begin:
			world_bulk_begin(&s.world, int(v.count))
		case game.Explosion:
			explosion_effects(s, v.position, f64(v.radius))
		case game.Entity_Spawn:
			s.entities[v.entity] = {
				kind      = v.kind,
				last_seen = v.position,
			}
			e := &s.entities[v.entity]
			track_add(&e.track, {tick = s.newest_tick, position = v.position, yaw = v.yaw})
		case game.Entities:
			if s.newest_at == {} || game.sequence_before(s.newest_tick, v.tick) {
				s.newest_tick, s.newest_at = v.tick, time.tick_now()
			}
			for i in 0 ..< v.count {
				x := v.entries[i]
				if e, known := &s.entities[x.entity]; known {
					track_add(&e.track, {v.tick, x.position, x.yaw, x.pitch, false})
				}
			}
		case game.Entity_Despawn:
			if e, known := &s.entities[v.entity]; known && v.died {
				entity_died(s, e)
			}
			delete_key(&s.entities, v.entity)
		case game.Entity_Hurt:
			if e, known := &s.entities[v.entity]; known {
				e.hurt_at = time.tick_now()
				append(&s.sounds, Sound_Event{.Entity_Hurt, .Air, e.last_seen + {0, 0.5, 0}, 1})
			}
		case game.Edit_Result:
			// The server's word, accepted or not: set it (undoing a rejected
			// prediction) and stop waiting.
			world_set_block(&s.world, v.pos, v.block)
			for e, i in s.edits {
				if e.id == v.id {
					ordered_remove(&s.edits, i)
					break
				}
			}
		case game.Block_Changed:
			// Someone else's edit: heard where it happened.
			old, _ := world_block(&s.world, v.pos)
			if world_set_block(&s.world, v.pos, v.block) && old != v.block {
				edit_sound(s, v.pos, old, v.block)
			}
		case game.Column:
			if s.state != .Playing {
				fail(s, "the server sent a column before welcoming us")
				return
			}
			world_set_column(&s.world, v)
		}
	}
}

@(private = "file")
welcome :: proc(s: ^Session, w: game.Welcome) {
	if s.state != .Connecting {
		fail(s, "the server welcomed us twice")
		return
	}
	if w.protocol != game.PROTOCOL_VERSION || w.tick_rate != game.TICK_RATE {
		fail(s, "the server runs a different version")
		return
	}
	s.welcome = w
	// Everything the server can send us at once: the interest area plus the
	// margin within which we keep chunks.
	r, h :=
		i32(w.view_radius) + game.CLIENT_DROP_MARGIN, i32(w.view_height) + game.CLIENT_DROP_MARGIN
	capacity := game.interest_count(r, h)
	columns := game.interest_count(r, 0)
	cores := os.get_processor_core_count()
	if err := world_init(
		&s.world,
		capacity,
		columns,
		max(1, cores / 4),
		virtual.arena_allocator(&s.arena),
	); err != nil {
		fail(s, "out of memory for the world")
		return
	}
	s.world_init = true
	s.rules = w.rules
	game.prediction_init(&s.prediction, {position = w.spawn})
	s.camera = {
		position = w.spawn + {0, game.PLAYER_EYE, 0},
	}
	s.state = .Playing
	if t, ok := s.teleport.?; ok && w.cheats {send_message(s, t)}
	log.infof("session joined view=%dx%d capacity=%d", w.view_radius, w.view_height, capacity)
}

// session_others_now: the server time (ticks) to show the other players at.
session_others_now :: proc(s: ^Session) -> f64 {
	return render_tick(s.newest_tick, f32(time.duration_seconds(time.tick_since(s.newest_at))))
}

// notice keeps a message from the server for the console.
@(private = "file")
notice :: proc(s: ^Session, text: string) {
	log.info("session ", text)
	append(&s.notices, strings.clone(text))
}

// flush sends what is due over the network (about once per display frame
// at most: acknowledgements need not go out a thousand times a second).
@(private = "file")
flush :: proc(s: ^Session) {
	if !s.remote {return}
	now := time.tick_now()
	if time.tick_diff(s.last_flush, now) < FLUSH_INTERVAL {return}
	s.last_flush = now
	netcode.link_flush(&s.link, now)
}

FLUSH_INTERVAL :: 8 * time.Millisecond

// session_trace starts recording every message to net.trace next to the
// executable (see netdump and replay in DEBUGGING.md).
session_trace :: proc(s: ^Session) -> bool {
	path := path_next_to_exe("net.trace")
	header := game.Trace_Header {
		protocol     = game.PROTOCOL_VERSION,
		seed         = s.config.seed,
		view_radius  = u32(s.config.view_radius),
		view_height  = u32(s.config.view_height),
		allow_cheats = true, // as session_start configures it
	}
	if !game.pipe_trace_start(&s.pipe, path, header) {
		log.errorf("net trace cannot write path=%s", path)
		return false
	}
	log.infof("net trace recording path=%s", path)
	return true
}

// net_update pings once a second and refreshes the per-second rates.
@(private = "file")
net_update :: proc(s: ^Session, dt: f32) {
	n := &s.net
	n.ping_timer += dt
	if n.ping_timer >= 1 && !n.ping_pending && s.state == .Playing {
		n.ping_timer = 0
		n.ping_id += 1
		n.ping_sent = time.tick_now()
		n.ping_pending = true
		send_message(s, game.Ping{n.ping_id})
	}
	n.rate_timer += dt
	if n.rate_timer >= 1 {
		now := s.traffic if s.remote else game.pipe_traffic(&s.pipe)
		for side in game.Side {
			for k in 0 ..< 256 {
				n.rates[side].messages[k] = int(
					math.round(
						f32(now[side].messages[k] - n.last[side].messages[k]) / n.rate_timer,
					),
				)
				n.rates[side].bytes[k] = int(
					f32(now[side].bytes[k] - n.last[side].bytes[k]) / n.rate_timer,
				)
			}
		}
		n.last = now
		n.rate_timer = 0
	}
}

@(private = "file")
fail :: proc(s: ^Session, reason: string) {
	log.errorf("session %s", reason)
	s.state = .Failed
	s.failure = strings.clone(reason, virtual.arena_allocator(&s.arena))
	if !s.remote && s.pipe.allocator.procedure != nil {game.close(s.endpoint)}
}

// The blocks a player can place, in hotbar order.
@(rodata)
HOTBAR := [?]game.Block{.Stone, .Dirt, .Grass, .Sand, .Gravel, .Lamp}

// LAUNCHER: the hotbar slot after the blocks holds the creative rocket
// launcher, where the server allows it (it is a cheat).
LAUNCHER :: len(HOTBAR)

// hotbar_slots: how many slots the hotbar has here.
hotbar_slots :: proc(s: ^Session) -> int {
	return len(HOTBAR) + (1 if session_can_cheat(s) else 0)
}

MAX_PENDING_EDITS :: 64
EDIT_REPEAT_SECONDS :: 0.25 // a held button edits again this often

// edit_controls: number keys and the wheel pick the hotbar block; left
// click breaks the aimed block, right click places against its face. Edits
// are predicted at once (if the shared rules allow them) and sent.
@(private = "file")
edit_controls :: proc(s: ^Session, input: ^Input_State, dt: f32) {
	keys := [?]platform.Key{.Num_1, .Num_2, .Num_3, .Num_4, .Num_5, .Num_6, .Num_7, .Num_8, .Num_9}
	slots := hotbar_slots(s)
	for k, i in keys[:slots] {
		if k in input.pressed {s.hotbar = i}
	}
	if input.wheel.y != 0 {
		s.hotbar = (s.hotbar - int(math.sign(input.wheel.y)) + slots) % slots
	}
	s.hotbar = min(s.hotbar, slots - 1)

	s.edit_timer -= dt
	breaking := .Left in input.mouse_down
	placing := .Right in input.mouse_down
	pressed := input.mouse_pressed & {.Left, .Right} != {}
	if !(breaking || placing) || (!pressed && s.edit_timer > 0) {return}
	s.edit_timer = EDIT_REPEAT_SECONDS
	if s.hotbar == LAUNCHER {
		if breaking {session_fire(s)}
		return
	}
	if breaking && !placing && session_attack(s) {return}
	session_edit(s, placing && !breaking, HOTBAR[s.hotbar])
}

// session_fire launches a rocket where we look (the server makes it).
session_fire :: proc(s: ^Session) -> bool {
	if !session_can_cheat(s) {return false}
	send_message(s, game.Fire{s.prediction.next_sequence - 1, s.camera.yaw, s.camera.pitch})
	append(&s.sounds, Sound_Event{.Launch, .Air, s.camera.position, 1})
	return true
}

// session_edit breaks the aimed block, or places block against its face:
// predicted now if the shared rules allow it, then sent. False if not.
session_edit :: proc(s: ^Session, place: bool, block: game.Block) -> bool {
	hit, aimed := s.aim.?
	if !aimed || len(s.edits) >= MAX_PENDING_EDITS {return false}
	edit := game.Edit {
		id    = s.next_edit + 1,
		after = s.prediction.next_sequence - 1, // the last input predicted
	}
	if !place {
		b, _ := world_block(&s.world, hit.block)
		if !game.can_break(b) {return false}
		edit.pos, edit.block = hit.block, .Air
	} else {
		if hit.normal == {} {return false}
		edit.pos = hit.block + hit.normal
		current, loaded := world_block(&s.world, edit.pos)
		if !loaded || !game.can_place_at(current, edit.pos, s.prediction.state) {return false}
		edit.block = block
	}
	before, _ := world_block(&s.world, edit.pos)
	if !world_set_block(&s.world, edit.pos, edit.block) {return false}
	edit_sound(s, edit.pos, before, edit.block)
	s.next_edit = edit.id
	append(&s.edits, edit)
	send_message(s, edit)
	return true
}

// edit_sound: a block at pos went from old to new.
@(private = "file")
edit_sound :: proc(s: ^Session, pos: game.Block_Pos, old, new: game.Block) {
	centre := [3]f64{f64(pos.x), f64(pos.y), f64(pos.z)} + 0.5
	if new == .Air {
		append(&s.sounds, Sound_Event{.Break, old, centre, 1})
	} else {
		append(&s.sounds, Sound_Event{.Place, new, centre, 1})
	}
}

// movement_sounds: footsteps every STRIDE blocks walked and landings
// (louder the harder), from the tick the prediction just ran. Flying is
// silent.
@(private = "file")
movement_sounds :: proc(s: ^Session) {
	was, now := s.prediction.previous, s.prediction.state
	if now.flying || was.flying {
		s.walked = 0
		return
	}
	feet := now.position
	under, solid := block_under(s, feet)
	if !was.on_ground && now.on_ground {
		speed := -was.velocity.y
		if speed >= LAND_MIN_SPEED && solid {
			loud := clamp((speed - LAND_MIN_SPEED) / (LAND_LOUD_SPEED - LAND_MIN_SPEED), 0.25, 1)
			append(&s.sounds, Sound_Event{.Land, under, feet, loud})
		}
		s.walked = 0
	}
	if now.on_ground {
		d := now.position - was.position
		s.walked += f32(math.sqrt(d.x * d.x + d.z * d.z))
		if s.walked >= STRIDE {
			s.walked -= STRIDE
			if solid {append(&s.sounds, Sound_Event{.Step, under, feet, 1})}
		}
	}
}

// block_under: the block the player stands on (under the middle of the
// feet, else under a corner of them, at the edge of a drop).
@(private = "file")
block_under :: proc(s: ^Session, feet: [3]f64) -> (game.Block, bool) {
	y := i32(math.floor(feet.y - 0.05))
	h := f64(game.PLAYER_WIDTH) / 2
	for o in ([?][2]f64{{0, 0}, {-h, -h}, {h, -h}, {-h, h}, {h, h}}) {
		b, _ := world_block(
			&s.world,
			{i32(math.floor(feet.x + o.x)), y, i32(math.floor(feet.z + o.y))},
		)
		if game.block_solid(b) {return b, true}
	}
	return .Air, false
}

@(private)
send_message :: proc(s: ^Session, m: game.Client_Message) {
	clear(&s.writer.buf)
	game.encode_client(&s.writer, m)
	data := s.writer.buf[:]
	if s.remote {
		s.traffic[.Client].messages[data[0]] += 1
		s.traffic[.Client].bytes[data[0]] += len(data)
		netcode.link_send(&s.link, data, game.message_reliable(.Client, data[0]))
	} else {
		game.send(s.endpoint, data)
	}
}
