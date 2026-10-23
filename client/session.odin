package client

import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"

import "../base"
import "../game"
import "../gpu"
import "../render"
import "../server"

// A Session is one visit to a world: from choosing Singleplayer until
// leaving. It owns the in-process server, the connection, the client's
// world copy and the camera; everything it allocates long-term is in its
// arena, freed at once by session_end. The client talks to the server only
// through messages, as it will over the network.

Session_Config :: struct {
	seed:        i64,
	view_radius: i32,
	view_height: i32,
}

Session_State :: enum u8 {
	Connecting, // Hello sent, waiting for Welcome
	Playing,
	Failed, // see failure; the caller ends the session
}

Session :: struct {
	state:      Session_State,
	failure:    string, // why it failed (in the arena)
	arena:      virtual.Arena,
	pipe:       game.Pipe,
	endpoint:   game.Endpoint,
	server:     server.Server,
	welcome:    game.Welcome,
	world:      World, // set up from Welcome
	world_init: bool,
	camera:     Fly_Camera,
	teleport:   Maybe(Fly_Camera), // requested before joining: applied on Welcome
	writer:     game.Writer,
	scratch:    ^game.Block_Array, // decoding target for chunk messages
	received:   [dynamic]game.Packet,
	sent_at:    f32, // seconds since the last Move
	last_sent:  [3]f64,
	stats:      Session_Stats,
}

Session_Stats :: struct {
	chunks_received: int,
	unloads:         int,
	bytes_received:  int,
}

// session_start starts the server and connects to it. On failure the
// caller still calls session_end.
session_start :: proc(s: ^Session, config: Session_Config) -> bool {
	s^ = {}
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

	cores := os.get_processor_core_count()
	if !server.start(
		&s.server,
		{
			seed = config.seed,
			view_radius = config.view_radius,
			view_height = config.view_height,
			workers = max(1, cores / 4),
		},
		{&s.pipe, .Server},
	) {
		fail(s, "the server did not start")
		return false
	}
	send_message(s, game.Hello{game.PROTOCOL_VERSION, "player"})
	return true
}

// session_end stops everything and frees the session; false if the server
// stopped on an error. Call after gpu.wait_idle (meshes are removed).
session_end :: proc(s: ^Session, pass: ^render.World_Pass, g: ^gpu.Gpu) -> bool {
	ok := true
	if s.server.thread != nil {ok = server.stop(&s.server)}
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

// session_update handles messages, moves the camera (when look is true:
// the mouse is captured) and starts meshing. Every frame, drawn or not.
session_update :: proc(s: ^Session, input: ^Input_State, settings: Settings, dt: f32, look: bool) {
	base.profile_scope("session")
	receive(s)
	if s.state != .Playing {return}
	if look {camera_update(&s.camera, input, settings, dt)}
	s.sent_at += dt
	if s.sent_at >= 1.0 / game.TICK_RATE && s.camera.position != s.last_sent {
		send_message(s, game.Move{s.camera.position})
		s.last_sent = s.camera.position
		s.sent_at = 0
	}
	world_update(&s.world, camera_chunk(&s.camera))
}

// session_apply does the session's GPU work for this frame; between
// render.world_begin and world_draw.
session_apply :: proc(s: ^Session, pass: ^render.World_Pass, g: ^gpu.Gpu) {
	if s.world_init {world_apply(&s.world, pass, g)}
}

// session_teleport moves the camera (now, or on joining).
session_teleport :: proc(s: ^Session, camera: Fly_Camera) {
	if s.state == .Playing {
		s.camera = camera
	} else {
		s.teleport = camera
	}
}

@(private = "file")
receive :: proc(s: ^Session) {
	game.receive(s.endpoint, &s.received)
	defer {
		for p in s.received {game.packet_free(s.endpoint, p)}
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
		case game.Unload_Chunk:
			if s.state != .Playing {
				fail(s, "the server unloaded a chunk before welcoming us")
				return
			}
			world_remove_chunk(&s.world, v.pos)
			s.stats.unloads += 1
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
	cores := os.get_processor_core_count()
	if err := world_init(&s.world, capacity, max(1, cores / 4), virtual.arena_allocator(&s.arena));
	   err != nil {
		fail(s, "out of memory for the world")
		return
	}
	s.world_init = true
	s.camera = s.teleport.? or_else {position = w.spawn}
	s.last_sent = w.spawn
	s.state = .Playing
	log.infof("session joined view=%dx%d capacity=%d", w.view_radius, w.view_height, capacity)
}

@(private = "file")
fail :: proc(s: ^Session, reason: string) {
	log.errorf("session %s", reason)
	s.state = .Failed
	s.failure = strings.clone(reason, virtual.arena_allocator(&s.arena))
	game.close(s.endpoint)
}

@(private = "file")
send_message :: proc(s: ^Session, m: game.Client_Message) {
	clear(&s.writer.buf)
	game.encode_client(&s.writer, m)
	game.send(s.endpoint, s.writer.buf[:])
}
