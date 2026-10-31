package fuzz_tool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "common:base/fuzz"

// The fuzz driver (docs/fuzzing.md): one process, one target at a time, supervised by
// `build fuzz` (tools/build/fuzz.odin), which starts it again after a crash.
//
//	fuzz --list
//	fuzz <target> [--seed N] [--cases N | --seconds N] [--regress] [--keep dir] [--out dir] [-- options]
//	fuzz <target> --case <file>
//	fuzz <target> --minimize <file>
main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {usage()}
	targets := every_target()
	if args[0] == "--list" {
		for t in targets {fmt.println(t.name)}
		return
	}
	name := args[0]
	target: ^fuzz.Target
	for &t in targets {
		if t.name == name {target = &t}
	}
	if target == nil {
		fmt.eprintfln("fuzz: no target %q (--list shows them)", name)
		os.exit(2)
	}
	cfg := fuzz.Config {
		seed    = 1,
		seconds = 10,
		out_dir = "build/fuzz",
	}
	case_file, minimize_file: string
	extra: []string
	for i := 1; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			if i^ >= len(args) {usage()}
			return args[i^]
		}
		switch args[i] {
		case "--seed":
			cfg.seed, _ = strconv.parse_u64(next(args, &i))
		case "--cases":
			cfg.cases, _ = strconv.parse_int(next(args, &i))
		case "--seconds":
			cfg.seconds, _ = strconv.parse_f64(next(args, &i))
			cfg.cases = 0
		case "--regress":
			cfg.regress = true
		case "--keep":
			cfg.keep = next(args, &i)
		case "--out":
			cfg.out_dir = next(args, &i)
		case "--case":
			case_file = next(args, &i)
		case "--minimize":
			minimize_file = next(args, &i)
		case "--":
			extra = args[i + 1:]
			i = len(args)
		case:
			usage()
		}
	}
	if len(extra) > 0 {
		// (a target with switches of its own, M51c's `--lua <exe>`, reads them here)
		fmt.eprintfln("fuzz: %s takes no option %q", target.name, extra[0])
		os.exit(2)
	}
	switch {
	case case_file != "":
		res, ok := fuzz.run_file(target, cfg, case_file)
		if !ok {
			fmt.eprintfln("fuzz: cannot read %s", case_file)
			os.exit(2)
		}
		fmt.printfln("signature %016x", res.signature)
		if res.failure != .None {
			fmt.printfln("failure: %v: %s", res.failure, res.detail)
			os.exit(1)
		}
		fmt.println("ok")
	case minimize_file != "":
		minimize(target, cfg, minimize_file)
	case:
		report := fuzz.run_target(target, cfg)
		fmt.printfln(
			"fuzz %s: cases=%d corpus=%d signatures=%d failures=%d",
			target.name,
			report.cases,
			report.corpus,
			report.signatures,
			len(report.failures),
		)
		for f in report.failures {fmt.printfln("FAIL %s", f)}
		if len(report.failures) > 0 {os.exit(1)}
	}
}

usage :: proc() {
	fmt.eprintln(
		"usage: fuzz --list | <target> [--seed N] [--cases N | --seconds N] [--regress] [--keep dir] [--out dir] [-- options] | <target> --case <file> | <target> --minimize <file>",
	)
	os.exit(2)
}

// minimize: the input shrunk while the same failure holds, each candidate run in a child
// process (a crash cannot end this one). Writes <file>.min.
minimize :: proc(target: ^fuzz.Target, cfg: fuzz.Config, file: string) {
	data, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		fmt.eprintfln("fuzz: cannot read %s", file)
		os.exit(2)
	}
	Child :: struct {
		target, tmp: string,
		self:        string,
	}
	child := Child {
		target = target.name,
		tmp    = "build/tmp/fuzz-minimize.bin",
	}
	child.self, _ = os.get_executable_path(context.allocator)
	os.make_directory_all("build/tmp")
	check :: proc(candidate: []u8, user: rawptr) -> string {
		c := (^Child)(user)
		_ = os.write_entire_file_from_bytes(c.tmp, candidate)
		state, stdout, stderr, perr := os.process_exec(
			{command = {c.self, c.target, "--case", c.tmp, "--out", "build/tmp/fuzz-minimize"}},
			context.temp_allocator,
		)
		if perr != nil {return ""}
		for line in strings.split_lines(string(stdout), context.temp_allocator) {
			if strings.has_prefix(line, "failure: ") {return line}
		}
		for line in strings.split_lines(string(stderr), context.temp_allocator) {
			if strings.has_prefix(line, "fuzz-failure: ") {return line}
		}
		if !state.success {return fmt.tprintf("exit %d", state.exit_code)}
		return ""
	}
	want := check(data, &child)
	if want == "" {
		fmt.eprintfln("fuzz: %s does not fail on %s", file, target.name)
		os.exit(1)
	}
	small := fuzz.minimize(data, check, &child)
	out := strings.concatenate({file, ".min"})
	_ = os.write_entire_file_from_bytes(out, small)
	fmt.printfln("%s: %d bytes -> %d (%s)", out, len(data), len(small), want)
}
