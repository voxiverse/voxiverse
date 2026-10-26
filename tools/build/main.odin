package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The Voxiverse build driver. build.sh / build.bat hand every argument to
// it; its commands are listed by usage (`build help`). It runs from the
// repository root (the wrapper scripts cd there).

// PACKAGES are type-checked by `check`, each on its own so one broken
// package doesn't hide errors in the others.
PACKAGES :: []string {
	"base",
	"audio",
	"netcode",
	"telemetry",
	"collector",
	"font",
	"ui",
	"game",
	"worldgen",
	"server",
	"platform",
	"gpu",
	"render",
	"client",
	"client/mesh",
	"client/sfx",
	"dedicated",
	"tools/build",
	"tools/netdump",
	"tools/audiodump",
	"tools/analytics",
	"tools/replay",
	"tools/sfx",
	"tools/worldmap",
	"tools/bench",
	"tools/debugger/printer_test",
}
// TEST_PACKAGES contain @(test) procedures.
TEST_PACKAGES :: []string {
	"base",
	"audio",
	"netcode",
	"telemetry",
	"collector",
	"font",
	"ui",
	"game",
	"worldgen",
	"server",
	"render",
	"client/mesh",
	"client/sfx",
	"client",
	"tools/analytics",
	"tools/build",
}
// SOURCE_DIRS hold first-party Odin code (formatting is checked here).
SOURCE_DIRS :: []string {
	"base",
	"dedicated",
	"audio",
	"netcode",
	"telemetry",
	"collector",
	"font",
	"ui",
	"game",
	"worldgen",
	"server",
	"platform",
	"gpu",
	"render",
	"client",
	"tools",
}

ODIN_FLAGS :: []string{"-vet", "-strict-style", "-warnings-as-errors"}
// CHECK_FLAGS: library packages have no main of their own.
CHECK_FLAGS :: []string{"-no-entry-point"}

GAME_PACKAGE :: "client"
GAME_NAME :: "voxiverse"
SERVER_PACKAGE :: "dedicated"
SERVER_NAME :: "voxiverse-server"

SHADER_DIR :: "assets/shaders"
SHADER_OUT_DIR :: "build/shaders"
SHADER_EXTS :: []string{".vert", ".frag", ".comp"}

main :: proc() {
	context.allocator = context.temp_allocator // short-lived CLI; freed at exit

	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(1)
	}
	ok: bool
	switch args[0] {
	case "check",
	     "test",
	     "build",
	     "determinism",
	     "run",
	     "serve",
	     "debug",
	     "package",
	     "audiodump",
	     "audio":
		// The game's packages link miniaudio; even type-checking wants it.
		compare_only := args[0] == "determinism" && len(args) > 1 && args[1] == "--compare"
		if !compare_only && !ensure_miniaudio() {os.exit(1)}
	}
	switch args[0] {
	case "check":
		ok = check()
	case "test":
		ok = test()
	case "determinism":
		ok = determinism(args[1:])
	case "fmt":
		ok = format_sources()
	case "shaders":
		ok = shaders()
	case "icon":
		ok = write_icon()
	case "build":
		_, ok = build_game(args[1:])
	case "package":
		ok = package_game()
	case "run":
		ok = run_game(args[1:])
	case "serve":
		ok = serve(args[1:])
	case "debug":
		ok = debug_game(args[1:])
	case "netdump", "audiodump", "replay", "sfx", "worldmap", "analytics":
		ok = run_tool(args[0], args[1:])
	case "audio":
		ok = audio_baselines(args[1:])
	case "bench":
		ok = bench(args[1:])
	case "trace":
		ok = trace(args[1:])
	case "perf":
		ok = perf_record(args[1:])
	case "help", "-h", "--help":
		usage()
		ok = true
	case:
		fmt.eprintfln("build: unknown command '%s'", args[0])
		usage()
	}
	os.exit(0 if ok else 1)
}

usage :: proc() {
	fmt.println("usage: build <command>")
	fmt.println("  check     type-check every package (-vet -strict-style) and verify formatting")
	fmt.println("  test      run the unit tests")
	fmt.println(
		"  determinism  run the scripted session at -o:minimal and -o:speed and compare the logs (--compare <dir>: every log in a directory)",
	)
	fmt.println("  fmt       format all sources in place (odinfmt)")
	fmt.println("  shaders   compile assets/shaders to SPIR-V (fetches the pinned glslang once)")
	fmt.println(
		"  audio     run the audio baselines (--accept <scenario|all> rewrites them, --wav <dir> renders each to a WAV)",
	)
	fmt.println(
		"  audiodump dump an audio capture: timeline, voice decisions, loudness, a bus as WAV (-report, -bus:, -wav:)",
	)
	fmt.println("  netdump   print a network trace (build/net.trace; -summary, -kind:chunk, ...)")
	fmt.println("  replay    replay a trace's client messages against a fresh server")
	fmt.println("  sfx       write every sound effect to build/sounds/*.wav")
	fmt.println(
		"  worldmap  draw an Earth world from above to build/worldmap.png (-seed:N -size:4096 ...)",
	)
	fmt.println(
		"  bench     run a benchmark scenario (PLAN.md, M19; results in build/benchmarks/):",
	)
	fmt.println("              chunks       generate, light and mesh on one thread (-check: CI's)")
	fmt.println(
		"              load, views, flight, edits, audio  the game (a release build, fixed settings;",
	)
	fmt.println("                           server: the server alone, simulated players;")
	fmt.println("                           --smoke: one short run, as CI does)")
	fmt.println("                           --profile: traced too)")
	fmt.println(
		"              compare <ref> <scenario> [-runs:N]  the working tree against a commit,",
	)
	fmt.println("                           alternating runs; changes called beyond the noise")
	fmt.println(
		"  trace     summarize a profile trace (build/voxiverse.spall; scopes for its timeline)",
	)
	fmt.println("  perf      record game, server or bench under Linux perf (-- program arguments)")
	fmt.println("  icon      draw the game's icon to build/voxiverse.ico and build/icon.png")
	fmt.println("  build     build the game and the dedicated server into build/: by default a")
	fmt.println("            development build (lightly optimized, debug info, the dev aids), or:")
	fmt.println("              --debug      unoptimized, for stepping through in a debugger")
	fmt.println("              --release    fully optimized, no dev aids (slow to compile)")
	fmt.println("              --symbols    with --release: line tables too, for perf")
	fmt.println("              --sanitize   unoptimized with AddressSanitizer")
	fmt.println(
		"              --profile    writing a Spall trace (with --release for real numbers)",
	)
	fmt.println("  package   a release package for this platform in build/dist/ (PLAN.md, M21)")
	fmt.println("  run       build, then run it; arguments after -- go to the game")
	fmt.println("  serve     build, then run the dedicated server; arguments after -- go to it")
	fmt.println(
		"  debug     build, then run it in the debugger (gdb; --lldb, --gdb; RAD Debugger on Windows)",
	)
}

// Build profiles. Compile times (the client, on one machine):
// unoptimized 1.4 s, -o:minimal 1.8 s, -o:speed 30 s; run times in the
// chunk pipeline: unoptimized 7-15x slower than -o:speed, -o:minimal 3-8x.
// So the everyday build is -o:minimal with debug info and the dev aids
// (base.DEV); --debug drops the optimizing for stepping through code;
// --release is -o:speed without the dev aids, and --symbols adds line
// tables to it (Odin's -debug, with VX_DEV forced off) for profilers.
Profile :: enum {
	Dev,
	Debug,
	Release,
}

// build_game compiles shaders, the game and the dedicated server; windowed:
// the game is a windowed program on Windows (no console: a player's).
build_game :: proc(args: []string, windowed := false) -> (exe: string, ok: bool) {
	profile := Profile.Dev
	symbols, sanitize, trace := false, false, false
	for arg in args {
		switch arg {
		case "--debug":
			profile = .Debug
		case "--release":
			profile = .Release
		case "--symbols":
			symbols = true
		case "--sanitize":
			sanitize = true
		case "--profile":
			trace = true
		case:
			fmt.eprintfln("build: unknown option '%s'", arg)
			return "", false
		}
	}
	if sanitize && profile == .Release {
		fmt.eprintln("build: --sanitize is unoptimized; drop --release")
		return "", false
	}
	if sanitize {profile = .Debug}
	if symbols && profile != .Release {
		fmt.eprintln("build: --symbols is for --release (the others have them)")
		return "", false
	}
	mode := make([dynamic]string)
	switch profile {
	case .Dev:
		append(&mode, "-o:minimal", "-debug")
	case .Debug:
		append(&mode, "-debug")
	case .Release:
		append(&mode, "-o:speed")
		if symbols {append(&mode, "-debug", "-define:VX_DEV=false")}
	}
	if trace {append(&mode, "-define:VX_PROFILE=true")}
	v := version_of()
	append(&mode, ..version_defines(v))
	shaders() or_return
	exe = path_join({"build", strings.concatenate({GAME_NAME, exe_suffix()})})
	if sanitize {
		append(&mode, "-sanitize:address")
		// Leaks are the tracking allocator's job; LSan would also report
		// GPU drivers' own allocations.
		if _, set := os.lookup_env("ASAN_OPTIONS", context.allocator); !set {
			os.set_env("ASAN_OPTIONS", "detect_leaks=0")
		}
	}
	game_extra, server_extra: [dynamic]string
	// One file: the shaders inside (no hot reload without the dev aids).
	if profile == .Release {append(&game_extra, "-define:VX_EMBED_SHADERS=true")}
	// Windows: the icon and version information linked in.
	when ODIN_OS == .Windows {
		rc := windows_resource(v, GAME_NAME, "Voxiverse") or_return
		append(&game_extra, strings.concatenate({"-resource:", rc}))
		if windowed {append(&game_extra, "-subsystem:windows")}
		rc = windows_resource(v, SERVER_NAME, "Voxiverse server") or_return
		append(&server_extra, strings.concatenate({"-resource:", rc}))
	}
	cmd := slice.concatenate(
		[][]string {
			{"odin", "build", GAME_PACKAGE},
			ODIN_FLAGS,
			mode[:],
			game_extra[:],
			{strings.concatenate({"-out:", exe})},
		},
	)
	run(cmd) or_return
	server_exe := path_join({"build", strings.concatenate({SERVER_NAME, exe_suffix()})})
	server_cmd := slice.concatenate(
		[][]string {
			{"odin", "build", SERVER_PACKAGE},
			ODIN_FLAGS,
			mode[:],
			server_extra[:],
			{strings.concatenate({"-out:", server_exe})},
		},
	)
	run(server_cmd) or_return
	fmt.printfln(
		"built  %s, %s %s (%s%s%s%s)",
		exe,
		server_exe,
		version_text(v),
		PROFILE_NAMES[profile],
		" + symbols" if symbols else "",
		" + sanitizer" if sanitize else "",
		" + profiling" if trace else "",
	)
	return exe, true
}

// debug_game runs a debug build under the platform's debugger with the Odin
// pretty-printers from tools/debugger loaded.
debug_game :: proc(args: []string) -> bool {
	opts, game_args := args, []string{}
	if i, found := slice.linear_search(args, "--"); found {
		opts, game_args = args[:i], args[i + 1:]
	}
	use_lldb := ODIN_OS == .Darwin
	for opt in opts {
		switch opt {
		case "--lldb":
			use_lldb = true
		case "--gdb":
			use_lldb = false
		case:
			fmt.eprintfln("build: unknown option '%s'", opt)
			return false
		}
	}
	exe, ok := build_game({"--debug"})
	if !ok {return false}
	when ODIN_OS == .Windows {
		// PDB debug info; RAD Debugger understands Odin types natively.
		if _, found := capture({"where", "raddbg"}); found {
			return run(slice.concatenate([][]string{{"raddbg", exe}, game_args}))
		}
		fmt.eprintln(
			"build: open build\\voxiverse.exe in RAD Debugger, RemedyBG or Visual Studio (see DEBUGGING.md)",
		)
		return false
	} else {
		if use_lldb {
			cmd := slice.concatenate(
				[][]string {
					{"lldb", "-o", "command script import tools/debugger/odin_lldb.py", "--", exe},
					game_args,
				},
			)
			return run(cmd)
		}
		cmd := slice.concatenate(
			[][]string {
				{"gdb", "-q", "-x", "tools/debugger/odin_gdb.py", "--args", exe},
				game_args,
			},
		)
		return run(cmd)
	}
}

// serve builds everything and runs the dedicated server with server_args.
serve :: proc(args: []string) -> bool {
	build_args, server_args := args, []string{}
	if i, found := slice.linear_search(args, "--"); found {
		build_args, server_args = args[:i], args[i + 1:]
	}
	build_game(build_args) or_return
	exe := path_join({"build", strings.concatenate({SERVER_NAME, exe_suffix()})})
	return run(slice.concatenate([][]string{{exe}, server_args}))
}

run_game :: proc(args: []string) -> bool {
	build_args, game_args := args, []string{}
	if i, found := slice.linear_search(args, "--"); found {
		build_args, game_args = args[:i], args[i + 1:]
	}
	exe, ok := build_game(build_args)
	if !ok {return false}
	return run(slice.concatenate([][]string{{exe}, game_args}))
}

check :: proc() -> bool {
	ok := true
	for pkg in PACKAGES {
		cmd := slice.concatenate([][]string{{"odin", "check", pkg}, ODIN_FLAGS, CHECK_FLAGS})
		if run(cmd) {
			fmt.printfln("check  %s", pkg)
		} else {
			fmt.eprintfln("check  %s FAILED", pkg)
			ok = false
		}
	}
	return determinism_lint() && check_format() && ok
}

test :: proc() -> bool {
	ok := true
	for pkg in TEST_PACKAGES {
		out := path_join(
			{"build", "test", strings.concatenate({filepath.base(pkg), exe_suffix()})},
		)
		cmd := slice.concatenate(
			[][]string{{"odin", "test", pkg}, ODIN_FLAGS, {strings.concatenate({"-out:", out})}},
		)
		os.make_directory_all(filepath.dir(out))
		ok = run(cmd) && ok
	}
	return ok
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

format_sources :: proc() -> bool {
	if !have_odinfmt() {return false}
	ok := true
	for dir in SOURCE_DIRS {
		ok = run({"odinfmt", "-w", dir}) && ok
	}
	return ok
}

// check_format compares every source file with odinfmt's output.
check_format :: proc() -> bool {
	if !have_odinfmt() {return false}
	dirty := 0
	for path in odin_files() {
		formatted, ok := capture({"odinfmt", path})
		current, err := os.read_entire_file_from_path(path, context.allocator)
		if !ok || err != nil || formatted != string(current) {
			fmt.eprintfln("fmt    %s needs formatting", path)
			dirty += 1
		}
	}
	if dirty > 0 {
		fmt.eprintfln("fmt    %d file(s) not formatted - run `build fmt`", dirty)
		return false
	}
	fmt.println("fmt    clean")
	return true
}

have_odinfmt :: proc() -> bool {
	if _, ok := capture({"odinfmt", "-h"}); ok {return true}
	fmt.eprintln("build: odinfmt not found - `odinup install --dev` builds it (with ols)")
	return false
}

odin_files :: proc() -> []string {
	files := make([dynamic]string)
	for dir in SOURCE_DIRS {
		w := os.walker_create(dir)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type == .Regular && filepath.ext(info.name) == ".odin" {
				append(&files, strings.clone(info.fullpath))
			}
		}
	}
	slice.sort(files[:])
	return files[:]
}

// ---------------------------------------------------------------------------
// Shaders
// ---------------------------------------------------------------------------

// shaders compiles each assets/shaders/<name>.<stage> to
// build/shaders/<name>.<stage>.spv when the source is newer than the output.
shaders :: proc() -> bool {
	sources, err := os.read_all_directory_by_path(SHADER_DIR, context.allocator)
	if err != nil {
		fmt.eprintfln("shaders: cannot read %s: %v", SHADER_DIR, err)
		return false
	}
	glslang, found := glslang_path()
	if !found {return false}
	os.make_directory_all(SHADER_OUT_DIR)

	// Shaders may #include any .glsl here: a newer include rebuilds them all.
	newest_include: i64
	for src in sources {
		if filepath.ext(src.name) == ".glsl" {
			newest_include = max(newest_include, src.modification_time._nsec)
		}
	}
	ok := true
	compiled := 0
	for src in sources {
		if !slice.contains(SHADER_EXTS, filepath.ext(src.name)) {continue}
		out := path_join({SHADER_OUT_DIR, strings.concatenate({src.name, ".spv"})})
		newest := max(src.modification_time._nsec, newest_include)
		if dst, serr := os.stat(out, context.allocator);
		   serr == nil && dst.modification_time._nsec >= newest {
			continue
		}
		if run({glslang, "-V", "--target-env", "vulkan1.3", "--quiet", "-o", out, src.fullpath}) {
			fmt.printfln("shader %s", src.name)
			compiled += 1
		} else {
			ok = false
		}
	}
	if ok && compiled == 0 {fmt.println("shader up to date")}
	return ok
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

// run executes cmd with our stdio and reports success.
run :: proc(cmd: []string) -> bool {
	desc := os.Process_Desc {
		command = cmd,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	child, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("build: could not start '%s': %v", cmd[0], err)
		return false
	}
	state, werr := os.process_wait(child)
	return werr == nil && state.exited && state.exit_code == 0
}

// audio_baselines runs the audio quality baselines (client/audio_baseline_test.odin,
// files in assets/baselines/audio/): `--accept <scenario|all>` rewrites the
// named baseline from what the scenario sounds like now (review the diff),
// `--wav <dir>` also writes every scenario's master as a WAV to listen to.
audio_baselines :: proc(args: []string) -> bool {
	defines := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--accept":
			if i + 1 >= len(args) {
				fmt.eprintln("build: audio --accept <burst|cave_walk|title_to_world|stress|all>")
				return false
			}
			i += 1
			if !slice.contains(
				[]string{"burst", "cave_walk", "title_to_world", "stress", "all"},
				args[i],
			) {
				fmt.eprintfln("build: audio --accept: no scenario '%s'", args[i])
				return false
			}
			append(&defines, strings.concatenate({"-define:VX_AUDIO_ACCEPT=", args[i]}))
		case "--wav":
			if i + 1 >= len(args) {
				fmt.eprintln("build: audio --wav <directory>")
				return false
			}
			i += 1
			append(&defines, strings.concatenate({"-define:VX_AUDIO_WAV_DIR=", args[i]}))
		case:
			fmt.eprintfln(
				"build: audio takes --accept <scenario|all> and --wav <dir>, not '%s'",
				args[i],
			)
			return false
		}
	}
	out := path_join({"build", "test", strings.concatenate({"audio-baselines", exe_suffix()})})
	os.make_directory_all(filepath.dir(out))
	cmd := slice.concatenate(
		[][]string {
			{"odin", "test", GAME_PACKAGE},
			ODIN_FLAGS,
			{
				strings.concatenate({"-out:", out}),
				"-define:ODIN_TEST_NAMES=client.test_audio_baselines",
			},
			defines[:],
		},
	)
	return run(cmd)
}

// run_tool builds and runs tools/<name> with args (netdump, replay, sfx).
run_tool :: proc(name: string, args: []string) -> bool {
	exe := build_tool(name) or_return
	return run(slice.concatenate([][]string{{exe}, args}))
}

// build_tool builds tools/<name> into build/.
build_tool :: proc(name: string) -> (exe: string, ok: bool) {
	exe = path_join({"build", strings.concatenate({name, exe_suffix()})})
	cmd := slice.concatenate(
	[][]string {
		{"odin", "build", path_join({"tools", name}), strings.concatenate({"-out:", exe})},
		ODIN_FLAGS,
		// The map generates millions of columns: optimized. The benchmark
		// as a release build, with line tables for perf.
		{"-o:speed"} if name == "worldmap" else {"-o:speed", "-debug", "-define:VX_DEV=false"} if name == "bench" else {},
		version_defines(version_of()),
	},
	)
	return exe, run(cmd)
}

// bench runs a benchmark scenario the one way: `chunks` is tools/bench
// (no game), the others a release build of the game with --benchmark
// (client/benchmark.odin has them and their fixed conditions).
bench :: proc(args: []string) -> bool {
	if len(args) == 0 {
		fmt.eprintln(
			"build: bench <scenario>: chunks, load, views, flight, edits, audio (client/benchmark.odin), server (dedicated/bench.odin), or compare",
		)
		return false
	}
	scenario := args[0]
	if scenario == "compare" {return bench_compare(args[1:])}
	if scenario == "chunks" {return run_tool("bench", args[1:])}
	build_args := []string{"--release"}
	smoke := false
	for arg in args[1:] {
		switch arg {
		case "--profile":
			build_args = {"--release", "--profile"}
		case "--smoke":
			smoke = true
		case:
			fmt.eprintfln("build: bench %s takes --profile or --smoke, not '%s'", scenario, arg)
			return false
		}
	}
	exe := build_game(build_args) or_return
	if scenario == "server" {
		// The server alone (dedicated/bench.odin).
		exe = path_join({"build", strings.concatenate({SERVER_NAME, exe_suffix()})})
	}
	if smoke {return run({exe, "--benchmark", scenario, "--smoke"})}
	return run({exe, "--benchmark", scenario})
}

// trace summarizes a Spall trace (default build/voxiverse.spall); further
// arguments name the scopes for its timeline.
trace :: proc(args: []string) -> bool {
	path := "build/voxiverse.spall"
	scopes := args
	if len(args) > 0 && strings.has_suffix(args[0], ".spall") {path, scopes = args[0], args[1:]}
	python := "python" when ODIN_OS == .Windows else "python3"
	return run(
		slice.concatenate([][]string{{python, "tools/debugger/spall_summary.py", path}, scopes}),
	)
}

// perf_record runs the game (or `bench`, or `server`) under Linux perf,
// sampling with call stacks, and prints where the time went per thread;
// build/<name>.perf stays for `perf report` (call graphs; --sort srcline
// for source lines). Arguments after -- go to the program. The game and
// server are release builds with line tables (--release --symbols).
perf_record :: proc(args: []string) -> bool {
	when ODIN_OS != .Linux {
		fmt.eprintln(
			"build: perf is Linux's (on Windows: a sampling profiler such as Superluminal or VTune on a --release --symbols build)",
		)
		return false
	} else {
		opts, program_args := args, []string{}
		if i, found := slice.linear_search(args, "--"); found {
			opts, program_args = args[:i], args[i + 1:]
		}
		target := opts[0] if len(opts) > 0 else "game"
		exe: string
		switch target {
		case "game", "server":
			game := build_game({"--release", "--symbols"}) or_return
			exe = game
			if target ==
			   "server" {exe = path_join({"build", strings.concatenate({SERVER_NAME, exe_suffix()})})}
		case "bench":
			exe = build_tool("bench") or_return
		case:
			fmt.eprintfln("build: perf records game, server or bench, not '%s'", target)
			return false
		}
		// Last-branch records where the CPU has them (Intel): small and
		// cheap; else unwinding copies of the stack (large files).
		graph := "dwarf,16384"
		if _, lbr := capture(
			{"perf", "record", "-q", "--call-graph", "lbr", "-o", "/dev/null", "--", "true"},
		); lbr {
			graph = "lbr"
		}
		out := path_join({"build", strings.concatenate({target, ".perf"})})
		record := slice.concatenate(
			[][]string {
				{
					"perf",
					"record",
					"-q",
					"-F",
					"1000",
					"--call-graph",
					graph,
					"-o",
					out,
					"--",
					exe,
				},
				program_args,
			},
		)
		ran := run(record)
		run(
			{
				"perf",
				"report",
				"-i",
				out,
				"--no-children",
				"--stdio",
				"--sort",
				"comm,symbol",
				"-g",
				"none",
				"--percent-limit",
				"1",
			},
		) or_return
		fmt.printfln(
			"perf   %s (call graphs: perf report -i %s; lines: add --sort srcline)",
			out,
			out,
		)
		return ran
	}
}

// capture executes cmd and returns its stdout; ok is false if it failed or
// couldn't start (silently: callers decide whether that is an error).
capture :: proc(cmd: []string) -> (output: string, ok: bool) {
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil {return "", false}
	return string(stdout), state.exited && state.exit_code == 0
}

exe_suffix :: proc() -> string {
	return ".exe" when ODIN_OS == .Windows else ""
}

// path_join joins path elements; allocation failure is fatal for a CLI anyway.
path_join :: proc(elems: []string) -> string {
	p, _ := filepath.join(elems)
	return p
}

PROFILE_NAMES := [Profile]string {
	.Dev     = "development",
	.Debug   = "debug",
	.Release = "release",
}
