package dedicated

import "core:crypto"
import "core:flags"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:time"

import "../base"
import "../netcode"
import "../server"

// voxiverse-server: a world with no window, for players to join over the
// network. Ctrl+C (or SIGTERM) stops it cleanly: the world is saved and
// every player is told the server stopped.
//
//	voxiverse-server --world worlds/home --password secret

Options :: struct {
	world:       string `usage:"the world's directory (created if new; default: world)"`,
	port:        int `usage:"UDP port (default 27315)"`,
	seed:        i64 `usage:"a new world's seed (default: random; a saved world keeps its own)"`,
	password:    string `usage:"players must give it to join"`,
	name:        string `usage:"shown in LAN server lists (default: the world's directory name)"`,
	max_players: int `usage:"seats (default 8, at most 32)"`,
	view_radius: int `usage:"view distance across, chunks (default 12)"`,
	view_height: int `usage:"view distance up and down, chunks (default 6)"`,
	cheats:      bool `usage:"let every player teleport, change rules and run server commands"`,
	seconds:     int `usage:"stop after this many seconds (0: run until stopped)"`,
	capture:     string `usage:"write every packet to this pcap file (Wireshark: tools/wireshark)"`,
}

// stop_requested is set by the Ctrl+C / SIGTERM handler (stop_*.odin).
stop_requested: bool

main :: proc() {
	dbg: base.Debug
	context = base.debug_begin(&dbg, "voxiverse-server.log", "main")
	opts := Options {
		world       = "world",
		port        = netcode.DEFAULT_PORT,
		max_players = server.DEFAULT_MAX_PLAYERS,
		view_radius = 12,
		view_height = 6,
	}
	flags.parse_or_exit(&opts, os.args, .Unix)
	ok := run(opts)
	ok = base.debug_end(&dbg) && ok
	os.exit(0 if ok else 1)
}

run :: proc(opts: Options) -> bool {
	seed := opts.seed
	if seed == 0 {crypto.rand_bytes(mem.ptr_to_bytes(&seed))}
	name := opts.name
	if name == "" {name = filepath.base(opts.world)}
	config := server.Config {
		seed            = seed,
		view_radius     = i32(clamp(opts.view_radius, 2, 32)),
		view_height     = i32(clamp(opts.view_height, 1, 16)),
		workers         = max(1, os.get_processor_core_count() / 2),
		everyone_cheats = opts.cheats,
		save_dir        = opts.world,
		max_players     = opts.max_players,
		listen          = true,
		port            = opts.port,
		password        = opts.password,
		name            = name,
		capture         = opts.capture,
	}
	srv := new(server.Server)
	defer free(srv)
	if !server.start(srv, config, {}) {return false}
	catch_stop()
	log.infof(
		"server ready world=%s port=%d name=%q (Ctrl+C stops it)",
		opts.world,
		srv.host.socket.port, // bound before the server thread started
		name,
	)
	started := time.tick_now()
	last_report := started
	for !sync.atomic_load(&stop_requested) {
		time.sleep(100 * time.Millisecond)
		if opts.seconds > 0 &&
		   time.duration_seconds(time.tick_since(started)) >= f64(opts.seconds) {
			break
		}
		if time.duration_seconds(time.tick_since(last_report)) >= 60 {
			last_report = time.tick_now()
			st := server.stats(srv)
			log.infof(
				"server status players=%d chunks=%d tick_ms=%.2f arena_mib=%.1f",
				st.clients,
				st.chunks_loaded,
				st.tick_ms,
				f64(st.arena_used) / (1 << 20),
			)
		}
	}
	log.info("server stopping")
	return server.stop(srv)
}
