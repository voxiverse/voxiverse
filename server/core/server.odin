package core

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:access"
import "common:base"
import "common:game"
import "common:netcode"
import "common:protocol"
import "common:telemetry"
import "common:worldgen"
import "server:collector"
import steam_server "server:steam"
import "server:store"

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

// Upload: send the event log to a collector (collector/) every interval
// (default 30 s) and at stop, as this account.
Upload :: struct {
	address:  net.Endpoint,
	key:      access.Account_Key,
	interval: time.Duration,
}

// Config: what a server session is started with (start): the universe, its worlds' defaults,
// the game it plays; a game's configure hook may change it.
Config :: struct {
	kit:                   string, // what new players are given, as world.cfg's kit says it ("": the world's own, else the default: the launcher)
	upload:                Maybe(Upload), // (needs save_dir: a scratch world has no log)
	seed:                  i64,
	earth:                 bool, // a new universe's home world is Earth (its fixed address) rather than one made from the seed
	mode:                  string, // a new universe's default game mode, by id ("": creative; a saved one keeps its own: universe.cfg)
	mode_changed:          bool, // /gamemode changed it since the universe was made (saved)
	generator:             worldgen.Kind, // for a new world (a saved one keeps its own)
	view_radius:           i32, // chunks, horizontally
	view_height:           i32, // chunks above and below
	workers:               int,
	allow_cheats:          bool, // the local player may Teleport, Set_Rule and Admin
	everyone_cheats:       bool, // ... and so may remote players
	save_dir:              string, // the world's directory; "" = not saved (its seed and rules win over these)
	rules:                 game.Rules, // zero: the defaults
	max_players:           int, // seats (0: DEFAULT_MAX_PLAYERS)
	listen:                bool, // take remote players from the start (else only after Admin "open_lan")
	port:                  int, // ... on this UDP port (0: any free one)
	password:              string, // remote players must know it ("": none)
	name:                  string, // what LAN discovery shows
	capture:               string, // write every packet to this pcap file once listening ("": no)
	conditions:            netcode.Conditions, // simulated loss etc. on what the server sends (tests)
	spawn:                 Maybe([3]f64), // a new world's spawn (lands on the ground there), not the generator's
	world_idle:            f64, // seconds a world with nobody in it stays loaded (0: WORLD_IDLE_SECONDS)
	gate_open:             f64, // seconds a dialed gate stays open (0: GATE_OPEN_TICKS)
	pack_watch:            bool, // development: reload the packs when their files change (pack_reload.odin)
	no_natural_spawns:     bool, // none appear by themselves (benchmarks: the same work every run)
	net:                   ^netcode.Simnet, // listen on this simulated network, not UDP (needs stepped; no conditions: the network's are the only ones)
	stepped:               bool, // no thread: the caller runs ticks with step (determinism.md), workers may be 0
	perturb:               Perturb, // tests only (refused unless stepped): a deliberate nondeterminism
	backups:               Maybe(int), // rolling backups kept (nil: BACKUP_KEEP; 0: none)
	journal_memory:        int, // tests: entries in a world's journal ring (0: JOURNAL_MEMORY)
	journal_segment_bytes: int, // tests: where a journal segment ends (0: JOURNAL_SEGMENT_BYTES)
	journal_timed:         bool, // tests: time the journal (Journal.cost_ticks)
	journal_detail:        u64, // tests: ticks a segment keeps its detail (0: JOURNAL_DETAIL)
	journal_keep:          u64, // tests: ticks a segment is kept (0: JOURNAL_KEEP)
	journal_max_bytes:     u64, // tests: the journal directory's size limit (0: JOURNAL_MAX_BYTES)
	steam:                 ^steam_server.Server, // checks joining players' Steam tickets (nil or off: tickets are ignored); the caller opens and shuts it
	watchdog_seconds:      int, // kill on a deadlocked tick (>0: seconds, default 60 on dedicated, 0: off)
	extra_packs:           []game.Pack_Source, // packs besides the universe's own and the game's (tests, tools), loaded last
	available_packs:       []store.Pack_Candidate, // where a listed pack the universe lacks is found, in order (the client's local packs, the Workshop)
	game:                  Game, // the game the server runs (games/): every session plays one, so start refuses a config without it
}

// Game: a game the server runs (docs/games.md): its id, the types of its state, and
// the hooks the server calls. The engine never imports a game: whoever starts the
// server puts one in Config.game. Any hook may be nil. configure and start run on
// the thread that calls start, stop on the one that calls stop, the rest on the
// server's, in its tick.
Game :: struct {
	using info:     game.Game_Info, // its id (its folder's name in games/: the dedicated server's --game), name and description (its shared package's)
	kinds:          protocol.Game_Kinds, // what it replicates besides the engine (its shared package's; game_put, game_event)
	server_state:   typeid, // its state for the session (game_state): zero at start; nil: none
	client_state:   typeid, // ... and for each seat (game_client_state): zero for each player who joins; nil: none
	entity_data:    typeid, // its record on each entity of its pack's kinds (entity_data): zero at spawn, saved with the world; nil: none
	stats:          []Game_Stat, // the statistics it keeps of its players (stat_count, stat_world): with the character, shown with the engine's
	character_data: typeid, // its record on each character (character_data): zero for a new one, kept with the character and saved in its file; nil: none
	world_state:    typeid, // its state for each world (world_state): zero when the world opens, freed with it; nil: none
	world_files:    []World_File, // the files it keeps in each world's directory (world_file_read, world_file_write)
	configure:      proc(config: ^Config), // before anything else: may change the config
	start:          proc(s: ^Server) -> bool, // the session is set up, no tick has run (false: start fails)
	stop:           proc(s: ^Server), // after the last tick, before the last save
	tick:           proc(s: ^Server), // every tick, after the entities' (also while frozen)
	spawned:        proc(s: ^Server, w: ^World, h: game.Entity_Handle) -> (keep: bool), // a creature of a kind with a spawn rule appeared by itself (natural): the game makes it what it is (its record, its looks) or refuses it (false: it goes)
	think:          proc(
		s: ^Server,
		w: ^World,
		kind: game.Kind_Id,
		entities: []game.Entity_Handle,
	), // each tick, the creatures of each of its kinds whose brain is "game" (their ground loaded, lowest id first), before they are steered
	joined:         proc(s: ^Server, c: ^Client), // c is playing (welcomed, in its world)
	left:           proc(s: ^Server, c: ^Client), // c is leaving (still seated, its state still there)
	command:        proc(s: ^Server, c: ^Client, name: string, args: []string) -> (known: bool), // a command the server has none of; known false: "Unknown server command"
	hurt:           proc(s: ^Server, c: ^Client, harm: Harm), // c was hurt and lives (its health already less)
	died:           proc(s: ^Server, c: ^Client, harm: Harm), // c died of harm (already told, counted and its things dropped)
	respawned:      proc(s: ^Server, c: ^Client), // c stands again: at the world's spawn, full health, the mode's kit (the game may move it, change what it holds)
	editing:        proc(
		s: ^Server,
		c: ^Client,
		at: game.Block_Pos,
		old, new: game.Block,
	) -> (
		refusal: string,
	), // c would change the block at `at` (its rules and reach allow it): "" lets it, else the edit is refused and c is told why
	entity_use:     proc(
		s: ^Server,
		c: ^Client,
		h: game.Entity_Handle,
		stack: game.Stack,
	) -> (
		refusal: string,
	), // c uses (right-clicks) the entity h within its reach, holding stack: the game does what the use does for its kinds and says "", or refuses (nothing happens, c is told why); then the engine's own use of the kind, if any
	block_changed:  proc(s: ^Server, w: ^World, change: Block_Change), // blocks of w changed (by a player, the world, a command, the game): told once a tick, before the game's tick
	entity_hurt:    proc(s: ^Server, w: ^World, h: game.Entity_Handle, harm: Entity_Harm), // an entity of w was hurt and lives (its health already less: entity_harm)
	entity_died:    proc(s: ^Server, w: ^World, dead: Dead_Entity, harm: Entity_Harm), // an entity of w died of harm (gone already: dead says what and where it was)
	action:         proc(s: ^Server, c: ^Client, index: int), // c pressed the game's action `index` (0 ..< game.MAX_GAME_ACTIONS; the client part's Game.actions names them); not while dead
	request:        proc(s: ^Server, c: ^Client, r: Request), // c's client part sent one of the game's requests (Game_Kinds.requests), decoded and checked (request_value)
	picking:        proc(s: ^Server, c: ^Client, stack: game.Stack) -> Pickup, // c walks over a dropped stack it may pick up: take it, leave it, or the game took it its own way
	harming:        proc(s: ^Server, h: ^Harming), // any harm about to be done, to a player or an entity: may change h.amount (0 or less: none)
	save:           proc(s: ^Server, out: ^strings.Builder), // what it keeps with the universe, as text (game.cfg), at each save's tick
	load:           proc(s: ^Server, text: string) -> (ok: bool), // its game.cfg, after start, before the first tick (a universe that has one); false: start fails
	world_opened:   proc(s: ^Server, w: ^World), // w is open (started, its entities loaded; the home world after start and load): the game makes what it keeps of it (world_state, its files read)
	world_closed:   proc(s: ^Server, w: ^World), // w closes (unloaded, or the session stops), after its last save: the game frees what it made of it
	world_save:     proc(s: ^Server, w: ^World), // a save captures w at this tick (with the universe, or w alone as it unloads): the game stages its files (world_file_write)
	machine_data:   typeid, // its record on each machine of its pack's blocks (machine_data): zero when built, saved with the chunk; nil: none
	machine_shown:  typeid, // what players are shown of each machine (machine_show; engine.machine_shown): at most game.MAX_MACHINE_SHOWN bytes; nil: nothing
	machines:       proc(s: ^Server, w: ^World, kind: game.Block_Type, at: []game.Block_Pos), // the machines of w whose time has come (machine_wake), a call per block type, lowest position first
	machine_use:    proc(s: ^Server, c: ^Client, at: game.Block_Pos) -> (refusal: string), // c uses (right-clicks) the machine at `at` within its reach: the game opens its panel, or refuses (c is told why)
	pack:           game.Pack_Source, // its own pack (games/<game>/pack, named for the game; its shared package's): loaded only where it is played (game_packs)
}

// game_state: the game's state for the session, as the type it declared
// (Game.server_state). Its memory is the session's, freed by stop.
game_state :: proc(s: ^Server, $T: typeid) -> ^T {
	assert(s.config.game.server_state == T, "not the game's server_state")
	return (^T)(raw_data(s.game_state))
}

// game_client_state: the game's state for c's seat, as the type it declared
// (Game.client_state). Zero when a player takes the seat; its memory is the
// session's.
game_client_state :: proc(s: ^Server, c: ^Client, $T: typeid) -> ^T {
	assert(s.config.game.client_state == T, "not the game's client_state")
	return (^T)(raw_data(c.game_state))
}

// game_state_make: zeroed memory for a value of type state (none for nil).
@(private = "file")
game_state_make :: proc(state: typeid, allocator: mem.Allocator) -> ([]byte, mem.Allocator_Error) {
	if state == nil {return nil, nil}
	info := type_info_of(state)
	return mem.alloc_bytes(info.size, info.align, allocator)
}

DEFAULT_MAX_PLAYERS :: 8

// UNLOAD_SWEEP_TICKS: how often every loaded chunk is looked at for whether
// anyone wants it (a client's moves free what it left as it goes).
UNLOAD_SWEEP_TICKS :: game.TICK_RATE * 10

Phase_Timing :: struct {
	name: string,
	ms:   f32,
}

// Stats is a snapshot, published at the end of every tick.
Stats :: struct {
	tick:              u64,
	tick_ms:           f32,
	tick_cpu_ms:       f32, // the server thread's CPU time in the tick: what a budget test judges
	tick_ms_avg:       f32, // rolling 100-tick average MSPT
	tick_ms_max:       f32, // rolling 100-tick peak MSPT
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
	desyncs:           int, // prediction checks that differed
	checks_judged:     int, // prediction checks compared
	checks_skipped:    int, // ... and skipped (not quiet)
	slowest_phases:    [4]Phase_Timing,
	slowest_phase_n:   int,
}

Thread :: thread.Thread

// Server: a session of the universe: its config, worlds, clients and tick, what every hook
// of a game is given.
Server :: struct {
	// The phases of the tick being run (slow-tick diagnosis: server_main logs
	// them when a tick takes SLOW_TICK or longer).
	tick_marks:        [16]Tick_Mark,
	tick_mark_n:       int,
	tick_start:        time.Tick,
	slow_logged:       time.Tick, // when a slow tick was last logged
	config:            Config,
	capacity:          int, // chunks
	local:             protocol.Endpoint, // the in-process player's pipe (none: a dedicated server)
	thread:            ^Thread,
	stopping:          bool, // (atomic)
	schema:            protocol.Schema, // what is replicated to clients (state_kinds.odin)
	time_stopped:      bool, // the clock stands still (the local player paused): clients are given a new anchor every tick
	frozen:            bool, // (atomic) the local player paused: time and entities stand still
	sim_speed:         int, // the world's steps a tick, as the game set it (sim_speed_set; 0: paused; 1 at start)
	sim_steps:         int, // this tick's: sim_speed, or 0 while frozen (a game steps its own simulation as many times)
	failed:            bool, // (atomic)
	stats_mutex:       sync.Mutex,
	stats:             Stats,
	log_tag:           base.Log_Tag,
	store:             Store, // saving (save.odin)
	pack_blobs:        [dynamic]Pack_Blob, // the universe's packs as sent (pack_send.odin)
	reload:            Pack_Reload, // hot reload of the packs (pack_reload.odin)
	registry:          ^game.Registry, // what blocks, items and recipes there are (universe_packs.odin); read only once started
	refusal:           string, // why start returned false, when it is a message for the player
	tick_deadline:     time.Tick, // absolute wall-clock deadline of current tick
	overload_warn:     time.Tick, // when an overload warning was last logged
	watchdog_thread:   ^Thread, // monitors tick responsiveness
	watchdog_stopping: bool, // (atomic)
	tick_times:        [100]f32, // rolling 100-sample MSPT ring buffer
	tick_times_head:   int,
	tick_times_count:  int,
	tick_times_sum:    f32,
	// Server thread only, after start:
	arena:             virtual.Arena,
	home:              ^World, // the universe's first world (always loaded)
	worlds:            [dynamic]^World, // loaded (home first)
	clients:           []Client, // index = player id
	host:              netcode.Host, // remote players (listening when host_open)
	listening:         bool,
	capture:           netcode.Capture, // (config.capture)
	perms:             Permissions, // who may do what (permissions.odin)
	admins:            access.Admins, // admins.cfg: accounts and SteamIDs that have the role admin (permissions.odin)
	community:         Community, // nicknames, mutes, homes, warps, bans (community.odin)
	chat:              Chat_State, // (chat.odin)
	kit:               [dynamic]game.Stack, // what new players are given (player_data.odin; world.cfg)
	offsets:           []game.Chunk_Pos, // the interest area around a client, nearest first
	unload_offsets:    []game.Chunk_Pos, // ... with SERVER_UNLOAD_MARGIN (unload_left)
	calls:             base.Queue(Server_Call), // from beside an in-process server (call.odin)
	writer:            game.Writer,
	tick:              u64,
	sink:              telemetry.Sink, // events (stats.odin; telemetry/)
	session:           telemetry.Sink, // the session recording's file (session_log.odin)
	session_on:        bool,
	log_sink:          ^base.Log_Sink, // whose warnings and errors it keeps
	uploader:          collector.Uploader, // sends its log to a collector
	uploading:         bool,
	ledger:            Ledger, // every item made or unmade (ledger.odin)
	desyncs:           int, // checks that differed (desync.odin)
	desync_fields:     [protocol.Player_Field]int, // ... and in which fields
	checks_judged:     int, // checks compared
	checks_skipped:    int, // checks not compared: the player was not quiet
	hash_root:         u64, // a stepped server's chain of tick hashes (state_hash.odin)
	age_base:          u64, // the universe's ticks before this run (universe.cfg; age_of)
	tick_us:           [TICK_SUMMARY_TICKS]u32, // the last minute's tick times, microseconds
	game_state:        []byte, // the game's state for the session (game_state)
}

// A rejected remote client is told why and dropped this many ticks later.
@(private)
KICK_DELAY :: game.TICK_RATE

// start sets up the session and starts the server thread. s must stay at
// its address until stop. local: the in-process player's end of a pipe
// ({} for none).
start :: proc(s: ^Server, config: Config, local: protocol.Endpoint) -> bool {
	config := config
	if !game.game_id_valid(config.game.id) {
		log.errorf("server needs a game to play (Config.game; its id: %q)", config.game.id)
		return false
	}
	if config.game.entity_data != nil {
		if why := game.entity_data_plain(config.game.entity_data); why != "" {
			log.errorf("server game's entity_data cannot be kept game=%s: %s", config.game.id, why)
			return false
		}
	}
	for check in ([2]struct {
			type: typeid,
			why:  proc(T: typeid) -> string,
		}{{config.game.machine_data, game.machine_data_plain}, {config.game.machine_shown, game.machine_shown_plain}}) {
		if check.type == nil {continue}
		if why := check.why(check.type); why != "" {
			log.errorf(
				"server game's machine records cannot be kept game=%s: %s",
				config.game.id,
				why,
			)
			return false
		}
	}
	if why := game_stats_valid(config.game.stats); why != "" {
		log.errorf("server game's statistics cannot be kept game=%s: %s", config.game.id, why)
		return false
	}
	if config.game.character_data != nil {
		if why := game.character_data_plain(config.game.character_data); why != "" {
			log.errorf(
				"server game's character_data cannot be kept game=%s: %s",
				config.game.id,
				why,
			)
			return false
		}
	}
	if why := world_files_valid(config.game.world_files); why != "" {
		log.errorf("server game's world files cannot be kept game=%s: %s", config.game.id, why)
		return false
	}
	if config.game.configure != nil {config.game.configure(&config)}
	if config.net != nil && (!config.stepped || config.conditions != {}) {
		log.warnf("a simulated network needs a stepped server and no conditions of its own")
		return false
	}
	assert(config.view_radius > 0 && config.view_radius <= protocol.MAX_VIEW_RADIUS)
	assert(
		config.view_height > 0 &&
		config.view_height <= game.MAX_VIEW_HEIGHT &&
		(config.workers > 0 || config.stepped),
	)
	// Field by field: a literal of the whole Server is built on the stack first (88 KB) and copied.
	s^ = {}
	s.config, s.local = config, local
	s.sim_speed = 1
	s.schema = protocol.game_schema(config.game.id, config.game.kinds)
	assert(config.perturb.what == .None || config.stepped, "perturb is for stepped servers")
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
	// (a game's list is a constant's, made where its Game was copied: the session keeps
	// its own, so a Game given from a call that has returned is still whole)
	s.config.game.stats = slice.clone(config.game.stats, arena)
	s.home = world_make(s)
	append(&s.worlds, s.home)
	// A saved world's seed and rules replace the config's.
	if !store_open(s, config.save_dir) {
		teardown(s, world = false)
		return false
	}
	if !universe_registry(s) || !universe_blocks_check(s) {
		teardown(s, world = false)
		return false
	}
	clear(&s.kit) // by default nothing: a kit is the universe's or the game's
	if kit_text := s.store.kit_text if s.store.kit_text != "" else s.config.kit; kit_text != "" {
		if kit, ok := kit_parse(s.registry, kit_text); ok {
			clear(&s.kit)
			append(&s.kit, ..kit)
		} else {
			log.warnf("server universe kit not understood kit=%q", kit_text)
		}
	}
	permissions_open(s)
	community_open(s)
	admins_open(s)
	telemetry.sink_start(
		&s.sink,
		filepath.join({s.store.dir, "telemetry"}, context.temp_allocator) or_else "" if s.store.dir != "" else "",
		u32(telemetry.now_ms()),
		stepped = config.stepped,
	)
	session_open(s)
	if up, ok := config.upload.?; ok && s.store.dir != "" {
		interval := up.interval if up.interval > 0 else 30 * time.Second
		collector.uploader_start(
			&s.uploader,
			filepath.join({s.store.dir, "telemetry"}, context.temp_allocator) or_else "",
			up.address,
			up.key,
			interval,
		)
		s.uploading = true
	}
	characters_open(s)
	base.queue_init(&s.calls)
	s.offsets = game.interest_offsets(config.view_radius, config.view_height, arena)
	s.unload_offsets = game.interest_offsets(
		config.view_radius + game.SERVER_UNLOAD_MARGIN,
		config.view_height + game.SERVER_UNLOAD_MARGIN,
		arena,
	)
	// Loaded chunks stay within the unload distance of some player, plus
	// chunks still generating that were requested before they moved.
	per_player := game.interest_count(
		config.view_radius + game.SERVER_UNLOAD_MARGIN,
		config.view_height + game.SERVER_UNLOAD_MARGIN,
	)
	capacity :=
		per_player * s.config.max_players + max(config.workers, 1) * MAX_IN_FLIGHT_PER_WORKER
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
	{
		err: mem.Allocator_Error
		s.game_state, err = game_state_make(config.game.server_state, arena)
		for &c in s.clients {
			if err != nil {break}
			c.game_state, err = game_state_make(config.game.client_state, arena)
		}
		if err != nil {
			log.errorf("server cannot allocate the game's state game=%s: %v", config.game.id, err)
			teardown(s, world = true)
			return false
		}
	}
	game.writer_init(&s.writer, arena, protocol.MAX_MESSAGE_SIZE) // never grows: the arena stays flat
	if local.pipe != nil {
		s.clients[0].state = .Connecting
		s.clients[0].link = Local{}
	}
	if config.listen && !listen(s, config.port, config.port) {
		teardown(s, world = true)
		return false
	}
	if config.game.start != nil && !config.game.start(s) {
		log.errorf("server game did not start game=%s", config.game.id)
		teardown(s, world = true)
		return false
	}
	if !game_load(s) {
		if config.game.stop != nil {config.game.stop(s)} 	// (its start succeeded)
		teardown(s, world = true)
		return false
	}
	world_open_game(s.home)

	if !config.stepped {
		s.thread = thread.create(server_main, name = "server")
		s.thread.data = s
		s.thread.init_context = base.thread_context()
		thread.start(s.thread)
		if config.watchdog_seconds > 0 {
			s.watchdog_thread = thread.create(server_watchdog_proc, name = "watchdog")
			s.watchdog_thread.data = s
			s.watchdog_thread.init_context = base.thread_context()
			thread.start(s.watchdog_thread)
		}
	}
	log.infof(
		"server started seed=%d generator=%s view=%dx%d workers=%d capacity=%d seats=%d game=%s",
		s.config.seed,
		worldgen.KIND_NAMES[s.config.generator],
		config.view_radius,
		config.view_height,
		config.workers,
		capacity,
		s.config.max_players,
		config.game.id,
	)
	return true
}

// stop finishes the current tick, stops the thread, saves, says goodbye to
// remote players and frees the session. False if the server stopped
// because of an error (or the last save failed).
stop :: proc(s: ^Server) -> bool {
	sync.atomic_store(&s.watchdog_stopping, true)
	if s.watchdog_thread != nil {
		thread.join(s.watchdog_thread)
		thread.destroy(s.watchdog_thread)
		s.watchdog_thread = nil
	}
	sync.atomic_store(&s.stopping, true)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	if s.config.game.stop != nil {s.config.game.stop(s)}
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
	session_close(s)
	telemetry.sink_stop(&s.sink) // (the events written; safe if it never started)
	if s.uploading {collector.uploader_stop(&s.uploader)} 	// (a last pass: what was written)
	netcode.capture_close(&s.capture)
	store_close(s)
	permissions_destroy(&s.perms)
	community_destroy(&s.community)
	access.admins_destroy(&s.admins)
	for w in s.worlds {world_close(w)} 	// (first: it joins the generator workers, which read the registry)
	delete(s.worlds)
	game.registry_destroy(s.registry)
	pack_blobs_destroy(s)
	reload_destroy(s)
	delete(s.kit)
	for &c in s.clients {client_reset(&c)}
	protocol.schema_destroy(&s.schema)
	ledger_destroy(&s.ledger)
	base.queue_destroy(&s.calls)
	refusal := s.refusal // (a failed start says why, after the rest is gone)
	virtual.arena_destroy(&s.arena)
	s^ = {}
	s.refusal = refusal
}

// MAX_SIM_SPEED: the most steps a tick a game may run its world at.
MAX_SIM_SPEED :: 4

// sim_speed_set: the world's life (its time, its block updates and random ticks, its
// entities) steps speed times a tick from the next one: 0 pauses it, 2 and 4 run it
// fast; false (and nothing changes) past MAX_SIM_SPEED. A game asks for it (a city
// builder's speed buttons) and steps its own simulation s.sim_steps times in its tick,
// which still comes once a tick, so its records stay. Players are not sped: each moves
// by its own inputs, one a tick, so prediction holds; the server stays deterministic
// (the same steps in the same order, whatever the speed).
sim_speed_set :: proc(s: ^Server, speed: int) -> bool {
	if speed < 0 || speed > MAX_SIM_SPEED {return false}
	s.sim_speed = speed
	return true
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

// server_now: the time netcode is given: the simulated network's clock when
// the server runs on one, else the OS's. (The live tick's pacing keeps the
// wall clock: it is not state.)
@(private)
server_now :: proc(s: ^Server) -> time.Tick {
	if s.config.net != nil {return s.config.net.now}
	return time.tick_now()
}

// listen opens the UDP port for remote players: the first free one from
// first to last. False (logged) if none could be opened.
@(private)
listen :: proc(s: ^Server, first, last: int) -> bool {
	if s.listening {return true}
	err: net.Network_Error
	for port in first ..= last {
		err = netcode.host_open(
			&s.host,
			port,
			s.config.max_players,
			s.config.password,
			sim = s.config.net,
		)
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

Tick_Mark :: struct {
	name: string,
	at:   time.Tick,
}

SLOW_TICK :: 250 * time.Millisecond // a tick this long is logged with its phases

// tick_mark ends a phase of the tick (named for what ran since the last mark).
tick_mark :: proc(s: ^Server, name: string) {
	if s.tick_mark_n < len(s.tick_marks) {
		s.tick_marks[s.tick_mark_n] = {name, time.tick_now()}
		s.tick_mark_n += 1
	}
}

// slow_tick_log: a tick that took SLOW_TICK or longer, with how long each
// phase took (at most one line every 5 s).
@(private = "file")
slow_tick_log :: proc(s: ^Server, start: time.Tick, took: time.Duration) {
	if took < SLOW_TICK {return}
	if s.slow_logged != {} && time.tick_since(s.slow_logged) < 5 * time.Second {return}
	s.slow_logged = time.tick_now()
	b := strings.builder_make(context.temp_allocator)
	from := start
	for m in s.tick_marks[:s.tick_mark_n] {
		fmt.sbprintf(
			&b,
			" %s=%.0fms",
			m.name,
			time.duration_milliseconds(time.tick_diff(from, m.at)),
		)
		from = m.at
	}
	if took_ms := time.duration_milliseconds(time.tick_diff(from, time.tick_add(start, took)));
	   took_ms > 0.5 {
		fmt.sbprintf(&b, " tail=%.0fms", took_ms)
	}
	log.warnf(
		"server slow tick tick=%d ms=%.0f%s",
		s.tick,
		time.duration_milliseconds(took),
		strings.to_string(b),
	)
}

// have_time reports whether the server has remaining wall-clock budget in the
// current tick, with an optional safety margin.
have_time :: proc(s: ^Server, margin: time.Duration = 0, now: time.Tick = {}) -> bool {
	if s == nil || s.config.stepped {return true}
	current := now if now._nsec != 0 else time.tick_now()
	return time.tick_diff(current, s.tick_deadline) > margin
}

@(private = "file")
server_watchdog_proc :: proc(t: ^thread.Thread) {
	base.thread_register("watchdog")
	defer base.thread_unregister()
	s := (^Server)(t.data)
	max_dur := time.Duration(s.config.watchdog_seconds) * time.Second
	for !sync.atomic_load(&s.watchdog_stopping) {
		time.sleep(500 * time.Millisecond)
		if sync.atomic_load(&s.watchdog_stopping) {break}
		start := s.tick_start
		if start._nsec != 0 {
			elapsed := time.tick_since(start)
			if elapsed > max_dur {
				secs := time.duration_seconds(elapsed)
				log.errorf(
					"server watchdog: a single server tick has taken %.1f s (limit %d s); server appears deadlocked",
					secs,
					s.config.watchdog_seconds,
				)
				path := base.crash_bundle_write("watchdog: single tick deadlock")
				if path != "" {
					log.errorf("server watchdog: crash bundle written to %s", path)
				}
				time.sleep(5 * time.Second)
				os.exit(1)
			}
		}
	}
}

@(private = "file")
server_main :: proc(t: ^thread.Thread) {
	base.thread_register("server")
	defer base.thread_unregister()
	s := (^Server)(t.data)
	context.logger = base.log_retag(&s.log_tag, context.logger, "server")
	base.profile_thread_start("server")
	next := time.tick_now()
	for !sync.atomic_load(&s.stopping) {
		start := time.tick_now()
		s.tick_start = start
		s.tick_deadline = time.tick_add(start, game.TICK_DURATION)
		cpu := base.thread_cpu_us()
		s.tick_mark_n = 0
		tick(s)
		took := time.tick_since(start)
		slow_tick_log(s, start, took)
		free_all(context.temp_allocator)
		s.tick_us[s.tick % TICK_SUMMARY_TICKS] = u32(time.duration_microseconds(took))
		publish_stats(
			s,
			f32(time.duration_milliseconds(took)),
			f32(base.thread_cpu_us() - cpu) / 1000,
		)
		s.tick_start = {}

		next = time.tick_add(next, game.TICK_DURATION)
		left := time.tick_diff(time.tick_now(), next)
		if left < -5 * game.TICK_DURATION {
			now := time.tick_now()
			behind_ms := -time.duration_milliseconds(left)
			skipped := int(-left / game.TICK_DURATION)
			if time.duration_seconds(time.tick_since(s.overload_warn)) >= 10 {
				s.overload_warn = now
				log.warnf(
					"can't keep up! server is %.0f ms (%d ticks) behind, skipping ticks",
					behind_ms,
					skipped,
				)
			}
			next = now
		} else if left > 0 {
			time.sleep(left)
		}
	}
	base.profile_thread_stop()
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
}

SINK_DRAIN_TICKS :: game.TICK_RATE // a stepped server writes its events once a second

@(private)
tick :: proc(s: ^Server) {
	base.profile_scope_number("server tick", s.tick + 1)
	base.metric_scope(.Server_Tick)
	s.tick += 1
	if s.config.steam != nil {steam_server.run_callbacks(s.config.steam)}
	{
		base.profile_scope("scheduled calls")
		calls_run(s)
	}
	if s.tick % TICK_SUMMARY_TICKS == 0 {tick_summary(s)}
	{
		base.profile_scope("saving")
		save_poll(s)
		save_slice(s)
		if s.config.stepped && s.tick % SINK_DRAIN_TICKS == 0 { 	// (no writer thread: its timing is not the test's)
			telemetry.sink_drain(&s.sink)
			if s.session_on {telemetry.sink_drain(&s.session)}
		}
		if s.tick - s.store.last_save >= AUTOSAVE_SECONDS * game.TICK_RATE {save(s, wait = false)}
	}
	tick_mark(s, "saving")
	for w in s.worlds {
		keep_request(w)
		chunks_collect(
			&w.chunks,
			proc(pos: game.Chunk_Pos, data: rawptr) -> bool {
				w := (^World)(data)
				if !anyone_wants(w, pos, game.SERVER_UNLOAD_MARGIN) {return false}
				// Water next door that stopped at this chunk's edge flows on.
				origin := game.chunk_origin(pos)
				sim_wake_box(w, origin, origin + game.CHUNK_SIZE - 1, 0, only_border = true)
				return true
			},
			w,
		)
		naturals_take(w)
	}
	{
		base.profile_scope("receive messages")
		receive_messages(s)
	}
	tick_mark(s, "chunks_and_messages")
	frozen := sync.atomic_load(&s.frozen) && !s.listening
	s.time_stopped = frozen
	s.sim_steps = 0 if frozen else s.sim_speed
	for _ in 0 ..< s.sim_steps {
		for w in s.worlds {w.clock = game.advance_time(w.clock, f64(game.TICK_SECONDS), &w.rules)}
	}
	tick_mark(s, "clock")
	Move :: struct {
		world:    ^World,
		from, to: game.Chunk_Pos,
	}
	moves := make([dynamic]Move, context.temp_allocator)
	for &c in s.clients {
		if c.state != .Playing {continue}
		base.profile_scope("player")
		simulate_player(s, &c)
		player_entity_sync(s, &c)
		health_tick(s, &c)
		weapons_tick(s, &c)
		place_tick(s, &c)
		stats_tick(s, &c)
		if c.moved {
			base.profile_scope("drop far")
			c.moved = false
			append(&moves, Move{c.world, c.moved_from, c.center})
			drop_far(s, &c)
		}
	}
	tick_mark(s, "players")
	player_entities_release(s)
	for w in s.worlds {islands_update(s, w)}
	tick_mark(s, "islands")
	{
		base.profile_scope("unload idle worlds and audit")
		worlds_unload_idle(s)
		audit_tick(s)
	}
	for m in moves {
		base.profile_scope("unload left")
		unload_left(m.world, m.from, m.to)
	}
	for w in s.worlds {
		if s.tick % UNLOAD_SWEEP_TICKS == 0 {
			base.profile_scope("unload unwanted")
			unload_unwanted(w)
		}
	}
	tick_mark(s, "unloads")
	// The world's own life steps sim_steps times (sim_speed: none paused, more fast).
	for _ in 0 ..< s.sim_steps {
		for w in s.worlds {sim_run_scheduled(w)}
	}
	tick_mark(s, "block_updates")
	for _ in 0 ..< s.sim_steps {
		for w in s.worlds {
			base.profile_scope("random ticks")
			random_ticks(w)
		}
	}
	tick_mark(s, "random_ticks")
	for _ in 0 ..< s.sim_steps {
		for w in s.worlds {
			entities_tick(w)
			{
				base.profile_scope("containers")
				containers_tick(w)
			}
		}
	}
	tick_mark(s, "entities")
	if s.sim_steps > 0 {
		base.profile_scope("belts and machines")
		for w in s.worlds {
			belts_tick(w)
			machines_tick(w)
		}
		tick_mark(s, "machines")
	}
	for w in s.worlds {block_changes_tell(w)}
	if s.config.game.tick != nil {
		base.profile_scope("game")
		s.config.game.tick(s)
		tick_mark(s, "game")
	}
	for w in s.worlds {
		rewind: {
			base.profile_scope("rewind, gates and rollback")
			rewind_record(s, w)
			gates_tick(w)
			rollback_tick(w)
		}
	}
	tick_mark(s, "rewind_and_gates")
	for w in s.worlds {
		{
			base.profile_scope("changes flush")
			changes_flush(w)
		}
		{
			base.profile_scope("journal")
			journal_tick(w)
		}
	}
	tick_mark(s, "changes_and_journal")
	sent := 0
	for &c in s.clients {
		if c.state != .Playing {continue}
		{
			base.profile_scope("replicate")
			replicate_tick(s, &c)
		}
		base.profile_scope("stream")
		base.metric_scope(.Server_Stream)
		sent += stream(s, &c)
		base.profile_scope("replica flush")
		replica_flush(s, &c)
	}
	base.metric_add(.Server_Sent_KiB, f32(sent) / 1024)
	{
		base.profile_scope("kicks and packs")
		kick_due(s)
		packs_tick(s)
		packs_reload_tick(s)
	}
	if s.listening {
		if s.tick % game.TICK_RATE == 0 {update_info(s)}
		base.profile_scope("network flush")
		netcode.host_flush(&s.host, server_now(s))
	}
	tick_mark(s, "network_and_packs")
}

// receive_messages handles what every player sent since the last tick: the
// local player's pipe, then the network.
@(private = "file")
receive_messages :: proc(s: ^Server) {
	if s.local.pipe != nil {
		packets := make([dynamic]protocol.Packet, context.temp_allocator)
		protocol.receive(s.local, &packets)
		defer for p in packets {protocol.packet_free(s.local, p)}
		for p in packets {handle(s, &s.clients[0], p)}
	}
	if !s.listening {return}
	netcode.host_update(&s.host, server_now(s))
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
				netcode.host_kick(&s.host, v.peer, "the server is full", server_now(s))
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

// proved: the account is proved (and has its packs): its character, or the
// list to choose from.
@(private = "file")
proved :: proc(s: ^Server, c: ^Client) {
	if c.wanted_len == 0 {
		c.state = .Choosing
		names := characters_of(s, c.account)
		send_message(s, c, protocol.Characters{strings.join(names, " ", context.temp_allocator)})
		return
	}
	enter(s, c, string(c.wanted[:c.wanted_len]))
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
	m, ok := protocol.decode_client(p, s.registry)
	if !ok {
		disconnect(s, c, "invalid message")
		return
	}
	// Before playing only the handshake (or a ping) makes sense.
	if c.state != .Playing {
		handshake: bool
		#partial switch _ in m {
		case protocol.Hello,
		     protocol.Proof,
		     protocol.Choose,
		     protocol.Ping,
		     protocol.Pack_Want,
		     protocol.Packs_Ready:
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
	case protocol.Teleport:
		node = "teleport.tp"
	case protocol.Set_Rule:
		node = "world.gen" if strings.has_prefix(v.name, "worldgen.") else NODE_RULE
	case protocol.Fire:
		node = "world.fire"
	case protocol.Edit:
		node = "world.edit"
	case protocol.Chat:
		node = "chat.send"
	}
	if node != "" && !allowed(s, c, node) {
		if e, edit := m.(protocol.Edit); edit {send_message(s, c, edit_refused(w, e))}
		notice(s, c, fmt.tprintf("You may not do that here (%s)", node))
		return
	}
	switch v in m {
	case protocol.Hello:
		if c.state != .Connecting {
			disconnect(s, c, "unexpected hello")
			return
		}
		if v.protocol != protocol.PROTOCOL_VERSION {
			disconnect(s, c, "protocol version mismatch")
			return
		}
		if v.schema != s.schema.engine_hash {
			disconnect(
				s,
				c,
				fmt.tprintf(
					"this server runs a different version of the game (state schema %016x vs %016x)",
					s.schema.engine_hash,
					v.schema,
				),
			)
			return
		}
		if v.character != "" && !game.name_valid(v.character) {
			disconnect(s, c, "names are 1 to 16 letters, digits, _ or -")
			return
		}
		c.steam_id = 0
		if why := steam_hello(s, v); why != "" {
			log.infof(
				"server steam join refused account=%s why=%q",
				access.account_text(v.account),
				why,
			)
			disconnect(s, c, why)
			return
		}
		if steam_on(s) && len(v.ticket) > 0 {c.steam_id = v.steam_id}
		c.account = v.account
		c.wanted_len = copy(c.wanted[:], v.character)
		c.nonce = access.nonce_make()
		c.state = .Proving
		send_message(s, c, protocol.Challenge{c.nonce})
	case protocol.Proof:
		if c.state != .Proving {
			disconnect(s, c, "unexpected proof")
			return
		}
		if !access.account_verify(c.account, c.nonce, v.signature) {
			log.warnf("server account proof failed account=%s", access.account_text(c.account))
			disconnect(s, c, "the account's proof is wrong")
			return
		}
		c.nonce = {} // (used: a proof is for one nonce)
		if why := steam_link(s, c); why != "" {
			disconnect(s, c, why)
			return
		}
		if packs_begin(s, c) {return}
		proved(s, c)
	case protocol.Pack_Want:
		pack_want(s, c, v)
	case protocol.Packs_Ready:
		if pack_ready(s, c, v) {proved(s, c)}
	case protocol.Choose:
		if c.state != .Choosing || !game.name_valid(v.character) {
			disconnect(s, c, "unexpected choice")
			return
		}
		enter(s, c, v.character)
	case protocol.Input:
		if v.snapshot <= u32(s.tick) {protocol.sender_ack(&c.tx, v.snapshot)} 	// (a client cannot hold a snapshot not sent yet)
		if !protocol.input_queue_push(&c.inputs, v) {disturb(s, c)} 	// (refused: it was predicted, not applied)
	case protocol.Prediction_Check:
		c.check = v
	case protocol.Teleport:
		land(s, c, v.position, {v.yaw, v.pitch}, .Exact)
	case protocol.Set_Rule:
		if strings.has_prefix(v.name, "worldgen.") {
			set_worldgen(s, c, v.name, v.value)
			return
		}
		rule_set(s, c, w, v.name, v.value)
	case protocol.Ping:
		send_message(s, c, protocol.Pong{v.id})
	case protocol.Command:
		admin(s, c, v.command)
	case protocol.Chat:
		chat_say(s, c, v.text)
	case protocol.Inventory_Request:
		inventory_request(s, c, v)
	case protocol.Dial:
		notice_if(s, c, gate_dial(s, c, v))
	case protocol.Edit:
		queue_action(s, c, v)
	case protocol.Attack:
		queue_action(s, c, v)
	case protocol.Use_Entity:
		queue_action(s, c, v)
	case protocol.Use_Block:
		queue_action(s, c, v)
	case protocol.Fire:
		queue_action(s, c, v)
	case protocol.Shoot:
		queue_action(s, c, v)
	case protocol.Reload:
		weapon_reload(s, c)
	case protocol.Game_Action:
		if g := &s.config.game; g.action != nil && !c.dead {g.action(s, c, int(v.index))}
	case protocol.Game_Request:
		request_receive(s, c, v)
	case protocol.Telemetry_Batch, protocol.Dev_Message, protocol.Dev_Fetch:
		disconnect(s, c, "this is not a telemetry collector")
	case protocol.Respawn:
		respawn_ask(s, c) // (refused while alive or before the delay: nothing happens)
	case protocol.Stats_Request:
		stats_request(s, c, v)
	case protocol.Telemetry_Report:
		telemetry_report(s, c, v)
	}
}

// send_message encodes m for a client: down the pipe, or over the network
// (reliably unless the kind is a state that the next one replaces).
@(private)
send_message :: proc(
	s: ^Server,
	c: ^Client,
	m: protocol.Server_Message,
	blocks: ^game.Chunk_Blocks = nil,
	reliable := false,
) -> (
	bytes: int,
) {
	if c.link == nil {return}
	clear(&s.writer.buf)
	protocol.encode_server(&s.writer, m, blocks)
	data := s.writer.buf[:]
	switch l in c.link {
	case Local:
		protocol.send(s.local, data)
	case netcode.Peer_Id:
		netcode.host_send(
			&s.host,
			l,
			data,
			reliable || protocol.message_reliable(.Server, data[0]),
		)
	}
	return len(data)
}

// broadcast sends m to every player (in world, if given: its news).
@(private)
broadcast :: proc(s: ^Server, m: protocol.Server_Message, world: ^World = nil) {
	for &c in s.clients {
		if c.state == .Playing && (world == nil || c.world == world) {send_message(s, &c, m)}
	}
}

// notice tells one player something (cut to game.MAX_NOTICE_TEXT, at a whole letter).
// Public: a game (Game) speaks to its players with it.
notice :: proc(s: ^Server, c: ^Client, text: string) {
	log.info("server notice ", text)
	text := text
	if len(text) > protocol.MAX_NOTICE_TEXT {
		cut := protocol.MAX_NOTICE_TEXT
		for cut > 0 && text[cut] & 0xc0 == 0x80 {cut -= 1} 	// (a whole letter)
		text = text[:cut]
	}
	shown := protocol.Notice{text}
	event_send(s, c, .Notice, &shown)
}

// player_id: c's id, its seat: what its players' records are keyed by
// (game.key_player). Public: a game keys its own records with it.
player_id :: proc(s: ^Server, c: ^Client) -> u16 {
	return u16(mem.ptr_sub(c, &s.clients[0]))
}

// Player_Ref: a player held past the moment (a rocket's shooter): its seat and the
// seat's generation, which counts up each time a player takes the seat. Seats are
// reused, generations are not, so a ref to one who left names nobody, never whoever
// sits there now (ground rule 2: a generational handle).
Player_Ref :: struct {
	seat:       u16,
	generation: u32,
}

// player_ref: c as a Player_Ref.
player_ref :: proc(s: ^Server, c: ^Client) -> Player_Ref {
	return {player_id(s, c), c.generation}
}

// player_of: the playing player ref names; nil when it left (its seat empty or
// another's) or is not playing.
player_of :: proc(s: ^Server, ref: Player_Ref) -> ^Client {
	if int(ref.seat) >= len(s.clients) {return nil}
	c := &s.clients[ref.seat]
	if c.generation != ref.generation || c.state != .Playing {return nil}
	return c
}

// update_info refreshes what LAN discovery answers.
@(private = "file")
update_info :: proc(s: ^Server) {
	players := 0
	for c in s.clients {if c.state == .Playing {players += 1}}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	name := s.config.name if s.config.name != "" else "Voxiverse server"
	protocol.encode_server_info(
		&w,
		{
			protocol = protocol.PROTOCOL_VERSION,
			name = name[:min(len(name), protocol.MAX_SERVER_NAME)],
			players = players,
			max_players = s.config.max_players,
			password = s.config.password != "",
		},
	)
	netcode.host_set_info(&s.host, w.buf[:])
}

@(private)
tick_times_record :: proc(s: ^Server, tick_ms: f32) -> (avg_ms, max_ms: f32) {
	if s.tick_times_count < len(s.tick_times) {
		s.tick_times[s.tick_times_head] = tick_ms
		s.tick_times_sum += tick_ms
		s.tick_times_count += 1
		s.tick_times_head = (s.tick_times_head + 1) % len(s.tick_times)
	} else {
		old := s.tick_times[s.tick_times_head]
		s.tick_times[s.tick_times_head] = tick_ms
		s.tick_times_sum = s.tick_times_sum - old + tick_ms
		s.tick_times_head = (s.tick_times_head + 1) % len(s.tick_times)
	}
	avg_ms = s.tick_times_sum / f32(max(1, s.tick_times_count))
	for t in s.tick_times[:s.tick_times_count] {
		max_ms = max(max_ms, t)
	}
	return
}

@(private)
publish_stats :: proc(s: ^Server, tick_ms, tick_cpu_ms: f32) {
	playing := 0
	for c in s.clients {if c.state == .Playing {playing += 1}}
	avg_ms: f32 = 0
	max_ms: f32 = 0
	if !s.config.stepped {
		avg_ms, max_ms = tick_times_record(s, tick_ms)
	}
	st := Stats {
		tick           = s.tick,
		tick_ms        = tick_ms,
		tick_cpu_ms    = tick_cpu_ms,
		tick_ms_avg    = avg_ms,
		tick_ms_max    = max_ms,
		arena_used     = s.arena.total_used,
		arena_reserved = s.arena.total_reserved,
		clients        = playing,
		port           = s.host.socket.port if s.listening else 0,
		worlds         = len(s.worlds),
		desyncs        = s.desyncs,
		checks_judged  = s.checks_judged,
		checks_skipped = s.checks_skipped,
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
	phases: [16]Phase_Timing
	pn := 0
	if s.tick_start != {} {
		from := s.tick_start
		for m in s.tick_marks[:s.tick_mark_n] {
			dur := f32(time.duration_milliseconds(time.tick_diff(from, m.at)))
			from = m.at
			if dur > 0.05 && pn < len(phases) {
				phases[pn] = {m.name, dur}
				pn += 1
			}
		}
		for i in 0 ..< pn {
			for j := i + 1; j < pn; j += 1 {
				if phases[j].ms > phases[i].ms {
					phases[i], phases[j] = phases[j], phases[i]
				}
			}
		}
		for i in 0 ..< min(pn, len(st.slowest_phases)) {
			st.slowest_phases[i] = phases[i]
			st.slowest_phase_n += 1
		}
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
