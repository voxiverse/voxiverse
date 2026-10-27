package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The numbers lint (docs/determinism.md): shared code (game, server, worldgen)
// keeps to base's sin, cos, exp and Rng. A line that is not state says so with a
// trailing `// numbers: <why>`.

DETERMINISM_DIRS :: []string{"common/game", "server", "common/worldgen"}

@(rodata)
BANNED_CALLS := [?]struct {
	call, instead: string,
} {
	{"math.sin(", "base.sin"},
	{"math.cos(", "base.cos"},
	{"math.tan(", "a ratio of base.sin and base.cos"},
	{"math.pow(", "multiplication"},
	{"math.exp(", "base.exp"},
	{"math.fmuladd(", "a * b + c"},
	{"math.sinh(", "base.exp"},
	{"math.cosh(", "base.exp"},
	{"math.tanh(", "base.exp"},
	{"math.gamma(", "a table"},
	{"math.lgamma(", "a table"},
	{"math.erf(", "a table"},
	{"math.erfc(", "a table"},
	{"rand.", "base.Rng"},
}

// lint_numbers returns one message per offending line of one file's text.
lint_numbers :: proc(path, text: string) -> []string {
	found := make([dynamic]string)
	line_no := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_no += 1
		trimmed := strings.trim_left_space(line)
		if strings.has_prefix(trimmed, "//") || strings.contains(line, "// numbers:") {continue}
		for banned in BANNED_CALLS {
			at := strings.index(line, banned.call)
			if at < 0 {continue}
			if banned.call == "rand." && at > 0 && is_ident_char(line[at - 1]) {continue}
			name := strings.trim_right(banned.call, "(")
			append(
				&found,
				fmt.aprintf(
					"%s:%d: %s in shared code: use %s (docs/determinism.md)",
					path,
					line_no,
					name,
					banned.instead,
				),
			)
			break
		}
	}
	return found[:]
}

is_ident_char :: proc(c: u8) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

determinism_lint :: proc() -> bool {
	ok := true
	for dir in DETERMINISM_DIRS {
		w := os.walker_create(dir)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type != .Regular || filepath.ext(info.name) != ".odin" {continue}
			if strings.has_suffix(info.name, "_test.odin") {continue}
			data, err := os.read_entire_file_from_path(info.fullpath, context.allocator)
			if err != nil {
				fmt.eprintfln("lint   %s: unreadable", info.fullpath)
				ok = false
				continue
			}
			for msg in lint_numbers(info.fullpath, string(data)) {
				fmt.eprintln(msg)
				ok = false
			}
		}
	}
	if ok {fmt.println("lint   numbers clean")}
	return ok
}

// ---------------------------------------------------------------------------
// The cross-OS and cross-optimization job (docs/determinism.md)
// ---------------------------------------------------------------------------

DETERMINISM_LOG_DIR :: "build/determinism"
DETERMINISM_TICKS :: 10000

// determinism: `build determinism` runs the scripted session at -o:minimal and
// -o:speed, one log each, and compares them; `build determinism --compare <dir>`
// compares every log in a directory (CI: the six it downloaded).
determinism :: proc(args: []string) -> bool {
	if len(args) == 2 && args[0] == "--compare" {return compare_dir(args[1])}
	if len(args) != 0 {
		fmt.eprintln("build: determinism [--compare <dir>]")
		return false
	}
	os.make_directory_all(DETERMINISM_LOG_DIR)
	os_name := strings.to_lower(fmt.aprintf("%v", ODIN_OS))
	for level in ([]string{"minimal", "speed"}) {
		log_path := path_join({DETERMINISM_LOG_DIR, fmt.aprintf("%s.%s.txt", os_name, level)})
		out := path_join(
			{"build", "test", strings.concatenate({"determinism-", level, exe_suffix()})},
		)
		os.make_directory_all(filepath.dir(out))
		cmd := slice.concatenate(
			[][]string {
				{"odin", "test", "server"},
				ODIN_FLAGS,
				{
					strings.concatenate({"-o:", level}),
					strings.concatenate({"-out:", out}),
					"-define:ODIN_TEST_NAMES=server.test_determinism_session",
					fmt.aprintf("-define:VX_DETERMINISM_TICKS=%d", DETERMINISM_TICKS),
					strings.concatenate({"-define:VX_DETERMINISM_LOG=", log_path}),
				},
			},
		)
		if !run(cmd) {return false}
	}
	return compare_dir(DETERMINISM_LOG_DIR)
}

// compare_dir compares every .txt log in dir with the first in name order.
compare_dir :: proc(dir: string) -> bool {
	names := make([dynamic]string)
	w := os.walker_create(dir)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.type == .Regular && filepath.ext(info.name) == ".txt" {
			append(&names, strings.clone(info.name))
		}
	}
	slice.sort(names[:])
	if len(names) < 2 {
		fmt.eprintfln(
			"determinism: %d log(s) in %s: need at least two to compare",
			len(names),
			dir,
		)
		return false
	}
	texts := make([]string, len(names))
	for name, i in names {
		data, err := os.read_entire_file_from_path(path_join({dir, name}), context.allocator)
		if err != nil {
			fmt.eprintfln("determinism: cannot read %s: %v", name, err)
			return false
		}
		texts[i] = string(data)
	}
	report, ok := compare_logs(names[:], texts)
	if ok {
		fmt.printfln("determinism: %d logs agree (%s)", len(names), strings.join(names[:], ", "))
	} else {
		fmt.eprint(report)
	}
	return ok
}

// compare_logs checks every log against the first: the same header (but for
// the OS and the optimization), the same line for every tick, the same end.
// A difference is named: the first differing tick, which sections differ, and
// the first differing line of the next checkpoint's dump.
compare_logs :: proc(names, texts: []string) -> (report: string, ok: bool) {
	b := strings.builder_make()
	ok = true
	first := strings.split_lines(texts[0], context.temp_allocator)
	for i in 1 ..< len(names) {
		other := strings.split_lines(texts[i], context.temp_allocator)
		if message, same := compare_two(names[0], names[i], first, other); !same {
			fmt.sbprintln(&b, message)
			ok = false
		}
	}
	return strings.to_string(b), ok
}

@(private = "file")
header_key :: proc(line: string) -> string {
	parts := strings.split(line, " ", context.temp_allocator)
	kept := make([dynamic]string, context.temp_allocator)
	for p in parts {
		if strings.has_prefix(p, "os=") || strings.has_prefix(p, "opt=") {continue}
		append(&kept, p)
	}
	return strings.join(kept[:], " ", context.temp_allocator)
}

@(private = "file")
compare_two :: proc(name_a, name_b: string, a, b: []string) -> (message: string, same: bool) {
	if len(a) == 0 || len(b) == 0 {
		return fmt.aprintf("determinism: %s or %s is empty", name_a, name_b), false
	}
	if header_key(a[0]) != header_key(b[0]) {
		return fmt.aprintf(
				"determinism: headers differ:\n  %s: %s\n  %s: %s",
				name_a,
				a[0],
				name_b,
				b[0],
			),
			false
	}
	n := min(len(a), len(b))
	for i in 1 ..< n {
		if strings.has_prefix(a[i], "dump ") ||
		   strings.has_prefix(a[i], "world ") ||
		   strings.has_prefix(a[i], "end ") {break}
		if a[i] == b[i] {continue}
		tick := strings.split(a[i], " ", context.temp_allocator)[0]
		sections := differing_sections(a[i], b[i])
		text := fmt.aprintf(
			"determinism: %s and %s differ at tick %s, in %s",
			name_a,
			name_b,
			tick,
			sections,
		)
		if line, found := next_dump_difference(a[i:], b[i:], tick); found {
			text = fmt.aprintf("%s\n  next dump: %s", text, line)
		}
		return text, false
	}
	// The ticks agree; the checkpoints and the end must too.
	for i in 1 ..< n {
		if a[i] != b[i] {
			return fmt.aprintf(
					"determinism: %s and %s differ after the last tick:\n  %s: %s\n  %s: %s",
					name_a,
					name_b,
					name_a,
					a[i],
					name_b,
					b[i],
				),
				false
		}
	}
	if len(a) != len(b) {
		return fmt.aprintf(
				"determinism: %s has %d lines, %s has %d",
				name_a,
				len(a),
				name_b,
				len(b),
			),
			false
	}
	return "", true
}

@(private = "file")
differing_sections :: proc(a, b: string) -> string {
	pa, pb :=
		strings.split(a, " ", context.temp_allocator),
		strings.split(b, " ", context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for i in 2 ..< min(len(pa), len(pb)) {
		if pa[i] != pb[i] {append(&names, strings.split(pa[i], "=", context.temp_allocator)[0])}
	}
	if len(names) == 0 {return "the root only"}
	return strings.join(names[:], ", ", context.temp_allocator)
}

// next_dump_difference finds the first differing line of the first checkpoint
// dump after the tick, in the lines from there on.
@(private = "file")
next_dump_difference :: proc(a, b: []string, tick: string) -> (line: string, found: bool) {
	start := -1
	for l, i in a {
		if strings.has_prefix(l, "dump ") && l[5:] >= tick && len(l[5:]) >= len(tick) {
			start = i
			break
		}
	}
	if start < 0 || start >= len(b) {return "", false}
	for i in start ..< min(len(a), len(b)) {
		if a[i] != b[i] {
			return fmt.aprintf("%s | %s", a[i], b[i]), true
		}
		if strings.has_prefix(a[i], "world ") {break}
	}
	return "", false
}
