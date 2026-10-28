package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The Voxiverse build driver. build.sh / build.bat hand every argument to
// it; its commands are listed by usage (`build help`). It runs from the
// repository root (the wrapper scripts cd there).

// PACKAGES are type-checked by `check`, each on its own so one broken
// package doesn't hide errors in the others.
PACKAGES :: []string {
	"base",
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
	"client/platform",
	"dedicated",
	"tools/build",
	"tools/netdump",
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
}
// TEST_PACKAGES contain @(test) procedures.
TEST_PACKAGES :: []string {
	"base",
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
	"base",
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
	     "music",
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
	case "netdump", "audiodump", "replay", "sfx", "music", "worldmap", "analytics", "schema":
		ok = run_tool(args[0], args[1:])
	case "packs":
		ok = run_tool("packcheck", args[1:])
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
	fmt.println(
		"  check     type-check every package (-vet -strict-style), build objects for the other Tier 1 targets, verify formatting",
	)
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
	fmt.println(
		"  schema    rewrite the Wireshark dissector's generated schema block from the game's state kinds",
	)
	fmt.println(
		"  packs     check content packs: the base pack plus the given pack directories, in order",
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
	ok = check_cross() && ok
	return determinism_lint() && check_format() && check_no_binaries() && ok
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

// check_cross builds the game, the server and every test package as objects for
// each Tier 1 target that is not the host, so code that only compiles on the host
// (a variable used only inside `when ODIN_OS == .Linux`) fails here, not in CI.
// Objects only: nothing links or runs. Windows needs -windows-sdk-root to build
// objects without the SDK (any existing directory will do). `odin test` takes no
// such flag and refuses a Windows target without the real SDK, so Windows test
// packages are checked natively on the Windows CI runner only; macOS ones are
// cross-built here.
check_cross :: proc() -> bool {
	ok := true
	if !ensure_foreign_miniaudio() {return false}
	host := host_target()
	for target in TIER1_TARGETS {
		if target == host {continue}
		windows := strings.has_prefix(target, "windows")
		cross_flags := slice.concatenate(
			[][]string{{strings.concatenate({"-target:", target}), "-build-mode:obj"}, ODIN_FLAGS},
		)
		if windows {
			cross_flags = slice.concatenate([][]string{cross_flags, {"-windows-sdk-root:."}})
		}
		jobs := make([dynamic][2]string)
		for pkg in ([]string{GAME_PACKAGE, SERVER_PACKAGE}) {
			append(&jobs, [2]string{"build", pkg})
		}
		if !windows {
			for pkg in TEST_PACKAGES {
				append(&jobs, [2]string{"test", pkg})
			}
		}
		for job in jobs {
			out := path_join({"build", "cross", target, job[0], filepath.base(job[1])})
			os.make_directory_all(filepath.dir(out))
			cmd := slice.concatenate(
				[][]string {
					{"odin", job[0], job[1]},
					cross_flags,
					{strings.concatenate({"-out:", out})},
				},
			)
			if run(cmd) {
				fmt.printfln("cross  %s %s %s", target, job[0], job[1])
			} else {
				fmt.eprintfln("cross  %s %s %s FAILED", target, job[0], job[1])
				ok = false
			}
		}
	}
	return ok
}

// check_no_binaries fails if git tracks an executable (ELF, PE or Mach-O): build
// output belongs in build/, and one was once committed at the root by mistake.
check_no_binaries :: proc() -> bool {
	listing, ok := capture({"git", "ls-files", "-z"})
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
			fmt.eprintfln("binary %s is an executable: build output goes in build/", path)
			found += 1
		}
	}
	if found > 0 {return false}
	fmt.println("binary none tracked")
	return true
}

// test_env_defines turns the environment's ODIN_TEST_RANDOM_SEED and ODIN_TEST_THREADS into
// -define flags: Odin's test runner reads both only as compile-time defines, so the variable
// alone (CI's, or `ODIN_TEST_RANDOM_SEED=n ./build.sh test` to reproduce a failure) is ignored.
test_env_defines :: proc() -> []string {
	defines := make([dynamic]string)
	// A leak or a bad free fails the test, naming the allocation (tracking stays on, its default).
	append(&defines, "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true")
	for name in ([]string{"ODIN_TEST_RANDOM_SEED", "ODIN_TEST_THREADS"}) {
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

test :: proc() -> bool {
	ok := true
	for pkg in TEST_PACKAGES {
		ok = test_package(pkg) && ok
	}
	return ok
}

// test_package runs one package's tests under the time limit; a run that outlasts it is
// killed with its children and reported as a failure naming the package.
test_package :: proc(pkg: string) -> bool {
	out := path_join({"build", "test", strings.concatenate({filepath.base(pkg), exe_suffix()})})
	last_run := strings.concatenate({out, ".seconds"})
	cmd := slice.concatenate(
		[][]string {
			{"odin", "test", pkg},
			ODIN_FLAGS,
			{strings.concatenate({"-out:", out})},
			test_env_defines(),
		},
	)
	os.make_directory_all(filepath.dir(out))
	limit := test_timeout(last_run)
	start := time.tick_now()
	result := run_limited(cmd, limit)
	took := time.duration_seconds(time.tick_since(start))
	switch result {
	case .Ok:
		_ = os.write_entire_file(last_run, fmt.tprintf("%.1f", took))
		return true
	case .Failed:
		return false
	case .Timed_Out:
		fmt.eprintfln(
			"test   %s FAILED: still running after %.0f s (the limit): killed it and its children",
			pkg,
			time.duration_seconds(limit),
		)
		return false
	}
	return false
}

Run_Result :: enum {
	Ok,
	Failed, // exited nonzero, or could not start
	Timed_Out,
}

// run_limited is run with a time limit: a command still going at the limit is killed
// together with everything it started.
run_limited :: proc(cmd: []string, limit: time.Duration) -> Run_Result {
	desc := os.Process_Desc {
		command = cmd,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	child, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("build: could not start '%s': %v", cmd[0], err)
		return .Failed
	}
	state, werr := os.process_wait(child, limit)
	if werr == nil {
		return .Ok if state.exited && state.exit_code == 0 else .Failed
	}
	kill_tree(child.pid)
	_, _ = os.process_wait(child)
	return .Timed_Out
}

// kill_tree kills a process and every descendant (each is frozen before its children
// are listed, so none can start more while the tree is walked).
kill_tree :: proc(pid: int) {
	context.allocator = context.temp_allocator // capture's output
	when ODIN_OS == .Windows {
		_, _ = capture({"taskkill", "/T", "/F", "/PID", fmt.tprint(pid)})
	} else {
		pids := make([dynamic]int, context.temp_allocator)
		append(&pids, pid)
		for i := 0; i < len(pids); i += 1 {
			_, _ = capture({"kill", "-STOP", fmt.tprint(pids[i])})
			out, _ := capture({"pgrep", "-P", fmt.tprint(pids[i])})
			for line in strings.split_lines(out, context.temp_allocator) {
				if child, ok := strconv.parse_int(strings.trim_space(line)); ok {
					append(&pids, child)
				}
			}
		}
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "kill", "-KILL")
		for p in pids {append(&cmd, fmt.tprint(p))}
		_, _ = capture(cmd[:])
	}
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
			{
				strings.concatenate({"-out:", out}),
				"-define:ODIN_TEST_NAMES=client.test_audio_baselines,client.test_music_hour_golden",
			},
			defines[:],
			test_env_defines(),
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
