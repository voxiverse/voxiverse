package core

import "base:runtime"
import "core:log"
import "core:mem"
import "core:net"
import "core:time"

import "common:game"
import "common:netcode"
import "common:protocol"

// The deterministic harness (docs/determinism.md, "The harness"): a stepped
// server, an in-memory network on a tick clock, the fixed flat world and one
// stepping API. Nothing in it reads a clock or sleeps: what a test waits for
// is a number of ticks, the same on every machine.

Harness :: struct {
	srv:     Server,
	net:     netcode.Simnet, // every remote player's network (the server listens on it)
	pipe:    protocol.Pipe, // the local player's (harness_local), when there is one
	parties: [dynamic]Harness_Party, // run each tick before the server, in the order added
	started: bool,
	local:   bool,
	last:    State_Hash, // the last step's
	temp:    runtime.Arena, // the steps' temp allocator: the server frees it each tick, the test's own stays
}

// Harness_Party: the mirror, a test client, a client session driven by a
// test, a bot: whatever the test gives it. The harness never decodes a message.
Harness_Party :: struct {
	tick: proc(data: rawptr), // receive what has arrived, decide, send
	data: rawptr,
}

// HARNESS_GAME: the game a harness server plays when its config names none (every
// session plays one): no hooks and nothing of its own, so the engine's tests run the
// engine as it is. A client that joins one needs its client part (engine.HARNESS_GAME).
HARNESS_GAME :: Game {
	info = {
		id = "harness",
		name = "Harness",
		description = "The engine's tests' game: no rules of its own.",
	},
}

// harness_game: config, playing HARNESS_GAME if it names no game.
@(private = "file")
harness_game :: proc(config: Config) -> Config {
	c := config
	if c.game.id == "" {c.game = HARNESS_GAME}
	return c
}

// harness_refused: whether `start` refuses this configuration, and cleanly
// (the refusal is the point, so its log is muted; a failed start leaves no
// state behind). A test of a refusal asks here, so no test starts a server
// itself; a server that did start is stopped again. A config that names no
// game plays HARNESS_GAME, as harness_start's does.
harness_refused :: proc(config: Config) -> bool {
	context.logger = log.nil_logger()
	srv: Server
	if start(&srv, harness_game(config), {}) {
		stop(&srv)
		return false
	}
	return mem.check_zero(mem.ptr_to_bytes(&srv))
}

HARNESS_SEED :: 66 // issue #66; the flat world does not depend on it, its RNG streams do

// harness_rules: the defaults with random ticks and the daylight cycle off.
// (The game has no weather yet; when it has, its switch is added here, off.)
harness_rules :: proc() -> game.Rules {
	r := game.RULES_DEFAULTS
	r.random_tick_speed = 0
	r.daylight_cycle = false
	return r
}

// harness_world: the fixed small test world. Natural spawning, random ticks
// and the daylight cycle are off; a test turns one on by changing the config
// before harness_start, or the rule through /gamerule as a player would.
// HARNESS_KIT: what the harness's worlds give their players, blocks to place and break
// (the engine's own default is nothing; a game's rig gives the game's kit instead).
HARNESS_KIT :: "stone 64, dirt 64, grass 64, sand 64, log 64, leaves 64, water 64, lamp 64, rocket_launcher 1"

harness_world :: proc() -> Config {
	return {
		kit = HARNESS_KIT,
		seed = HARNESS_SEED,
		generator = .Flat,
		view_radius = 2,
		view_height = 1,
		spawn = [3]f64{0.5, 0, 0.5},
		max_players = 8,
		allow_cheats = true,
		everyone_cheats = true,
		no_natural_spawns = true,
		backups = 0,
		rules = harness_rules(),
	}
}

// harness_start starts the server on the harness's network (stepped, no
// workers). h must stay at its address until harness_stop. local: the
// in-process player takes seat 0 on a pipe, as singleplayer does. A config that
// names no game plays HARNESS_GAME.
harness_start :: proc(
	h: ^Harness,
	config: Config,
	local := false,
	conditions := netcode.Conditions{},
) -> bool {
	h^ = {}
	h.temp.backing_allocator = runtime.heap_allocator()
	// (the network's packets are not the server's memory: a test that tracks the
	// server's allocations does not count what is in flight)
	netcode.simnet_init(&h.net, conditions, runtime.heap_allocator())
	h.net.now = harness_time(0)
	c := harness_game(config)
	c.stepped, c.workers, c.net = true, 0, &h.net
	end: protocol.Endpoint
	if local {
		protocol.pipe_init(&h.pipe)
		h.pipe.clock, h.pipe.start = &h.net.now, h.net.now // (latency and jitter in ticks of the harness, drawn from its seed)
		protocol.pipe_seed(&h.pipe, HARNESS_SEED)
		end = {&h.pipe, .Server}
		h.local = true
	}
	if !start(&h.srv, c, end) {
		// (h.srv stays as start left it: its refusal says why)
		if local {protocol.pipe_destroy(&h.pipe)}
		netcode.simnet_destroy(&h.net)
		h.local = false
		return false
	}
	h.started = true
	return true
}

// harness_local: the client's end of the pipe.
harness_local :: proc(h: ^Harness) -> protocol.Endpoint {
	assert(h.local, "harness_local needs harness_start(local = true)")
	return {&h.pipe, .Client}
}

// harness_address: where the server listens on the simulated network.
harness_address :: proc(h: ^Harness) -> net.Endpoint {
	assert(h.srv.listening, "harness_address needs a server that listens (Config.listen)")
	return {net.IP4_Loopback, h.srv.host.socket.port}
}

// harness_add adds a party, run every tick before the server.
harness_add :: proc(h: ^Harness, tick: proc(data: rawptr), data: rawptr) {
	append(&h.parties, Harness_Party{tick, data})
}

@(private = "file")
harness_time :: proc(tick: u64) -> time.Tick {
	return netcode.simnet_tick_time(tick, game.TICK_RATE)
}

// harness_step runs n ticks and returns the last one's hash. A tick is: the
// network's clock moves to the time of the tick about to run, every party
// takes its turn in the order added, the server steps. What a party sends in
// a tick is handled in that tick; what the server sends at its end is there
// for the parties at the next.
harness_step :: proc(h: ^Harness, n := 1) -> State_Hash {
	for _ in 0 ..< n {
		h.net.now = harness_time(h.srv.tick + 1)
		for p in h.parties {p.tick(p.data)}
		// (the server frees the temp allocator at the end of a tick: its own arena, so what
		// the test holds in the test's survives the steps; the parties keep the test's, as a
		// thread a party starts keeps the context it was started in)
		{
			context.temp_allocator = runtime.arena_allocator(&h.temp)
			h.last = step(&h.srv)
		}
	}
	return h.last
}

// harness_step_until steps until `until` is true (checked after each tick), at
// most max_ticks ticks. ok is false when it never was (then exactly max_ticks
// ran): it never sleeps and never reads a clock.
harness_step_until :: proc(
	h: ^Harness,
	until: proc(data: rawptr) -> bool,
	data: rawptr,
	max_ticks: int,
) -> (
	ticks: int,
	ok: bool,
) {
	for ticks < max_ticks {
		harness_step(h)
		ticks += 1
		if until(data) {return ticks, true}
	}
	return ticks, false
}

harness_ticks :: proc(h: ^Harness) -> u64 {return h.srv.tick}

// harness_stop stops the server, then the pipe and the network (whatever is
// still in flight is freed). The parties are the test's to end.
harness_stop :: proc(h: ^Harness) -> bool {
	ok := stop(&h.srv)
	if h.local {protocol.pipe_destroy(&h.pipe)}
	netcode.simnet_destroy(&h.net)
	runtime.arena_destroy(&h.temp)
	delete(h.parties)
	h^ = {}
	return ok
}
