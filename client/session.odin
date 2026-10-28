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
import "../common/game"
import "../common/netcode"
import "../common/worldgen"
import "../server"
import "gpu"
import "mesh"
import "render"

// A Session is one visit to a world: from choosing Singleplayer until
// leaving. It owns the connection (to its own in-process server, or over
// the network to someone else's), the client's world copy, the predicted
// player and what it knows of the other players; everything it allocates
// long-term is in its arena, freed at once by session_end. The client talks
// to the server only through messages, the same either way: it sends
// inputs, predicts their effect (common/game/prediction.odin), and the server's
// Player_Updates have the last word.

Session_Config :: struct {
	name:         string, // the character to play ("": ask for the account's)
	key:          game.Account_Key, // the account
	join:         Maybe(Join), // play on that server; otherwise host the world here
	seed:         i64,
	mode:         string, // a new universe's default game mode ("": creative)
	view_radius:  i32,
	view_height:  i32,
	trace:        bool, // record every message to net.trace from the start (hosting only)
	capture:      bool, // write every packet to net.pcap (joining only)
	save_dir:     string, // the world's directory; "" = scratch, not saved
	spawn:        Maybe([3]f64), // a new world's spawn (else the generator's)
	no_sheep:     bool, // (hosting) none appear by themselves: benchmarks
	still_clouds: bool, // the clouds stay where they start: benchmarks
	upload:       Maybe(server.Upload), // (hosting) send its event log to a collector
	registry:     ^game.Registry, // the game's own (the base pack): what a remote server must match
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
	loading:          Maybe(Loading), // the loading screen is up (screen_loading.odin)
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
	texels:           [][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba, // block textures by layer, for debris (made again when the registry is swapped)
	render_clock:     Render_Clock, // when to show the others (players.odin)
	notices:          [dynamic]string, // from the server, for the console (heap: the App prints and frees them)
	welcome:          game.Welcome,
	reg:              ^game.Registry, // what the blocks and items are: the game's, or (hosting) the universe's
	reg_owned:        bool, // reg is the universe's own (freed with the session)
	reg_fresh:        ^game.Registry, // the registry the server's reload made, waiting for the mesh jobs to end (hot reload; the App swaps it in)
	reg_swapped:      bool, // reg was replaced by the packs of the server joined (the App makes the new items' icons, then clears it)
	fetch:            ^game.Pack_Fetch, // the server's packs, while joining (pack_fetch.odin)
	fetching:         bool, // a Packs message came
	fetched:          bool, // ... and its registry is built
	world:            World, // set up from Welcome
	world_init:       bool,
	camera:           View, // the eyes, from the prediction; looking turns it every frame
	view:             View, // what is drawn from: the eyes, or the third person camera, with the bobbing (view_camera.odin)
	camera_mode:      Camera_Mode, // F5 (not saved)
	pull:             f64, // the third person camera's distance now (pulled in against walls, easing back out)
	fov_kick:         f32, // 0 ..= 1: how far the sprint widening has come
	bob_phase:        f32,
	bob_amp:          f32, // 0 ..= 1, easing in and out as walking starts and stops
	aiming:           bool, // a held item that aims is aimed (the crosshair stays in third person)
	weapon_clock:     f64, // seconds, advanced by the frames (weapons.odin's timers)
	shot_next:        f64, // when the held weapon may fire again (its rate)
	ammo_shown:       int, // the magazine as predicted ...
	ammo_until:       f64, // ... until this time (the server's word is shown after)
	reload_end:       f64, // when the reload we asked for is done (0: none)
	reload_slot:      int,
	recoil:           f32, // radians the view is lifted by the last shots (cosmetic)
	zoom:             f32, // 0 ..= 1: how far the held weapon's zoom has come
	zoom_to:          f32, // the held weapon's field-of-view factor
	marker:           f32, // seconds the hit marker has left
	marker_kill:      bool,
	marker_head:      bool,
	hurt_age:         f32, // seconds since the last Damage_Hit
	shots:            int, // shots we fired (tests)
	confirms:         int, // Hit_Confirm events seen
	feet:             [3]f64, // where the predicted player stands (the avatar in third person)
	teleport:         Maybe(game.Teleport), // requested before joining: sent on Welcome
	prediction:       game.Prediction,
	rules:            game.Rules, // the server's, as last announced
	clock:            f64, // world time: the server's last word, carried on since (common/game/time.odin)
	cloud_drift:      f64, // blocks the clouds have moved
	tick_time:        f32, // seconds into the current client tick
	toggle_fly:       bool, // a double-tapped jump waits for the next tick
	last_jump:        time.Tick, // for double-tap detection
	sneak_on:         bool,
	eye_height:       f64, // the camera above the feet: easing to player_eye_height // toggled sneaking and sprinting (Options: Toggle)
	sprint_on:        bool,
	sprint_moved:     bool, // moved since the sprint toggled on
	autopilot:        Maybe(game.Player_Input), // overrides the controls (fly_test)
	aim:              Maybe(game.Ray_Hit), // the block under the crosshair, within reach
	aim_entity:       Maybe(u32), // an entity under the crosshair, nearer than that block
	edits:            [dynamic]game.Edit, // predicted, waiting for Edit_Result
	next_edit:        u32,
	edit_timer:       f32, // seconds until a held button edits again
	input_yaw:        f32, // the yaw of the last input predicted (the one an edit follows)
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
	last_acked:       u32, // the acked of the newest Own_Player applied
	schema:           game.Schema, // what the server replicates (state_kinds.odin)
	rx:               game.Receiver, // what it has told us (State and Snapshot messages)
	teleports:        u8, // Own_Player.teleports as last seen
	frozen:           bool, // paused, the world standing still (session_freeze)
	selection:        [2]Maybe(game.Block_Pos), // the server's word on our world-editing selection (drawn)
	stats:            Session_Stats,
	mode:             int, // the game mode the server last said (Mode): an index into reg.game_modes
	health:           f32, // as the server last said (Health)
	max_health:       f32,
	hurt:             game.Damage_Hit, // the last hit (the damage direction on the screen)
	hurts:            int, // Damage_Hits seen
	dead:             bool, // at the death screen (Health.dead)
	death_line:       [96]u8, // how it happened, as the death screen says it
	death_len:        int,
	tally:            game.Tally, // our kills and deaths (the P list)
	place:            game.Place, // the server's word on where we are (the music's)
	home:             game.Address, // the world we joined in (the music's "home")
	died:             int, // Player_Died events seen (the music's death stinger)
	arrivals:         int, // arrivals through a gate or travel (the music's discovery stinger)
	player_stats:     Stats_Data, // the counters the server last sent (menu_statistics.odin)
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
	s.schema = game.game_schema()
	s.reg = config.registry
	game.receiver_init(&s.rx, &s.schema, s.reg)
	s.received = make([dynamic]game.Packet, 0, 256)
	s.edits = make([dynamic]game.Edit, 0, MAX_PENDING_EDITS, arena)
	s.sounds = make([dynamic]Sound_Event, 0, 64, arena)
	s.notices = make([dynamic]string, 0, 16) // heap: notices come and go (an arena would only grow)
	s.others = make(map[u16]Other_Player) // heap: players come and go (an arena would only grow)
	s.entities = make(map[u32]Other_Entity, 64)
	s.puffs = make([dynamic]Puff, 0, MAX_PUFFS, arena) // never grows: appends check the room
	session_texels(s)
	s.config.name = strings.clone(config.name, arena)
	s.config.save_dir = strings.clone(config.save_dir, arena)

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
	if own := server.registry_for_dir(config.save_dir, base_dir = server.dev_base_dir());
	   own != nil {
		s.reg, s.reg_owned = own, true // (the universe's packs: the base's, and what it lists)
		game.receiver_destroy(&s.rx) // (the receiver is made again over the new registry)
		game.receiver_init(&s.rx, &s.schema, s.reg)
		session_texels(s)
	}
	if !server.start(
	&s.server,
	{
		seed         = config.seed,
		mode         = config.mode,
		view_radius  = config.view_radius,
		view_height  = config.view_height,
		workers      = worker_count(),
		allow_cheats = true, // our own world
		save_dir     = config.save_dir,
		pack_watch   = base.DEV, // (a development build reloads packs when their files change)
		spawn        = config.spawn,
		no_sheep     = config.no_sheep,
		upload       = config.upload,
		rules        = still_rules() if config.no_sheep else {},
		name         = filepath.base(config.save_dir) if config.save_dir != "" else "Scratch world",
	},
	{&s.pipe, .Server},
	) {
		reason := s.server.refusal if s.server.refusal != "" else "the log says why"
		fail(s, fmt.tprintf("the world could not start: %s", reason))
		return false
	}
	if config.trace {session_trace(s)}
	send_message(
		s,
		game.Hello{game.PROTOCOL_VERSION, s.config.key.account, s.config.name, s.schema.hash},
	)
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

// session_ability: the character can do a (its mode's profile and what it wears:
// the same derive_abilities the server asks).
session_ability :: proc(s: ^Session, a: game.Ability) -> bool {
	return s.state == .Playing && a in game.derive_abilities(s.reg, s.mode, &s.inventory)
}

// session_end stops everything and frees the session; false if the server
// stopped on an error. Call after gpu.wait_idle (meshes are removed).
session_end :: proc(s: ^Session, pass: ^render.World_Pass, g: ^gpu.Gpu) -> bool {
	ok := true
	if s.server.thread != nil {ok = server.stop(&s.server)}
	if s.remote {netcode.link_close(&s.link, "left the game")}
	delete(s.entities) // the heap: entities come and go
	game.receiver_destroy(&s.rx)
	game.schema_destroy(&s.schema)
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
	stats_data_clear(&s.player_stats)
	delete(s.player_stats.lines)
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
	if s.fetch != nil {
		game.pack_fetch_destroy(s.fetch)
		free(s.fetch)
	}
	delete(s.texels)
	if s.reg_fresh != nil {game.registry_destroy(s.reg_fresh)}
	if s.reg_owned {game.registry_destroy(s.reg)}
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
	actions: ^Actions,
	settings: Settings,
	conditions: game.Conditions,
	dt: f32,
	look: bool,
) {
	base.profile_scope("session")
	base.metric_scope(.Frame_Session)
	clock_advance(&s.render_clock, dt)
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
		look_update(&s.camera, input, actions, settings, dt, zoom_factor(s))
		movement_toggles(s, actions, settings)
		if action_pressed(actions, .Jump) {
			if time.duration_seconds(time.tick_since(s.last_jump)) <
			   DOUBLE_TAP_SECONDS {s.toggle_fly = true}
			s.last_jump = time.tick_now()
		}
	}
	// Fixed ticks, like the server's; a long hitch is not caught up on.
	s.tick_time += dt
	if s.tick_time > 4 * game.TICK_SECONDS {s.tick_time = game.TICK_SECONDS}
	query := game.Block_Query{&s.world, world_block, &s.reg.blocks}
	for s.tick_time >= game.TICK_SECONDS {
		s.tick_time -= game.TICK_SECONDS
		in_ :=
			s.autopilot.? or_else (player_input(actions, s) if look else game.Player_Input{yaw = s.camera.yaw, pitch = s.camera.pitch})
		s.input_yaw = in_.yaw
		if s.toggle_fly {
			in_.buttons += {.Toggle_Fly}
			s.toggle_fly = false
		}
		sent := game.prediction_tick(
			&s.prediction,
			in_,
			&s.rules,
			query,
			game.derive_character(s.reg, s.mode, &s.inventory),
		)
		sent.snapshot = s.rx.ack
		send_message(s, sent)
		send_prediction_check(s, sent.sequence)
		movement_sounds(s)
	}
	if look {edit_controls(s, input, actions, dt)}
	game.prediction_decay(&s.prediction, dt)
	eyes := game.prediction_view(&s.prediction, s.tick_time / game.TICK_SECONDS)
	// The eyes ease down when crouching and back up (not a jump cut).
	eye := game.player_eye_height(s.prediction.state)
	s.eye_height += (eye - s.eye_height) * f64(1 - math.exp(-15 * dt))
	if s.eye_height == 0 {s.eye_height = eye}
	s.camera.position = eyes + {0, s.eye_height, 0}
	s.feet = eyes
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
	camera_update(s, actions, settings, query, dt, look)
	world_update(&s.world, camera_chunk(&s.camera))
}

// movement_toggles: sneak and sprint as Options chooses: held, or toggled by
// a press (sneak stays until pressed again; sprint also ends when you stop
// moving after you had started). Hold clears what a toggle left.
movement_toggles :: proc(s: ^Session, actions: ^Actions, settings: Settings) {
	toggle :: proc(a: ^Actions, action: Action, toggles: bool, on: ^bool) {
		if !toggles {on^ = false} else if action_pressed(a, action) {on^ = !on^}
	}
	toggle(actions, .Sneak, settings.sneak_toggle, &s.sneak_on)
	toggle(actions, .Sprint, settings.sprint_toggle, &s.sprint_on)
	if actions.move != {} {s.sprint_moved = true} else if s.sprint_moved {
		s.sprint_on, s.sprint_moved = false, false
	}
	if !s.sprint_on {s.sprint_moved = false}
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

// session_others_now: the server time (ticks) to show the other players
// and entities at, and whether the connection is live: snapshots stopped
// coming for STALE_SECONDS means what we know of them is old, so none is
// shown. (A thing that stands still sends nothing, and is still there.)
session_others_now :: proc(s: ^Session) -> (now: f64, live: bool) {
	return s.render_clock.time, clock_live(s.render_clock)
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

// still_rules: nothing changing by itself, for benchmarks and exit checks.
still_rules :: proc() -> game.Rules {
	return game.rules_still()
}

// session_texels makes the block textures' pixels of s.reg (for debris and
// colours), one per layer of the texture array.
session_texels :: proc(s: ^Session) {
	delete(s.texels)
	s.texels = make(
		[][mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE]mesh.Rgba,
		game.registry_texture_layers(s.reg),
	)
	for &pixels, layer in s.texels {mesh.texture_layer_pixels(s.reg, u32(layer), pixels[:])}
}
