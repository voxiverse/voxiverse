package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// `build fuzz`: builds tools/fuzz and supervises it (docs/fuzzing.md). The driver runs one
// target at a time in a process of its own, so a crash ends that process only: it is recorded
// (the harness saved the input under build/fuzz/<target>/) and the target starts again with
// the next seed.
//
//	build fuzz --list
//	build fuzz [<target>...] [--seed N] [--cases N | --seconds N] [--sanitize] [--keep <dir>]
//	build fuzz <target> --case <file>
//	build fuzz <target> --minimize <file>
//	build fuzz --smoke        every target: 2 000 cases at seed 84, then its regression files
//	options after `--` go to the targets named (a target refuses one it does not know)

FUZZ_SMOKE_SEED :: 84
FUZZ_SMOKE_CASES :: 2000
FUZZ_RESTARTS :: 20 // crashes of one target the supervisor starts it again after

fuzz :: proc(args: []string) -> bool {
	seed, cases, seconds := u64(1), 0, f64(10)
	sanitize, smoke, list := false, false, false
	names := make([dynamic]string)
	passthrough := make([dynamic]string) // --case, --minimize, --keep, -- ...
	single := ""
	for i := 0; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			if i^ >= len(args) {
				fmt.eprintln("build: fuzz: an option is missing its value")
				os.exit(1)
			}
			return args[i^]
		}
		switch args[i] {
		case "--list":
			list = true
		case "--smoke":
			smoke = true
		case "--sanitize":
			sanitize = true
		case "--seed":
			seed, _ = strconv.parse_u64(next(args, &i))
		case "--cases":
			cases, _ = strconv.parse_int(next(args, &i))
		case "--seconds":
			seconds, _ = strconv.parse_f64(next(args, &i))
			cases = 0
		case "--case", "--minimize", "--keep":
			append(&passthrough, args[i], next(args, &i))
			single = args[i - 1]
		case "--":
			append(&passthrough, ..args[i:])
			i = len(args)
		case:
			if strings.has_prefix(args[i], "--") {
				fmt.eprintfln("build: fuzz: unknown option %s", args[i])
				return false
			}
			append(&names, args[i])
		}
	}
	if sanitize && ODIN_OS != .Linux {
		fmt.eprintln("build: fuzz --sanitize is for Linux (AddressSanitizer)")
		return false
	}
	exe := build_fuzz_driver(sanitize) or_return
	release_build_lock()
	if sanitize {
		// (the harness checks its own leaks; the sanitizer's end-of-run report would name
		// what a run keeps on purpose: the registry the targets share)
		os.set_env("ASAN_OPTIONS", "detect_leaks=0")
	}
	if list {return run({exe, "--list"})}
	targets := make([dynamic]string)
	{
		out := fuzz_list(exe) or_return
		for t in out {
			if len(names) == 0 || slice.contains(names[:], t) {append(&targets, t)}
		}
		for n in names {
			if !slice.contains(out, n) {
				fmt.eprintfln("build: fuzz: no target %q (--list shows them)", n)
				return false
			}
		}
	}
	if single != "" {
		if len(names) != 1 {
			fmt.eprintfln("build: fuzz: %s takes one target", single)
			return false
		}
		return run(slice.concatenate([][]string{{exe, names[0]}, passthrough[:]}))
	}
	failures := make([dynamic]string)
	started := time.tick_now()
	for target in targets {
		if smoke {
			code := run_code(
				{
					exe,
					target,
					"--seed",
					fmt.tprint(FUZZ_SMOKE_SEED),
					"--cases",
					fmt.tprint(FUZZ_SMOKE_CASES),
					"--regress",
				},
			)
			if code != 0 {append(&failures, fmt.tprintf("%s: exit %d", target, code))}
			continue
		}
		budget := time.tick_now()
		for attempt in 0 ..< FUZZ_RESTARTS {
			cmd := slice.concatenate(
				[][]string {
					{exe, target, "--seed", fmt.tprint(seed + u64(attempt))},
					{"--cases", fmt.tprint(cases)} if cases > 0 else {},
					{"--seconds", fmt.tprint(max(seconds - time.duration_seconds(time.tick_since(budget)), 1))} if cases == 0 else {},
					{"--regress"} if attempt == 0 else {},
					passthrough[:],
				},
			)
			code := run_code(cmd)
			if code == 0 {break}
			if code == 1 {
				append(&failures, fmt.tprintf("%s: failures (above)", target))
				break
			}
			append(
				&failures,
				fmt.tprintf(
					"%s: crashed (exit %d, seed %d); its input is under build/fuzz/%s/",
					target,
					code,
					seed + u64(attempt),
					target,
				),
			)
			if cases == 0 && time.duration_seconds(time.tick_since(budget)) >= seconds {break}
			fmt.printfln(
				"build: fuzz: %s starts again at seed %d",
				target,
				seed + u64(attempt) + 1,
			)
		}
	}
	fmt.printfln(
		"fuzz: %d targets in %.0f s",
		len(targets),
		time.duration_seconds(time.tick_since(started)),
	)
	if len(failures) > 0 {
		for f in failures {fmt.eprintfln("fuzz FAILED: %s", f)}
		return false
	}
	return true
}

// build_fuzz_driver builds tools/fuzz (its executable is build/fuzz-driver: build/fuzz/ holds
// what a run finds).
build_fuzz_driver :: proc(sanitize: bool) -> (exe: string, ok: bool) {
	exe = path_join(
		{
			"build",
			strings.concatenate({"fuzz-driver-asan" if sanitize else "fuzz-driver", exe_suffix()}),
		},
	)
	cmd := slice.concatenate(
		[][]string {
			{"odin", "build", "tools/fuzz", strings.concatenate({"-out:", exe})},
			ODIN_FLAGS,
			COLLECTIONS,
			{"-o:speed", "-debug"},
			{"-sanitize:address"} if sanitize else {},
		},
	)
	return exe, run(cmd)
}

// fuzz_list: the driver's target names.
fuzz_list :: proc(exe: string) -> (names: []string, ok: bool) {
	state, stdout, _, err := os.process_exec({command = {exe, "--list"}}, context.allocator)
	if err != nil || !state.success {return nil, false}
	return strings.split_lines(strings.trim_space(string(stdout))), true
}

// run_code runs cmd with the terminal's streams and returns its exit code (-1: it did not
// start, or a signal ended it).
run_code :: proc(cmd: []string) -> int {
	desc := os.Process_Desc {
		command = cmd,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	child, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("build: could not start '%s': %v", cmd[0], err)
		return -1
	}
	state, werr := os.process_wait(child)
	if werr != nil || !state.exited {return -1}
	return state.exit_code
}
