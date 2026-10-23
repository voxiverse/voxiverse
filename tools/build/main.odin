package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The Voxiverse build driver. build.sh / build.bat hand every argument to it:
//
//	build check                type-check every package and verify formatting
//	build test                 run the unit tests
//	build fmt                  format all sources in place
//	build shaders              compile assets/shaders to SPIR-V (fetches the pinned glslang once)
//	build build [--release | --sanitize]    build the game into build/
//	build run [--release | --sanitize] [-- game args...]
//	build debug [--lldb] [-- game args...]   debug build under gdb/lldb with Odin printers
//
// It runs from the repository root (the wrapper scripts cd there).

// PACKAGES are type-checked by `check`, each on its own so one broken
// package doesn't hide errors in the others.
PACKAGES :: []string {
	"base",
	"font",
	"ui",
	"game",
	"server",
	"platform",
	"gpu",
	"render",
	"client",
	"client/mesh",
	"tools/build",
	"tools/debugger/printer_test",
}
// TEST_PACKAGES contain @(test) procedures.
TEST_PACKAGES :: []string {
	"base",
	"font",
	"ui",
	"game",
	"server",
	"render",
	"client/mesh",
	"client",
}
// SOURCE_DIRS hold first-party Odin code (formatting is checked here).
SOURCE_DIRS :: []string {
	"base",
	"font",
	"ui",
	"game",
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
	case "check":
		ok = check()
	case "test":
		ok = test()
	case "fmt":
		ok = format_sources()
	case "shaders":
		ok = shaders()
	case "build":
		_, ok = build_game(args[1:])
	case "run":
		ok = run_game(args[1:])
	case "debug":
		ok = debug_game(args[1:])
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
	fmt.println("  fmt       format all sources in place (odinfmt)")
	fmt.println("  shaders   compile assets/shaders to SPIR-V (fetches the pinned glslang once)")
	fmt.println(
		"  build     build the game into build/ (debug; --release optimized, --sanitize with AddressSanitizer)",
	)
	fmt.println("  run       build, then run it; arguments after -- go to the game")
	fmt.println(
		"  debug     build, then run it in the debugger (gdb, --lldb, RAD Debugger on Windows)",
	)
}

// build_game compiles shaders and the game. Debug builds keep symbols and
// turn on Vulkan validation; --release optimizes; --sanitize adds
// AddressSanitizer (use-after-free, overflows; best on Linux/macOS);
// --profile writes a Spall trace (combine with --release for real numbers).
build_game :: proc(args: []string) -> (exe: string, ok: bool) {
	release, sanitize, profile := false, false, false
	for arg in args {
		switch arg {
		case "--release":
			release = true
		case "--sanitize":
			sanitize = true
		case "--profile":
			profile = true
		case:
			fmt.eprintfln("build: unknown option '%s'", arg)
			return "", false
		}
	}
	if release && sanitize {
		fmt.eprintln("build: --sanitize is a debug build; drop --release")
		return "", false
	}
	shaders() or_return
	exe = path_join({"build", strings.concatenate({GAME_NAME, exe_suffix()})})
	mode := make([dynamic]string)
	append(&mode, "-o:speed" if release else "-debug")
	if profile {append(&mode, "-define:VX_PROFILE=true")}
	if sanitize {
		append(&mode, "-sanitize:address")
		// Leaks are the tracking allocator's job; LSan would also report
		// GPU drivers' own allocations.
		if _, set := os.lookup_env("ASAN_OPTIONS", context.allocator); !set {
			os.set_env("ASAN_OPTIONS", "detect_leaks=0")
		}
	}
	cmd := slice.concatenate(
		[][]string {
			{"odin", "build", GAME_PACKAGE},
			ODIN_FLAGS,
			mode[:],
			{strings.concatenate({"-out:", exe})},
		},
	)
	run(cmd) or_return
	fmt.printfln(
		"built  %s (%s%s%s)",
		exe,
		"release" if release else "debug",
		" + sanitizer" if sanitize else "",
		" + profiling" if profile else "",
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
	exe, ok := build_game({})
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
	return check_format() && ok
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
	fmt.eprintln("build: odinfmt not found - `odinup install` builds it (with ols)")
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

	ok := true
	compiled := 0
	for src in sources {
		if !slice.contains(SHADER_EXTS, filepath.ext(src.name)) {continue}
		out := path_join({SHADER_OUT_DIR, strings.concatenate({src.name, ".spv"})})
		if dst, serr := os.stat(out, context.allocator);
		   serr == nil && dst.modification_time._nsec >= src.modification_time._nsec {
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
