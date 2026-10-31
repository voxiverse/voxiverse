package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "tools:build/limited"

// The Voxiverse build driver. build.sh / build.bat hand every argument to
// it; its commands are listed by usage (`build help`). It runs from the
// repository root (the wrapper scripts cd there).

// PACKAGES are type-checked by `check`, each on its own so one broken
// package doesn't hide errors in the others.
PACKAGES :: []string {
	"common/base",
	"common/ogg",
	"client/audio",
	"common/netcode",
	"common/telemetry",
	"server/collector",
	"client/font",
	"client/ui",
	"common/game",
	"common/worldgen",
	"server",
	"client/platform",
	"client/gpu",
	"client/render",
	"client",
	"client/mesh",
	"client/sfx",
	"dedicated",
	"tools/build",
	"tools/netdump",
	"tools/ogg",
	"tools/schema",
	"tools/packcheck",
	"tools/audiodump",
	"tools/analytics",
	"tools/replay",
	"tools/sfx",
	"tools/music",
	"tools/worldmap",
	"tools/bench",
	"tools/debugger/printer_test",
	"tests",
}
// TEST_PACKAGES contain @(test) procedures.
TEST_PACKAGES :: []string {
	"common/base",
	"common/ogg",
	"client/audio",
	"common/netcode",
	"common/telemetry",
	"server/collector",
	"client/font",
	"client/ui",
	"common/game",
	"common/worldgen",
	"server",
	"client/render",
	"client/mesh",
	"client/sfx",
	"client/platform",
	"client",
	"tools/analytics",
	"tools/music",
	"tools/build",
}
// SOURCE_DIRS hold first-party Odin code (formatting is checked here).
SOURCE_DIRS :: []string {
	"common/base",
	"common/ogg",
	"dedicated",
	"client/audio",
	"common/netcode",
	"common/telemetry",
	"server/collector",
	"client/font",
	"client/ui",
	"common/game",
	"common/worldgen",
	"server",
	"client/platform",
	"client/gpu",
	"client/render",
	"client",
	"tools",
	"tests",
}

// COLLECTIONS: the roots first-party code imports through (client:gpu, server:collector,
// common:game, tools:build/limited). The driver passes them to every odin it runs; build.sh,
// build.bat (the driver's own build) and ols.json (the editor) repeat them, and a test keeps
// those three in step. A package's own directory is `server:.` / `client:.`.
COLLECTIONS :: []string {
	"-collection:client=client",
	"-collection:server=server",
	"-collection:common=common",
	"-collection:tools=tools",
}

ODIN_FLAGS :: []string{"-vet", "-strict-style", "-warnings-as-errors"}
// CHECK_FLAGS: library packages have no main of their own.
CHECK_FLAGS :: []string{"-no-entry-point"}

GAME_PACKAGE :: "client"
GAME_NAME :: "voxiverse"
SERVER_PACKAGE :: "dedicated"
SMOKE_PACKAGE :: "tests"
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
	switch args[0] {
	case "self-fresh", "self-built", "help", "-h", "--help", "shaders":
	// No lock: the bootstrap runs before the driver is there to take it, help writes
	// nothing, and a game with hot reload runs `shaders` on its main thread (waiting
	// for a test run there would freeze it).
	case:
		// One run at a time: the job logs, the test binaries, the content cache and the
		// cross objects are one set of names, and two runs at once silently corrupt
		// each other. A second run waits for the first. run, serve, debug and the tools
		// let it go once built, so a game that is up never holds it.
		os.make_directory_all(CACHE_DIR)
		locked: bool
		build_lock, locked = lock_build(
			path_join({CACHE_DIR, "lock"}),
			fmt.tprintf("pid %d: build %s", os.get_pid(), strings.join(args, " ")),
		)
		if !locked {os.exit(1)}
	}
	ok: bool
	switch args[0] {
	case "check",
	     "test",
	     "smoke",
	     "build",
	     "determinism",
	     "run",
	     "serve",
	     "debug",
	     "package",
	     "audiodump",
	     "music",
	     "bench",
	     "images",
	     "audio":
		// The game's packages link miniaudio; even type-checking wants it.
		compare_only := args[0] == "determinism" && len(args) > 1 && args[1] == "--compare"
		if !compare_only && !ensure_miniaudio() {os.exit(1)}
	}
	switch args[0] {
	case "check":
		ok = check()
	case "test":
		ok = test(args[1:])
	case "smoke":
		ok = smoke()
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
	case "netdump",
	     "audiodump",
	     "replay",
	     "sfx",
	     "music",
	     "worldmap",
	     "analytics",
	     "schema",
	     "ogg":
		ok = run_tool(args[0], args[1:], release = true)
	case "packs":
		ok = run_tool("packcheck", args[1:], release = true)
	case "audio":
		ok = audio_baselines(args[1:])
	case "images":
		ok = images(args[1:])
	case "bench":
		ok = bench(args[1:])
	case "trace":
		ok = trace(args[1:])
	case "perf":
		ok = perf_record(args[1:])
	case "self-fresh":
		// (build.sh: is this driver built from the sources there now?)
		step := driver_step()
		ok = odin_step_fresh(&step)
	case "self-built":
		// (build.sh, after building it: remember what it was built from)
		step := driver_step()
		started := path_join({CACHE_DIR, "build-driver.started"})
		info, err := os.stat(started, context.allocator)
		ok = err == nil
		if ok {
			step.started = info.modification_time
			odin_step_succeeded(&step)
		}
	case "help", "-h", "--help":
		usage()
		ok = true
	case:
		fmt.eprintfln("build: unknown command '%s'", args[0])
		usage()
	}
	os.exit(0 if ok else 1)
}

// build_lock: held by this run until it ends or release_build_lock (main).
@(private = "file")
build_lock: Build_Lock

// release_build_lock lets another run start: what follows writes nothing under build/
// that a run shares (a game or a tool, started after it is built).
release_build_lock :: proc() {
	unlock_build(&build_lock)
}

usage :: proc() {
	fmt.println("usage: build <command>")
	fmt.println(
		"  check     type-check every package (-vet -strict-style), build objects for the other Tier 1 targets, verify formatting",
	)
	fmt.println(
		"            (its builds for other targets skip what is unchanged since it last passed, by content: build/cache)",
	)
	fmt.println(
		"  test      run the unit tests, the packages in parallel (VX_JOBS=n at once, else one per core); `test <package>...`: only those",
	)
	fmt.println(
		"            (a package unchanged since built runs without compiling; its output is kept in build/test/<package>.log, printed only when it fails)",
	)
	fmt.println(
		"  smoke     run the smoke suite (real threads, sockets, audio devices, child processes), one test at a time",
	)
	fmt.println(
		"  determinism  run the scripted session at -o:minimal and -o:speed and compare the logs (--compare <dir>: every log in a directory)",
	)
	fmt.println("  fmt       format all sources in place (odinfmt)")
	fmt.println("  shaders   compile assets/shaders to SPIR-V (fetches the pinned glslang once)")
	fmt.println(
		"  audio     run the audio baselines (--accept <scenario|all> rewrites them, --wav <dir> renders each to a WAV)",
	)
	fmt.println(
		"  images    render the visual baselines' scenes on lavapipe and compare them (--accept <scene|all> rewrites them; Linux)",
	)
	fmt.println(
		"  audiodump dump an audio capture: timeline, voice decisions, loudness, a bus as WAV (-report, -bus:, -wav:)",
	)
	fmt.println("  netdump   print a network trace (build/net.trace; -summary, -kind:chunk, ...)")
	fmt.println(
		"  schema    rewrite the Wireshark dissector's generated schema block from the game's state kinds",
	)
	fmt.println(
		"  packs     check content packs: the base pack plus the given pack directories, in order",
	)
	fmt.println(
		"  ogg       the Ogg decoder's maintenance: digests | reference | fuzz [--seed N] [--iterations N]",
	)
	fmt.println("  replay    replay a trace's client messages against a fresh server")
	fmt.println("  sfx       write every sound effect to build/sounds/*.wav")
	fmt.println(
		"  music     render assets/music/*.score|*.mid to Ogg (--force, --wav <dir>, --midi, --audition <name> [--from <s>])",
	)
	fmt.println(
		"  worldmap  draw an Earth world from above to build/worldmap.png (-seed:N -size:4096 ...)",
	)
	fmt.println(
		"  bench     run a benchmark scenario (docs/plan.md, M19; results in build/benchmarks/):",
	)
	fmt.println("              chunks       generate, light and mesh on one thread (-check: CI's)")
	fmt.println(
		"              ogg          the Ogg decoder against miniaudio's, on the music (no game)",
	)
	fmt.println(
		"              load, views, flight, edits, audio  the game (a release build, fixed settings;",
	)
	fmt.println("                           server: the server alone, simulated players;")
	fmt.println("                           --smoke: one short run, as CI does;")
	fmt.println("                           --profile: traced too;")
	fmt.println("                           -size:WIDTHxHEIGHT: drawn at that size, not 1280x720)")
	fmt.println(
		"              compare <ref> <scenario> [-runs:N] [-size:WxH]  the working tree against a commit,",
	)
	fmt.println("                           alternating runs; changes called beyond the noise")
	fmt.println(
		"  trace     summarize a profile trace (build/voxiverse.spall; scopes for its timeline)",
	)
	fmt.println("  perf      record game, server or bench under Linux perf (-- program arguments)")
	fmt.println(
		"  icon      draw the game's icon to build/voxiverse.ico and build/icon-<size>.png",
	)
	fmt.println("  build     build the game and the dedicated server into build/: by default a")
	fmt.println("            development build (lightly optimized, debug info, the dev aids), or:")
	fmt.println("              --debug      unoptimized, for stepping through in a debugger")
	fmt.println("              --release    fully optimized, no dev aids (slow to compile)")
	fmt.println("              --symbols    with --release: line tables too, for perf")
	fmt.println("              --sanitize   unoptimized with AddressSanitizer")
	fmt.println(
		"              --profile    writing a Spall trace (with --release for real numbers)",
	)
	fmt.println(
		"  package   a release package for this platform in build/dist/ (docs/plan.md, M21)",
	)
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
	when ODIN_OS == .Darwin {moltenvk_path() or_return} 	// the Vulkan driver, found at run time
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
	// macOS: the oldest system asked for, and the game finds MoltenVK in the
	// .app's Frameworks folder.
	when ODIN_OS == .Darwin {
		append(&game_extra, "-minimum-os-version:" + MACOS_MINIMUM)
		append(&game_extra, "-extra-linker-flags:-Wl,-rpath,@executable_path/../Frameworks")
		append(&server_extra, "-minimum-os-version:" + MACOS_MINIMUM)
	}
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
			COLLECTIONS,
			mode[:],
			game_extra[:],
			{strings.concatenate({"-out:", exe})},
		},
	)
	server_exe := path_join({"build", strings.concatenate({SERVER_NAME, exe_suffix()})})
	server_cmd := slice.concatenate(
		[][]string {
			{"odin", "build", SERVER_PACKAGE},
			ODIN_FLAGS,
			COLLECTIONS,
			mode[:],
			server_extra[:],
			{strings.concatenate({"-out:", server_exe})},
		},
	)
	// The two are independent: compiled side by side, each printing its output whole.
	results := parallel(
		{
			{cmd = cmd, log = job_log(0, ".game.log")},
			{cmd = server_cmd, log = job_log(0, ".server.log")},
		},
		2,
	)
	if results[0] != .Ok || results[1] != .Ok {return "", false}
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
	release_build_lock()
	when ODIN_OS == .Windows {
		// PDB debug info; RAD Debugger understands Odin types natively.
		if _, found := capture({"where", "raddbg"}); found {
			return run(slice.concatenate([][]string{{"raddbg", exe}, game_args}))
		}
		fmt.eprintln(
			"build: open build\\voxiverse.exe in RAD Debugger, RemedyBG or Visual Studio (see docs/debugging.md)",
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
	release_build_lock()
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
	release_build_lock()
	return run(slice.concatenate([][]string{{exe}, game_args}))
}

check :: proc() -> bool {
	// The host's type checks and the other targets' object builds share one pool.
	jobs := make([dynamic]Check_Job)
	for pkg in PACKAGES {
		append(
			&jobs,
			Check_Job {
				label = strings.concatenate({"check  ", pkg}),
				cmd = slice.concatenate(
					[][]string{{"odin", "check", pkg}, ODIN_FLAGS, COLLECTIONS, CHECK_FLAGS},
				),
			},
		)
	}
	ok := cross_jobs(&jobs)
	ok = run_checks(jobs[:]) && ok
	return(
		determinism_lint() &&
		source_lint() &&
		import_lint() &&
		collections_lint() &&
		test_lint() &&
		ci_lint() &&
		check_format() &&
		check_no_binaries() &&
		ok \
	)
}

// Check_Job: one of check's commands; a cached one (step set) is skipped while its
// inputs are unchanged.
Check_Job :: struct {
	label: string,
	cmd:   []string,
	step:  Maybe(Odin_Step),
}

// run_checks runs check's jobs in parallel, skipping cached ones whose inputs are
// unchanged; each prints its label, FAILED after it when it failed.
run_checks :: proc(jobs: []Check_Job) -> bool {
	State :: struct {
		jobs:    []Check_Job,
		indices: [dynamic]int, // jobs[indices[i]] is run_parallel's i
		steps:   [dynamic]Odin_Step,
		ok:      bool,
	}
	state := State {
		jobs = jobs,
		ok   = true,
	}
	run_jobs := make([dynamic]limited.Job)
	unchanged := 0
	for &job, i in jobs {
		cmd := job.cmd
		if step, cached := &job.step.?; cached {
			if odin_step_fresh(step) {unchanged += 1; continue}
			cmd = odin_step_command(step)
		}
		append(&state.indices, i)
		append(&run_jobs, limited.Job{cmd = cmd, log = job_log(len(run_jobs))})
	}
	if unchanged > 0 {fmt.printfln("cross  %d unchanged since they last passed", unchanged)}
	done :: proc(data: rawptr, index: int, result: limited.Run_Result, seconds: f64) {
		state := (^State)(data)
		job := &state.jobs[state.indices[index]]
		switch result {
		case .Ok:
			if step, cached := &job.step.?; cached {odin_step_succeeded(step)}
			fmt.println(job.label)
		case .Interrupted:
			fmt.eprintfln("%s interrupted", job.label)
			state.ok = false
		case .Failed, .Timed_Out:
			fmt.eprintfln("%s FAILED", job.label)
			state.ok = false
		}
	}
	parallel(run_jobs[:], jobs_width(), done, &state)
	return state.ok
}

// parallel is limited.run_parallel with Ctrl-C (and TERM) as its stop: the jobs are
// killed with their children and the run ends there, with exit code 130. Outside it a
// Ctrl-C ends the driver as it always did.
parallel :: proc(
	jobs: []limited.Job,
	width: int,
	done: limited.Job_Done = nil,
	data: rawptr = nil,
) -> []limited.Run_Result {
	limited.install_stop_signals()
	results := limited.run_parallel(jobs, width, done, data)
	limited.restore_stop_signals()
	if limited.interrupted() {
		fmt.eprintln("build: interrupted")
		os.exit(130)
	}
	return results
}

// job_log: where a parallel job's output waits to be printed.
job_log :: proc(i: int, ext := ".log") -> string {
	dir := path_join({"build", "tmp", "jobs"})
	os.make_directory_all(dir)
	return path_join({dir, fmt.aprintf("%d%s", i, ext)})
}

// jobs_width: how many commands run at once: VX_JOBS, or one per core.
jobs_width :: proc() -> int {
	if value, found := os.lookup_env("VX_JOBS", context.allocator); found {
		if n, ok := strconv.parse_int(value); ok && n > 0 {return n}
	}
	return max(os.get_processor_core_count(), 1)
}

// driver_step: this driver's own build, as build.sh and build.bat run it (they pass the
// dependency flags odin_step_command would add, and touch build-driver.started first).
driver_step :: proc() -> Odin_Step {
	exe := path_join({"build", strings.concatenate({"build-driver", exe_suffix()})})
	return Odin_Step {
		name = "build-driver",
		cmd = slice.concatenate(
			[][]string {
				{"odin", "build", "tools/build", strings.concatenate({"-out:", exe})},
				COLLECTIONS,
			},
		),
		output = exe,
	}
}

// host_target is the Odin target this driver runs on, as -target: spells it.
host_target :: proc() -> string {
	return ODIN_OS_STRING + "_" + ODIN_ARCH_STRING
}

// ensure_foreign_miniaudio gives vendor:miniaudio the library file the host does
// not use (an empty miniaudio.lib on Linux and macOS, miniaudio.a on Windows).
// Odin refuses to compile the package for a target whose library file is missing,
// and a release ships only the Windows one; object builds never read the file, and
// the host's own never gets a placeholder (ensure_miniaudio builds the real one).
ensure_foreign_miniaudio :: proc() -> bool {
	name := "miniaudio.a" if ODIN_OS == .Windows else "miniaudio.lib"
	lib := path_join({ODIN_ROOT, "vendor", "miniaudio", "lib", name})
	if os.exists(lib) {return true}
	if err := os.write_entire_file(lib, nil); err != nil {
		fmt.eprintfln(
			"cross: could not create the placeholder %s (is %s writable?)",
			lib,
			ODIN_ROOT,
		)
		return false
	}
	return true
}

// cross_jobs builds the game, the server and every test package as objects for
// each Tier 1 target that is not the host, so code that only compiles on the host
// (a variable used only inside `when ODIN_OS == .Linux`) fails here, not in CI.
// Objects only: nothing links or runs. Windows needs -windows-sdk-root to build
// objects without the SDK (any existing directory will do). `odin test` takes no
// such flag and refuses a Windows target without the real SDK, so Windows test
// packages are checked natively on the Windows CI runner only; macOS ones are
// cross-built here.
cross_jobs :: proc(jobs: ^[dynamic]Check_Job) -> bool {
	if !ensure_foreign_miniaudio() {return false}
	host := host_target()
	for target in TIER1_TARGETS {
		if target == host {continue}
		windows := strings.has_prefix(target, "windows")
		cross_flags := slice.concatenate(
			[][]string {
				{strings.concatenate({"-target:", target}), "-build-mode:obj"},
				ODIN_FLAGS,
				COLLECTIONS,
			},
		)
		if windows {
			cross_flags = slice.concatenate([][]string{cross_flags, {"-windows-sdk-root:."}})
		}
		builds := make([dynamic][2]string)
		for pkg in ([]string{GAME_PACKAGE, SERVER_PACKAGE}) {
			append(&builds, [2]string{"build", pkg})
		}
		if windows {
			// The driver itself: its Windows files (the lock, Ctrl-C, how a job's output
			// reaches its log) build nowhere else before CI.
			append(&builds, [2]string{"build", "tools/build"})
		} else {
			for pkg in TEST_PACKAGES {
				append(&builds, [2]string{"test", pkg})
			}
		}
		for b in builds {
			name := filepath.base(b[1])
			out := path_join({"build", "cross", target, b[0], name})
			os.make_directory_all(filepath.dir(out))
			cmd := slice.concatenate(
				[][]string {
					{"odin", b[0], b[1]},
					cross_flags,
					{strings.concatenate({"-out:", out})},
				},
			)
			append(
				jobs,
				Check_Job {
					label = strings.concatenate({"cross  ", target, " ", b[0], " ", b[1]}),
					cmd = cmd,
					// The objects are not used: what is kept is that they built.
					step = Odin_Step {
						name = strings.concatenate({"cross-", target, "-", b[0], "-", name}),
						cmd = cmd,
					},
				},
			)
		}
	}
	return true
}

// check_no_binaries fails if an executable (ELF, PE or Mach-O) is in the tree outside
// build/, tracked or not: build output belongs in build/. One was once committed at the
// root by mistake, and a bare `odin build <pkg>` or `odin test <pkg>` (no -out:) leaves
// <pkg>.bin there.
check_no_binaries :: proc() -> bool {
	listing, ok := capture({"git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"})
	if !ok {
		fmt.eprintln("binary git ls-files failed")
		return false
	}
	found := 0
	for path in strings.split(listing, "\x00", context.temp_allocator) {
		if path == "" {continue}
		f, err := os.open(path)
		if err != nil {continue}
		head: [4]u8
		n, _ := os.read(f, head[:])
		os.close(f)
		if n < 4 {continue}
		elf := head == {0x7f, 'E', 'L', 'F'}
		pe := head[0] == 'M' && head[1] == 'Z'
		mach :=
			head == {0xcf, 0xfa, 0xed, 0xfe} ||
			head == {0xfe, 0xed, 0xfa, 0xcf} ||
			head == {0xca, 0xfe, 0xba, 0xbe}
		if elf || pe || mach {
			fmt.eprintfln(
				"binary %s is an executable: build output goes in build/ (delete it; `./build.sh test <package>` instead of `odin test`)",
				path,
			)
			found += 1
		}
	}
	if found > 0 {return false}
	fmt.println("binary none outside build/")
	return true
}

// test_env_defines turns the environment's ODIN_TEST_RANDOM_SEED, ODIN_TEST_THREADS and
// ODIN_TEST_NAMES into -define flags: Odin's test runner reads them only as compile-time
// defines, so the variable alone (CI's, or `ODIN_TEST_RANDOM_SEED=n ./build.sh test` to
// reproduce a failure, `ODIN_TEST_NAMES=server.test_x ./build.sh test server` for one
// test) is ignored.
test_env_defines :: proc() -> []string {
	defines := make([dynamic]string)
	// A leak or a bad free fails the test, naming the allocation (tracking stays on, its default).
	append(&defines, "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true")
	for name in ([]string{"ODIN_TEST_RANDOM_SEED", "ODIN_TEST_THREADS", "ODIN_TEST_NAMES"}) {
		if value, found := os.lookup_env(name, context.allocator); found && len(value) > 0 {
			append(&defines, fmt.aprintf("-define:%s=%s", name, value))
		}
	}
	return defines[:]
}

// TEST_TIMEOUT_FLOOR is the least a package's test run may be given (compile included).
TEST_TIMEOUT_FLOOR :: 10 * time.Minute
// TEST_TIMEOUT_FACTOR times the package's last passing run is its limit when that is longer.
TEST_TIMEOUT_FACTOR :: 10

// test_timeout is the limit for one package's `odin test`: ten times its last passing
// run (recorded beside the binary), at least ten minutes; VX_TEST_TIMEOUT_SECONDS
// overrides it (the hang test uses it).
test_timeout :: proc(last_run: string) -> time.Duration {
	if value, found := os.lookup_env("VX_TEST_TIMEOUT_SECONDS", context.allocator); found {
		if seconds, ok := strconv.parse_int(value); ok && seconds > 0 {
			return time.Duration(seconds) * time.Second
		}
	}
	limit := TEST_TIMEOUT_FLOOR
	if data, err := os.read_entire_file_from_path(last_run, context.allocator); err == nil {
		if seconds, ok := strconv.parse_f64(strings.trim_space(string(data))); ok {
			limit = max(
				limit,
				time.Duration(seconds * f64(TEST_TIMEOUT_FACTOR) * f64(time.Second)),
			)
		}
	}
	return limit
}

// test runs the test packages (or only the named ones) in parallel, the slowest last
// time first (it bounds the whole), each under its time limit.
test :: proc(named: []string) -> bool {
	packages := slice.clone(TEST_PACKAGES)
	if len(named) > 0 {
		for pkg in named {
			if !slice.contains(TEST_PACKAGES, pkg) {
				fmt.eprintfln("build: test: '%s' is not a test package (%v)", pkg, TEST_PACKAGES)
				return false
			}
		}
		packages = slice.clone(named)
	}
	last :: proc(pkg: string) -> f64 {
		data, err := os.read_entire_file_from_path(
			strings.concatenate({test_binary(pkg), ".seconds"}),
			context.temp_allocator,
		)
		if err != nil {return 1e9} 	// never timed: first
		seconds, _ := strconv.parse_f64(strings.trim_space(string(data)))
		return seconds
	}
	slice.sort_by(packages, proc(a, b: string) -> bool {return last(a) > last(b)})
	return test_packages(packages, {}, jobs_width())
}

// smoke runs the smoke suite on one thread: its tests start threads, sockets and clocks of
// their own, and two at once would only compete for the machine.
smoke :: proc() -> bool {
	return test_packages({SMOKE_PACKAGE}, {"-define:ODIN_TEST_THREADS=1"}, 1)
}

// test_binary: where a test package's executable is kept.
test_binary :: proc(pkg: string) -> string {
	return path_join({"build", "test", strings.concatenate({filepath.base(pkg), exe_suffix()})})
}

// test_log: where a test package's output is kept. A package that passed prints one
// line (its test count and time); the whole output is printed only when it failed.
test_log :: proc(pkg: string) -> string {
	return path_join({"build", "test", strings.concatenate({filepath.base(pkg), ".log"})})
}

// test_count: " N tests", from the test runner's last words in the log at path ("" if not there).
test_count :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return ""}
	text := string(data)
	i := strings.last_index(text, "Finished ")
	if i < 0 {return ""}
	fields := strings.fields(text[i:], context.temp_allocator)
	if len(fields) < 3 {return ""}
	return fmt.tprintf(" %s %s", fields[1], strings.trim_right(fields[2], "."))
}

// print_file writes a file's content to stdout (nothing if it cannot be read).
print_file :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err == nil {os.write(os.stdout, data)}
}

// test_packages runs packages' tests, width at a time, each under its time limit; a run
// that outlasts it is killed with its children and reported as a failure naming the
// package. A package whose inputs are unchanged since its binary was built runs that
// binary again instead of compiling it.
test_packages :: proc(packages: []string, extra: []string, width: int) -> bool {
	State :: struct {
		packages: []string,
		steps:    []Odin_Step,
		limits:   []time.Duration,
		ok:       bool,
	}
	state := State {
		packages = packages,
		steps    = make([]Odin_Step, len(packages)),
		limits   = make([]time.Duration, len(packages)),
		ok       = true,
	}
	jobs := make([]limited.Job, len(packages))
	reused := 0
	for pkg, i in packages {
		out := test_binary(pkg)
		os.make_directory_all(filepath.dir(out))
		step := &state.steps[i]
		step^ = Odin_Step {
			name   = strings.concatenate({"test-", filepath.base(pkg)}),
			cmd    = slice.concatenate(
				[][]string {
					{"odin", "test", pkg},
					ODIN_FLAGS,
					COLLECTIONS,
					{strings.concatenate({"-out:", out}), "-keep-executable"},
					test_env_defines(),
					extra,
				},
			),
			output = out,
		}
		cmd: []string
		if odin_step_fresh(step) {
			cmd = slice.clone([]string{out})
			reused += 1
		} else {
			cmd = odin_step_command(step)
		}
		state.limits[i] = test_timeout(strings.concatenate({out, ".seconds"}))
		jobs[i] = limited.Job {
			cmd   = cmd,
			limit = state.limits[i],
			log   = test_log(pkg),
			quiet = true, // (printed by done when the package failed)
		}
	}
	if reused > 0 {fmt.printfln("test   %d unchanged since built: run without compiling", reused)}
	done :: proc(data: rawptr, index: int, result: limited.Run_Result, seconds: f64) {
		state := (^State)(data)
		pkg := state.packages[index]
		step := &state.steps[index]
		// Built in this run (whatever the tests said): the binary is good for its inputs.
		// Not when interrupted: the kill may have come while it was being written.
		if info, err := os.stat(step.output, context.temp_allocator);
		   result != .Interrupted &&
		   err == nil &&
		   step.started != {} &&
		   time.diff(step.started, info.modification_time) >= 0 {
			odin_step_succeeded(step)
		}
		switch result {
		case .Ok:
			_ = os.write_entire_file(
				strings.concatenate({step.output, ".seconds"}),
				fmt.tprintf("%.1f", seconds),
			)
			fmt.printfln("test   %s%s (%.1f s)", pkg, test_count(test_log(pkg)), seconds)
		case .Failed:
			print_file(test_log(pkg))
			fmt.eprintfln("test   %s FAILED (its output: %s)", pkg, test_log(pkg))
			state.ok = false
		case .Timed_Out:
			print_file(test_log(pkg))
			fmt.eprintfln(
				"test   %s FAILED: still running after %.0f s (the limit): killed it and its children",
				pkg,
				time.duration_seconds(state.limits[index]),
			)
			state.ok = false
		case .Interrupted:
			fmt.eprintfln("test   %s interrupted", pkg)
			state.ok = false
		}
	}
	parallel(jobs, width, done, &state)
	return state.ok
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

// check_format compares every source file with odinfmt's output, in parallel. A file
// whose content odinfmt already found formatted (the same odinfmt, the same config) is
// not given to it again: the clean ones' keys are kept in CACHE_DIR/fmt-clean.
check_format :: proc() -> bool {
	if !have_odinfmt() {return false}
	tool := fmt_identity()
	record := path_join({CACHE_DIR, "fmt-clean"})
	known := make(map[string]bool)
	if data, err := os.read_entire_file_from_path(record, context.allocator); err == nil {
		for line in strings.split_lines(string(data)) {if line != "" {known[line] = true}}
	}
	files := odin_files()
	keys := make([]string, len(files))
	todo := make([dynamic]int)
	jobs := make([dynamic]limited.Job)
	for path, i in files {
		k: Key_Builder
		key_begin(&k, "odinfmt")
		key_text(&k, tool)
		key_file(&k, path)
		keys[i], _ = key_end(&k)
		keys[i] = strings.clone(keys[i])
		if keys[i] != "" && keys[i] in known {continue}
		append(&todo, i)
		append(
			&jobs,
			limited.Job {
				cmd = slice.clone([]string{"odinfmt", path}),
				log = job_log(len(jobs)),
				errors = job_log(len(jobs), ".err"),
				quiet = true,
			},
		)
	}
	results := parallel(jobs[:], jobs_width())
	dirty := 0
	clean := make([dynamic]string)
	for key in known {append(&clean, key)}
	for i, j in todo {
		path := files[i]
		formatted, ferr := os.read_entire_file_from_path(jobs[j].log, context.allocator)
		current, cerr := os.read_entire_file_from_path(path, context.allocator)
		if results[j] != .Ok ||
		   ferr != nil ||
		   cerr != nil ||
		   string(formatted) != string(current) {
			fmt.eprintfln("fmt    %s needs formatting", path)
			dirty += 1
			continue
		}
		// Its key is kept only if what odinfmt read is what the key was made from.
		if d, ok := file_digest(path); ok && d == content_digest(current) && keys[i] != "" {
			append(&clean, keys[i])
		}
	}
	// Only the keys of files there now: the record does not grow for ever.
	now := make(map[string]bool)
	for key in keys {now[key] = true}
	text := strings.builder_make()
	for key in clean {if key in now {strings.write_string(&text, key); strings.write_byte(&text, '\n')}}
	os.make_directory_all(CACHE_DIR)
	_ = os.write_entire_file(record, strings.to_string(text))
	if dirty > 0 {
		fmt.eprintfln("fmt    %d file(s) not formatted - run `build fmt`", dirty)
		return false
	}
	fmt.printfln(
		"fmt    clean (%d looked at, %d unchanged since)",
		len(todo),
		len(files) - len(todo),
	)
	return true
}

// fmt_identity: what decides odinfmt's output besides the file: the odinfmt binary
// itself and any odinfmt.json it would read (in the tree or above it).
fmt_identity :: proc() -> string {
	k: Key_Builder
	key_begin(&k, "odinfmt tool")
	exe := ""
	lookup := []string{"sh", "-c", "command -v odinfmt"}
	when ODIN_OS == .Windows {lookup = {"where", "odinfmt"}}
	if out, ok := capture(lookup); ok {
		exe = strings.trim_space(strings.split_lines(out)[0])
	}
	key_text(&k, exe)
	if exe != "" {key_file(&k, exe)}
	dir, _ := os.get_working_directory(context.allocator)
	for {
		config := path_join({dir, "odinfmt.json"})
		if os.exists(config) {key_file(&k, config)}
		parent := filepath.dir(dir)
		if parent == dir {break}
		dir = parent
	}
	key, ok := key_end(&k)
	return strings.clone(key) if ok else "unknown"
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
// build/shaders/<name>.<stage>.spv unless its key (in CACHE_DIR/shaders: a release
// carries build/shaders whole) says it was compiled from these bytes by this
// compiler: the source, every .glsl a shader may #include, the command and glslang.
shaders :: proc() -> bool {
	sources, err := os.read_all_directory_by_path(SHADER_DIR, context.allocator)
	if err != nil {
		fmt.eprintfln("shaders: cannot read %s: %v", SHADER_DIR, err)
		return false
	}
	slice.sort_by(sources, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	glslang, found := glslang_path()
	if !found {return false}
	os.make_directory_all(SHADER_OUT_DIR)
	os.make_directory_all(path_join({CACHE_DIR, "shaders"}))
	ok := true
	compiled := 0
	for src in sources {
		if !slice.contains(SHADER_EXTS, filepath.ext(src.name)) {continue}
		out := path_join({SHADER_OUT_DIR, strings.concatenate({src.name, ".spv"})})
		record := path_join({CACHE_DIR, "shaders", strings.concatenate({src.name, ".key"})})
		cmd := []string {
			glslang,
			"-V",
			"--target-env",
			"vulkan1.3",
			// Debug information: line numbers and the source text (OpLine, OpSource), so
			// a RenderDoc capture shows the GLSL. Not -gV/-gVS: their NonSemantic debug
			// information needs SPV_KHR_relaxed_extended_instruction, which a Vulkan 1.3
			// driver need not support (the validation layer refuses it without).
			"-g",
			"--quiet",
			"-o",
			out,
			src.fullpath,
		}
		k: Key_Builder
		key_begin(&k, "glslang")
		for part in cmd {key_text(&k, part)}
		key_file(&k, glslang)
		key_file(&k, src.fullpath)
		for inc in sources {
			if filepath.ext(inc.name) == ".glsl" {key_file(&k, inc.fullpath)}
		}
		key_listing(&k, SHADER_DIR)
		key, keyed := key_end(&k)
		if saved, rerr := os.read_entire_file_from_path(record, context.allocator);
		   keyed && rerr == nil && string(saved) == key && os.exists(out) {
			continue
		}
		os.remove(record)
		if run(cmd) {
			fmt.printfln("shader %s", src.name)
			compiled += 1
			// The key read before compiling: an edit made meanwhile is compiled next time.
			if keyed {_ = os.write_entire_file(record, key)}
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

AUDIO_SCENARIOS :: []string {
	"burst",
	"cave_walk",
	"title_to_world",
	"stress",
	"music_session",
	"music_hour",
	"all",
}

// audio_baselines runs the audio quality baselines (client/audio_baseline_test.odin,
// files in assets/baselines/audio/): `--accept <scenario|all>` rewrites the
// named baseline from what the scenario sounds like now (review the diff),
// `--wav <dir>` also writes every scenario's master as a WAV to listen to,
// and a scenario's name alone runs only that one.
audio_baselines :: proc(args: []string) -> bool {
	defines := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--accept":
			if i + 1 >= len(args) {
				fmt.eprintln(
					"build: audio --accept <burst|cave_walk|title_to_world|stress|music_session|music_hour|all>",
				)
				return false
			}
			i += 1
			if !slice.contains(AUDIO_SCENARIOS, args[i]) {
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
			if !slice.contains(AUDIO_SCENARIOS, args[i]) || args[i] == "all" {
				fmt.eprintfln(
					"build: audio takes --accept <scenario|all>, --wav <dir> and a scenario to run alone, not '%s'",
					args[i],
				)
				return false
			}
			append(&defines, strings.concatenate({"-define:VX_AUDIO_ONLY=", args[i]}))
		}
	}
	out := path_join({"build", "test", strings.concatenate({"audio-baselines", exe_suffix()})})
	os.make_directory_all(filepath.dir(out))
	cmd := slice.concatenate(
		[][]string {
			{"odin", "test", GAME_PACKAGE},
			ODIN_FLAGS,
			COLLECTIONS,
			{
				strings.concatenate({"-out:", out}),
				"-define:ODIN_TEST_NAMES=client.test_audio_baseline_burst,client.test_audio_baseline_cave_walk,client.test_audio_baseline_title_to_world,client.test_audio_baseline_stress,client.test_audio_baseline_music_session,client.test_music_hour_golden",
			},
			defines[:],
			test_env_defines(),
		},
	)
	return run(cmd)
}

// run_tool builds and runs tools/<name> with args (netdump, replay, sfx).
// run_tool builds tools/<name> and runs it; release: the build lock is let go first
// (the tools a person runs; a benchmark keeps it, so no other run shares its machine).
run_tool :: proc(name: string, args: []string, release := false) -> bool {
	exe := build_tool(name) or_return
	if release {release_build_lock()}
	return run(slice.concatenate([][]string{{exe}, args}))
}

// build_tool builds tools/<name> into build/.
build_tool :: proc(name: string) -> (exe: string, ok: bool) {
	exe = path_join({"build", strings.concatenate({name, exe_suffix()})})
	cmd := slice.concatenate(
	[][]string {
		{"odin", "build", path_join({"tools", name}), strings.concatenate({"-out:", exe})},
		ODIN_FLAGS,
		COLLECTIONS,
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
			"build: bench <scenario>: chunks, telemetry, budgets, ogg (no game), load, views, flight, edits, audio (client/benchmark.odin), server and party (dedicated/bench.odin), or compare",
		)
		return false
	}
	scenario := args[0]
	if scenario == "compare" {return bench_compare(args[1:])}
	if scenario == "chunks" {return run_tool("bench", args[1:])}
	if scenario == "telemetry" || scenario == "budgets" || scenario == "ogg" {
		return run_tool("bench", args)
	}
	build_args := []string{"--release"}
	extra := make([dynamic]string)
	for arg in args[1:] {
		switch {
		case arg == "--profile":
			build_args = {"--release", "--profile"}
		case arg == "--smoke":
			append(&extra, "--smoke")
		case strings.has_prefix(arg, "-size:"):
			append(&extra, "--bench-size", arg[len("-size:"):])
		case:
			fmt.eprintfln(
				"build: bench %s takes --profile, --smoke or -size:WIDTHxHEIGHT, not '%s'",
				scenario,
				arg,
			)
			return false
		}
	}
	exe := build_game(build_args) or_return
	if scenario == "server" || scenario == "party" {
		// The server alone (dedicated/bench.odin).
		exe = path_join({"build", strings.concatenate({SERVER_NAME, exe_suffix()})})
	}
	return run(slice.concatenate([][]string{{exe, "--benchmark", scenario}, extra[:]}))
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

capture :: limited.capture

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
