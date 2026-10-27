package dedicated

import "core:crypto"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:time"

import "../base"
import "../common/game"
import "../common/netcode"
import "../server"
import "../server/collector"

// voxiverse-server: a world with no window, for players to join over the
// network. Ctrl+C (or SIGTERM) stops it cleanly: the world is saved and
// every player is told the server stopped.
//
//	voxiverse-server --world worlds/home --password secret

Options :: struct {
	universe:    string `usage:"the universe's directory (created if new; default: universe)"`,
	port:        int `usage:"UDP port (default 27315)"`,
	seed:        i64 `usage:"a new world's seed (default: random; a saved world keeps its own)"`,
	password:    string `usage:"players must give it to join"`,
	name:        string `usage:"shown in LAN server lists (default: the world's directory name)"`,
	max_players: int `usage:"seats (default 8, at most 32)"`,
	view_radius: int `usage:"view distance across, chunks (default 12)"`,
	view_height: int `usage:"view distance up and down, chunks (default 6)"`,
	cheats:      bool `usage:"give every player every permission (testing; see permissions.cfg)"`,
	seconds:     int `usage:"stop after this many seconds (0: run until stopped)"`,
	capture:     string `usage:"write every packet to this pcap file (Wireshark: tools/wireshark)"`,
	benchmark:   string `usage:"run the server benchmark scenario (server) and quit: simulated players, nothing saved"`,
	smoke:       bool `usage:"with --benchmark: one short repetition (CI: the scenario still works)"`,
	telemetry:   string `usage:"send this server's event log to the collector at host:port (anonymous: see docs/plan.md, M27)"`,
	collector:   bool `usage:"run a telemetry collector instead of a world: --universe is its directory, --port its port (default 27316)"`,
	backups:     int `usage:"rolling backups kept (default 5, 0: none)"`,
	check:       bool `usage:"check the universe's files read whole, print what does not, and quit (exit 1 on a problem)"`,
	restore:     string `usage:"put a backup (a directory of backups/, or latest) back as the universe and quit"`,
	version:     bool `usage:"print the version and quit"`,
}

// stop_requested is set by the Ctrl+C / SIGTERM handler (stop_*.odin).
stop_requested: bool

main :: proc() {
	opts := Options {
		universe    = "universe",
		port        = netcode.DEFAULT_PORT,
		max_players = server.DEFAULT_MAX_PLAYERS,
		view_radius = 12,
		view_height = 6,
		backups     = server.BACKUP_KEEP,
	}
	flags.parse_or_exit(&opts, os.args, .Unix, context.temp_allocator)
	if opts.version {
		fmt.printfln("Voxiverse server %s (%s build)", base.version_text(), base.build_name())
		os.exit(0)
	}
	dbg: base.Debug
	context = base.debug_begin(&dbg, "voxiverse-server.log", "main")
	log.infof("Voxiverse server %s (%s build)", base.version_text(), base.build_name())
	if base.PROFILE {
		// A profiling build (`build build --profile`): the trace beside the executable.
		dir, _ := os.get_executable_directory(context.temp_allocator)
		path :=
			filepath.join(
				{dir, "voxiverse-server.spall"},
				context.temp_allocator,
			) or_else "voxiverse-server.spall"
		if base.profile_start(path) {log.infof("profiling to %s", path)}
	}
	ok: bool
	switch {
	case opts.benchmark != "":
		ok = run_benchmark(opts.benchmark, opts.smoke)
	case opts.check:
		ok = run_check(opts.universe)
	case opts.restore != "":
		ok = run_restore(opts.universe, opts.restore)
	case opts.collector:
		ok = run_collector(opts)
	case:
		ok = run(opts)
	}
	base.profile_stop()
	ok = base.debug_end(&dbg) && ok
	os.exit(0 if ok else 1)
}

run :: proc(opts: Options) -> bool {
	seed := opts.seed
	if seed == 0 {crypto.rand_bytes(mem.ptr_to_bytes(&seed))}
	name := opts.name
	if name == "" {name = filepath.base(opts.universe)}
	config := server.Config {
		seed            = seed,
		view_radius     = i32(clamp(opts.view_radius, 2, 32)),
		view_height     = i32(clamp(opts.view_height, 1, 16)),
		workers         = max(1, os.get_processor_core_count() / 2),
		everyone_cheats = opts.cheats,
		save_dir        = opts.universe,
		max_players     = opts.max_players,
		listen          = true,
		port            = opts.port,
		password        = opts.password,
		name            = name,
		capture         = opts.capture,
		backups         = max(0, opts.backups),
	}
	if opts.telemetry != "" {
		ep, err := net.resolve_ip4(opts.telemetry)
		if err != nil {
			log.errorf("cannot find the collector %s (%v)", opts.telemetry, err)
			return false
		}
		if ep.port == 0 {ep.port = COLLECTOR_PORT}
		config.upload = server.Upload{ep, server_key(opts.universe), 0}
	}
	srv := new(server.Server)
	defer free(srv)
	if !server.start(srv, config, {}) {return false}
	catch_stop()
	log.infof(
		"server ready world=%s port=%d name=%q (Ctrl+C stops it)",
		opts.universe,
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

COLLECTOR_PORT :: 27316

// run_collector: a telemetry collector (collector/) until stopped.
run_collector :: proc(opts: Options) -> bool {
	port := opts.port if opts.port != netcode.DEFAULT_PORT else COLLECTOR_PORT
	c := new(collector.Collector)
	defer free(c)
	if !collector.collector_start(c, opts.universe, port) {return false}
	catch_stop()
	log.infof("collector ready dir=%s port=%d (Ctrl+C stops it)", opts.universe, c.port)
	started := time.tick_now()
	for !sync.atomic_load(&stop_requested) {
		time.sleep(100 * time.Millisecond)
		if opts.seconds > 0 &&
		   time.duration_seconds(time.tick_since(started)) >= f64(opts.seconds) {break}
	}
	st := collector.collector_stats(c)
	collector.collector_stop(c)
	log.infof(
		"collector stopped batches=%d lines=%d duplicates=%d refused=%d forged=%d reports=%d",
		st.accepted_batches,
		st.accepted_lines,
		st.duplicates,
		st.refused,
		st.forged,
		st.reports,
	)
	return true
}

// server_key: this server's account, kept in its universe (made the first time).
server_key :: proc(dir: string) -> (key: game.Account_Key) {
	path := filepath.join({dir, "server.key"}, context.temp_allocator) or_else "server.key"
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator);
	   err == nil && len(data) == 32 {
		if game.account_key_set(&key, data) {return}
	}
	key = game.account_key_make()
	seed := game.account_key_seed(&key)
	os.make_directory_all(dir)
	_ = os.write_entire_file(path, seed[:])
	return
}

// run_check: --check. A save the server could open is whole.
run_check :: proc(universe: string) -> bool {
	if why := server.store_recover(universe, &base.Disk{}); why != "" {
		fmt.eprintfln("%s", why)
		return false
	}
	report := server.universe_check(universe)
	if report.ok {
		fmt.printfln("%s: ok (generation %d)", universe, report.generation)
		return true
	}
	for p in report.problems {fmt.eprintfln("%s", p)}
	return false
}

// run_restore: --restore.
run_restore :: proc(universe, name: string) -> bool {
	if why := server.universe_restore(universe, name, &base.Disk{}); why != "" {
		fmt.eprintfln("cannot restore: %s", why)
		return false
	}
	fmt.printfln("%s: restored from %s", universe, name)
	return true
}
