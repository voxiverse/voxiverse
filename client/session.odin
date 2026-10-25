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
import "../worldgen"
import "mesh"

// A Session is one visit to a world: from choosing Singleplayer until
// leaving. It owns the connection (to its own in-process server, or over
// the network to someone else's), the client's world copy, the predicted
// player and what it knows of the other players; everything it allocates
// long-term is in its arena, freed at once by session_end. The client talks
// to the server only through messages, the same either way: it sends
// inputs, predicts their effect (game/prediction.odin), and the server's
// Player_Updates have the last word.

Session_Config :: struct {
	name:         string, // the character to play ("": ask for the account's)
	key:          game.Account_Key, // the account
	join:         Maybe(Join), // play on that server; otherwise host the world here
	seed:         i64,
	view_radius:  i32,
	view_height:  i32,
	trace:        bool, // record every message to net.trace from the start (hosting only)
	capture:      bool, // write every packet to net.pcap (joining only)
	save_dir:     string, // the world's directory; "" = scratch, not saved
	spawn:        Maybe([3]f64), // a new world's spawn (else the generator's)
	no_sheep:     bool, // (hosting) none appear by themselves: benchmarks
	still_clouds: bool, // the clouds stay where they start: benchmarks
}

// Join: a server to play on.
Join :: struct {
	address:  net.Endpoint,
	password: string,
}

Session_State :: enum u8 {
	Connecting, // Hello sent, waiting for Welcome
	Choosing, // the account's characters arrived: pick one (or make one)
	Playing,
	Failed, // see failure; the caller ends the session
}

Session :: struct {
	state:            Session_State,
	loading:          Maybe(Loading), // the loading screen is up (loading.odin)
	failure:          string, // why it failed (in the arena)
	arena:            virtual.Arena,
	pipe:             game.Pipe, // to our own server (hosting)
	endpoint:         game.Endpoint,
	server:           server.Server,
	remote:           bool, // playing on someone else's server, through link
	link:             netcode.Link,
	capture:          netcode.Capture,
	last_flush:       time.Tick,
	traffic:          [game.Side]game.Traffic, // counted here when remote (the pipe counts its own)
	others:           map[u16]Other_Player, // the other players, by player id (players.odin)
	entities:         map[u32]Other_Entity, // near us, by id (entities.odin)
	puffs:            [dynamic]Puff, // particles: debris, smoke, a dying entity's puff
	worldgen:         worldgen.Params, // the server's generator settings (Variables), if it has any
	has_worldgen:     bool,
	grants:           [dynamic]game.Grant, // what the server lets this player do (heap)
	characters:       [dynamic]string, // the account's, to choose from (heap; Choosing)
	commands:         [dynamic]string, // the server commands it may use (heap, for Tab)
	chat:             [dynamic]Chat_Entry, // the lines kept (heap; chat.odin)
	texels:           [mesh.Texture][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba, // block textures, for debris
	newest_tick:      u32, // of the newest Players or Entities message
	newest_at:        time.Tick, // when it came
	notices:          [dynamic]string, // from the server, for the console (heap: the App prints and frees them)
	welcome:          game.Welcome,
	world:            World, // set up from Welcome
	world_init:       bool,
	camera:           View, // the eyes, from the prediction; looking turns it every frame
	teleport:         Maybe(game.Teleport), // requested before joining: sent on Welcome
	prediction:       game.Prediction,
	rules:            game.Rules, // the server's, as last announced
	clock:            f64, // world time: the server's last word, carried on since (game/time.odin)
	cloud_drift:      f64, // blocks the clouds have moved
	tick_time:        f32, // seconds into the current client tick
	toggle_fly:       bool, // a double-tapped jump waits for the next tick
	last_jump:        time.Tick, // for double-tap detection
	sneak_on:         bool,
	eye_height:       f64, // the camera above the feet: easing to player_eye_height // toggled sneaking and sprinting (Options: Toggle)
	sprint_on:        bool,
	autopilot:        Maybe(game.Player_Input), // overrides the controls (fly_test)
	aim:              Maybe(game.Ray_Hit), // the block under the crosshair, within reach
	aim_entity:       Maybe(u32), // an entity under the crosshair, nearer than that block
	edits:            [dynamic]game.Edit, // predicted, waiting for Edit_Result
	next_edit:        u32,
	edit_timer:       f32, // seconds until a held button edits again
	sounds:           [dynamic]Sound_Event, // this frame's; the App plays and clears them
	walked:           f32, // blocks on the ground since the last footstep
	drop_repeat:      Drop_Repeat, // the drop key held (items.odin)
	inventory:        game.Inventory, // as we predict it (items.odin)
	server_inventory: game.Inventory, // as the server last said
	inv_pending:      [dynamic]Pending_Inventory, // sent, not yet answered (heap)
	inv_sequence:     u32,
	writer:           game.Writer,
	scratch:          ^game.Block_Array, // decoding target for chunk messages
	received:         [dynamic]game.Packet,
	last_acked:       u32, // the newest Player_Update applied
	frozen:           bool, // paused, the world standing still (session_freeze)
	selection:        [2]Maybe(game.Block_Pos), // the server's word on our world-editing selection (drawn)
	stats:            Session_Stats,
	config:           Session_Config,
	net:              Net_Stats,
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

// worker_count: threads for each pool (the server's generation, our
// meshing): a quarter of the cores each, leaving the rest to the game.
@(private)
worker_count :: proc() -> int {
	return max(1, os.get_processor_core_count() / 4)
}

// session_start starts the server and connects to it. On failure the
// caller still calls session_end.
session_start :: proc(s: ^Session, config: Session_Config) -> bool {
	s^ = {
		config = config,
	}
	loading_begin(s, false)
	if err := virtual.arena_init_growing(&s.arena); err != nil {
		log.errorf("session cannot reserve memory: %v", err)
		return false
	}
	arena := virtual.arena_allocator(&s.arena)
	s.scratch = new(game.Block_Array, arena)
	game.writer_init(&s.writer, arena, game.MAX_MESSAGE_SIZE) // never grows: the arena stays flat
	s.received = make([dynamic]game.Packet, 0, 256)
	s.edits = make([dynamic]game.Edit, 0, MAX_PENDING_EDITS, arena)
	s.sounds = make([dynamic]Sound_Event, 0, 64, arena)
	s.notices = make([dynamic]string, 0, 16) // heap: notices come and go (an arena would only grow)
	s.others = make(map[u16]Other_Player) // heap: players come and go (an arena would only grow)
	s.entities = make(map[u32]Other_Entity, 64)
	s.puffs = make([dynamic]Puff, 0, MAX_PUFFS, arena) // never grows: appends check the room
	for &pixels, t in s.texels {mesh.generate_texture(t, pixels[:])}
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
	// Our own world: its server here, through the pipe.
	game.pipe_init(&s.pipe) // heap: both threads allocate and free packets
	s.endpoint = {&s.pipe, .Client}
	if !server.start(
	&s.server,
	{
		seed         = config.seed,
		view_radius  = config.view_radius,
		view_height  = config.view_height,
		workers      = worker_count(),
		allow_cheats = true, // our own world
		save_dir     = config.save_dir,
		spawn        = config.spawn,
		no_sheep     = config.no_sheep,
		rules        = still_rules() if config.no_sheep else {},
		name         = filepath.base(config.save_dir) if config.save_dir != "" else "Scratch world",
	},
	{&s.pipe, .Server},
	) {
		fail(s, "the world could not start (the log says why)")
		return false
	}
	if config.trace {session_trace(s)}
	send_message(s, game.Hello{game.PROTOCOL_VERSION, s.config.key.account, s.config.name})
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

// session_allowed: the server lets this player do node (its Grants; it
// checks again).
session_allowed :: proc(s: ^Session, node: string) -> bool {
	return s.state == .Playing && game.allowed(s.grants[:], node)
}

// session_end stops everything and frees the session; false if the server
// stopped on an error. Call after gpu.wait_idle (meshes are removed).
session_end :: proc(s: ^Session, pass: ^render.World_Pass, g: ^gpu.Gpu) -> bool {
	ok := true
	if s.server.thread != nil {ok = server.stop(&s.server)}
	if s.remote {netcode.link_close(&s.link, "left the game")}
	delete(s.entities) // the heap: entities come and go
	for g in s.grants {delete(g.pattern)}
	delete(s.grants)
	for c in s.commands {delete(c)}
	delete(s.commands)
	for c in s.characters {delete(c)}
	delete(s.characters)
	delete(s.inv_pending)
	for e in s.chat {delete(e.text)}
	delete(s.chat)
	for _, o in s.others {delete(o.name)}
	delete(s.others)
	for n in s.notices {delete(n)}
	delete(s.notices)
	netcode.capture_close(&s.capture)
	if s.world_init {
		st := &s.world.stats
		times := base.frame_stats_summary(&st.mesh_times)
		log.infof(
			"session mesher meshed=%d remeshed=%d stale=%d dirtied_resent=%d dirtied_edit=%d dirtied_column=%d mesh_ms_p50=%.2f p99=%.2f",
			st.meshed,
			st.remeshed,
			st.stale_meshes,
			st.dirtied_resent,
			st.dirtied_edit,
			st.dirtied_column,
			times.p50,
			times.p99,
		)
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
	base.metric_scope(.Frame_Session)
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
	if !s.config.still_clouds {s.cloud_drift += f64(dt) * render.CLOUD_SPEED}
	if look {
		look_update(&s.camera, input, settings)
		toggle :: proc(input: ^Input_State, key: platform.Key, toggles: bool, on: ^bool) {
			if !toggles {on^ = false} else if key in input.pressed {on^ = !on^}
		}
		toggle(input, settings.keys.sneak, settings.sneak_toggle, &s.sneak_on)
		toggle(input, settings.keys.sprint, settings.sprint_toggle, &s.sprint_on)
		if settings.keys.jump in input.pressed {
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
			s.autopilot.? or_else (player_input(input, s, settings.keys) if look else game.Player_Input{yaw = s.camera.yaw, pitch = s.camera.pitch})
		if s.toggle_fly {
			in_.buttons += {.Toggle_Fly}
			s.toggle_fly = false
		}
		send_message(s, game.prediction_tick(&s.prediction, in_, &s.rules, query))
		movement_sounds(s)
	}
	if look {edit_controls(s, input, settings.keys, dt)}
	game.prediction_decay(&s.prediction, dt)
	eyes := game.prediction_view(&s.prediction, s.tick_time / game.TICK_SECONDS)
	// The eyes ease down when crouching and back up (not a jump cut).
	eye := game.player_eye_height(s.prediction.state)
	s.eye_height += (eye - s.eye_height) * f64(1 - math.exp(-15 * dt))
	if s.eye_height == 0 {s.eye_height = eye}
	s.camera.position = eyes + {0, s.eye_height, 0}
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

// session_others_now: the server time (ticks) to show the other players at.
session_others_now :: proc(s: ^Session) -> f64 {
	return render_tick(s.newest_tick, f32(time.duration_seconds(time.tick_since(s.newest_at))))
}

FLUSH_INTERVAL :: 8 * time.Millisecond

// server_explode: an explosion at block p of radius blocks, done by our own
// in-process server (server.call): checks and benchmarks, not a command.
server_explode :: proc(s: ^Session, p: game.Block_Pos, radius: f64) {
	Explosion :: struct {
		at:     game.Block_Pos,
		radius: f64,
	}
	e := Explosion{p, radius}
	server.call(&s.server, proc(srv: ^server.Server, data: rawptr) {
			e := (^Explosion)(data)
			server.explode_by(srv, "", e.at, e.radius)
		}, &e)
}

// still_rules: the defaults with nothing changing by itself (random ticks
// off), for benchmarks and exit checks.
still_rules :: proc() -> game.Rules {
	r := game.RULES_DEFAULTS
	r.random_tick_speed = 0
	return r
}
