package script

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strconv"
import "core:strings"

import "common:base"
import "common:base/fuzz"

// The fuzzers: four targets of the fuzz harness (`build fuzz script.source
// script.generated script.bytecode script.snapshot`, docs/fuzzing.md). Their signature is
// the error kind, the compile phase or fault reached, and the instruction count's bucket.
//
//   - script.source: mutated sources through the compiler; a module that compiles runs with
//     a slice of 10 000 units in 1 MiB; every proto passes verify_proto (Config.verify).
//   - script.generated: generated programs run straight, in slices of random sizes 1..97,
//     in slices of 13 with a snapshot, vm_destroy and restore at every suspension (the
//     first 200, then every 2 000th), and
//     under gc_stress: the outputs equal, the heaps of the first three equal. With
//     `-- --lua <exe>` an unmutated generated program (its first line's hash holds) is also
//     run by that Lua and must print the same.
//   - script.bytecode: a compiled program's instructions mutated (from the input's hash):
//     verify_proto refuses them, or they run to any end without a crash.
//   - script.snapshot: snapshots of generated programs at a suspension, mutated, through
//     restore_unchecked: refused, or restored to a VM that runs to any end.

FUZZ_MEMORY :: 1 << 20
FUZZ_SLICE :: 10_000
FUZZ_RUN_UNITS :: 2_000_000 // the most a case's run may use
FUZZ_RESTORE_EVERY_FIRST :: 200
FUZZ_RESTORE_THEN :: 2000

FUZZ_TOKENS :: [?]string {
	"and",
	"break",
	"continue",
	"do",
	"else",
	"elseif",
	"end",
	"false",
	"for",
	"function",
	"if",
	"in",
	"local",
	"nil",
	"not",
	"or",
	"repeat",
	"return",
	"then",
	"true",
	"until",
	"while",
	"+",
	"-",
	"*",
	"/",
	"//",
	"%",
	"^",
	"#",
	"&",
	"~",
	"|",
	"<<",
	">>",
	"==",
	"~=",
	"<=",
	">=",
	"<",
	">",
	"=",
	"+=",
	"-=",
	"..=",
	"(",
	")",
	"{",
	"}",
	"[",
	"]",
	"::",
	";",
	":",
	",",
	".",
	"..",
	"...",
	"[[",
	"]]",
	"--",
	"\"",
	"'",
	"0x",
	"1e308",
	"9223372036854775807",
	"math.mininteger",
	"pcall",
	"error",
	"setmetatable",
	"coroutine.wrap",
	"coroutine.yield",
	"__index",
	"__add",
	"__call",
	"string.rep",
	"select('#', ...)",
}

script_fuzz_targets :: proc() -> []fuzz.Target {
	@(static) targets := [?]fuzz.Target {
		{
			name = "script.source",
			run = fuzz_source,
			seeds = "common/script/testdata/fuzz/script.source",
			dictionary = {
				"local",
				"function",
				"end",
				"do",
				"then",
				"(",
				")",
				"{",
				"}",
				"[[",
				"..",
				"...",
				"=",
				"+=",
				"..=",
				"continue",
				"goto",
				"return",
				"::",
				"\"",
				"1e308",
				"0x",
				"9223372036854775808",
			},
			max_len = 16 << 10,
			generate = fuzz_generate_source,
			alloc_cap = 16 << 20,
			shrink = fuzz_shrink_source,
		},
		{
			name = "script.generated",
			run = fuzz_generated,
			seeds = "common/script/testdata/fuzz/script.generated",
			dictionary = {
				"emit(",
				"pcall(",
				"coroutine.yield(",
				"setmetatable(",
				"end",
				"local",
				"nil",
				"math.mininteger",
				"-0.0",
				"0/0",
				"1 // 0",
			},
			max_len = 16 << 10,
			generate = fuzz_generate_program,
			alloc_cap = 16 << 20,
			check_options = fuzz_check_lua,
			run_options = fuzz_generated_lua,
			shrink = fuzz_shrink_source,
		},
		{
			name = "script.bytecode",
			run = fuzz_bytecode,
			seeds = "common/script/testdata/fuzz/script.bytecode",
			dictionary = {"function", "end", "return", "...", "local", "for", "pcall("},
			max_len = 16 << 10,
			generate = fuzz_generate_program,
			alloc_cap = 16 << 20,
		},
		{
			name = "script.snapshot",
			run = fuzz_snapshot,
			seeds = "common/script/testdata/fuzz/script.snapshot",
			dictionary = {"VXSS"},
			max_len = FUZZ_MEMORY + 64 << 10,
			generate = fuzz_generate_snapshot,
			alloc_cap = 64 << 20,
		},
	}
	return targets[:]
}

@(private = "file")
fuzz_config :: proc(gc_stress := false) -> Config {
	cfg := default_config()
	cfg.limits.memory = FUZZ_MEMORY
	cfg.limits.run_instructions = FUZZ_RUN_UNITS
	cfg.verify = true
	cfg.gc_stress = gc_stress
	return cfg
}

// The signature: the error kind, the fault, how far it got, the units' bucket.
@(private = "file")
fuzz_signature :: proc(phase: u64, e: Script_Error, units: i64) -> u64 {
	return fuzz.sig_mix(
		phase,
		u64(e.kind),
		u64(e.limit),
		fuzz.sig_text(e.message),
		fuzz.sig_bucket(int(units)),
	)
}

// --- script.source

fuzz_source :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	src := string(data)
	vm, ve := vm_create(fuzz_config(), allocator)
	if ve.kind != .None {
		fuzz.fail("vm_create: %s", ve.message)
		return 0
	}
	defer vm_destroy(vm)
	fn, ce := compile(vm, src, "fuzz", allocator = context.temp_allocator)
	if ce.kind != .None {
		if ce.kind != .Syntax {
			// (a memory fault compiling a huge input is fine; the verifier's refusal is not)
			if ce.kind != .Limit {fuzz.fail("compile: %v: %s", ce.kind, ce.message)}
			return fuzz_signature(1, ce, 0)
		}
		if ce.message == "" {fuzz.fail("a syntax error without a message")}
		lines := source_line_count(src)
		if ce.line < 1 || int(ce.line) > lines || ce.column < 1 {
			fuzz.fail("a syntax error at %d:%d of a %d-line source", ce.line, ce.column, lines)
		}
		return fuzz_signature(1, ce, 0)
	}
	r := call(vm, fn, nil, FUZZ_SLICE, context.temp_allocator)
	if r.status == .Suspended || r.status == .Yielded {abort(vm)}
	if ok, problem := heap_check(vm); !ok {fuzz.fail("heap_check: %s", problem)}
	return fuzz_signature(2 + u64(r.status), r.error, vm.run_used)
}

// source_line_count: the lines of src as the lexer counts them (\n, \r, \r\n and \n\r each
// end one, as in Lua).
source_line_count :: proc(src: string) -> int {
	lines := 1
	for i := 0; i < len(src); i += 1 {
		c := src[i]
		if c != '\n' && c != '\r' {continue}
		lines += 1
		if i + 1 < len(src) &&
		   (src[i + 1] == '\n' || src[i + 1] == '\r') &&
		   src[i + 1] != c {i += 1}
	}
	return lines
}

// fuzz_generate_source: a conformance file or the prelude, changed by one to four of the
// mutations a source fuzzer wants (a token inserted, a span deleted, doubled, spliced from
// another file, the end cut off, a span nested 300 times in ( ) or do end).
fuzz_generate_source :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	pick :: proc(rng: ^base.Rng) -> string {
		n := len(FUZZ_CORPUS)
		i := base.rng_int_max(rng, n + 1)
		if i == n {return PRELUDE}
		return string(FUZZ_CORPUS[i].data)
	}
	tokens := FUZZ_TOKENS
	append(out, pick(rng))
	for _ in 0 ..< 1 + base.rng_int_max(rng, 4) {
		n := len(out)
		if n == 0 {
			append(out, tokens[base.rng_int_max(rng, len(tokens))])
			continue
		}
		at := base.rng_int_max(rng, n)
		span := min(1 + base.rng_int_max(rng, 64), n - at)
		switch base.rng_int_max(rng, 7) {
		case 0:
			out[at] ~= u8(1 << uint(base.rng_int_max(rng, 8)))
		case 1:
			tok := tokens[base.rng_int_max(rng, len(tokens))]
			inject_at(out, at, " ")
			inject_at(out, at + 1, tok)
		case 2:
			remove_range(out, at, at + span)
		case 3:
			chunk := make([]u8, span, context.temp_allocator)
			copy(chunk, out[at:at + span])
			inject_at(out, at, ..chunk)
		case 4:
			other := pick(rng)
			if len(other) == 0 {break}
			o := base.rng_int_max(rng, len(other))
			inject_at(out, at, other[o:o + min(span, len(other) - o)])
		case 5:
			resize(out, at)
		case 6:
			open, close := "(", ")"
			if base.rng_int_max(rng, 2) == 0 {open, close = "do ", " end"}
			inner := strings.clone(string(out[at:at + span]), context.temp_allocator)
			b := strings.builder_make(context.temp_allocator)
			for _ in 0 ..< 300 {strings.write_string(&b, open)}
			strings.write_string(&b, inner)
			for _ in 0 ..< 300 {strings.write_string(&b, close)}
			remove_range(out, at, at + span)
			inject_at(out, at, strings.to_string(b))
		}
	}
}

// fuzz_shrink_source: the target's own minimizer for sources: whole lines removed, then
// bracketed expressions replaced by `nil`, while the failure holds.
fuzz_shrink_source :: proc(data: []u8, check: fuzz.Check_Proc, user: rawptr) -> []u8 {
	want := check(data, user)
	cur := strings.clone(string(data))
	if want == "" {return transmute([]u8)cur}
	try :: proc(
		cur: ^string,
		cand: string,
		want: string,
		check: fuzz.Check_Proc,
		user: rawptr,
	) -> bool {
		if check(transmute([]u8)cand, user) != want {return false}
		delete(cur^)
		cur^ = strings.clone(cand)
		return true
	}
	changed := true
	for changed {
		changed = false
		// Lines: halves first, then one at a time.
		lines := strings.split_lines(cur, context.temp_allocator)
		for size := max(len(lines) / 2, 1); size >= 1; size /= 2 {
			at := 0
			for at < len(lines) {
				n := min(size, len(lines) - at)
				rest := make([dynamic]string, context.temp_allocator)
				append(&rest, ..lines[:at])
				append(&rest, ..lines[at + n:])
				cand := strings.join(rest[:], "\n", context.temp_allocator)
				if try(&cur, cand, want, check, user) {
					lines = strings.split_lines(cur, context.temp_allocator)
					changed = true
				} else {
					at += n
				}
			}
			if size == 1 {break}
		}
		// Expressions: a bracketed span replaced by nil.
		for i := 0; i < len(cur); i += 1 {
			if cur[i] != '(' && cur[i] != '{' && cur[i] != '[' {continue}
			depth := 0
			j := i
			for ; j < len(cur); j += 1 {
				switch cur[j] {
				case '(', '{', '[':
					depth += 1
				case ')', '}', ']':
					depth -= 1
				}
				if depth == 0 {break}
			}
			if j >= len(cur) || j - i <= 4 {continue} 	// (nothing to gain: "(nil)" stays)
			cand := strings.concatenate({cur[:i + 1], "nil", cur[j:]}, context.temp_allocator)
			if try(&cur, cand, want, check, user) {changed = true}
		}
		free_all(context.temp_allocator)
	}
	return transmute([]u8)cur
}

// --- script.generated

Fuzz_Run :: struct {
	output: string,
	status: Run_Status,
	units:  i64,
	heap:   u64,
	failed: string, // a property broken on the way (heap_check, a refused restore)
}

// fuzz_run_program runs src: slice 0 straight; otherwise in slices of `slice` units (a
// slice of -1: random sizes 1..97 from rng), with a snapshot and restore at every
// suspension when snapshots is set.
fuzz_run_program :: proc(
	src: string,
	slice: int,
	rng: ^base.Rng,
	snapshots: bool,
	gc_stress: bool,
	allocator: runtime.Allocator,
) -> (
	r: Fuzz_Run,
	compiled: bool,
) {
	cfg := fuzz_config(gc_stress)
	vm, ve := vm_create(cfg, allocator)
	if ve.kind != .None {
		r.failed = fmt.tprintf("vm_create: %s", ve.message)
		return
	}
	defer vm_destroy(vm)
	fn, ce := compile(vm, src, "gen", allocator = context.temp_allocator)
	if ce.kind != .None {
		if ce.kind == .Runtime {r.failed = ce.message}
		return
	}
	compiled = true
	next_slice :: proc(slice: int, rng: ^base.Rng) -> i64 {
		if slice == 0 {return max(i64)}
		if slice < 0 {return i64(1 + base.rng_int_max(rng, 97))}
		return i64(slice)
	}
	out := strings.builder_make(context.temp_allocator)
	res := call(vm, fn, nil, next_slice(slice, rng), context.temp_allocator)
	suspensions := 0
	for res.status == .Suspended {
		strings.write_string(&out, output_take(vm, context.temp_allocator))
		suspensions += 1
		// Every suspension for the first FUZZ_RESTORE_EVERY_FIRST, then every
		// FUZZ_RESTORE_THEN-th: a mutated program may run its 2 000 000 units, and a restore
		// with its validation costs a millisecond in the debug build the suite runs.
		if snapshots &&
		   (suspensions <= FUZZ_RESTORE_EVERY_FIRST || suspensions % FUZZ_RESTORE_THEN == 0) {
			bytes := snapshot(vm, context.temp_allocator)
			vm_destroy(vm)
			re: Script_Error
			vm, re = restore(bytes, cfg, allocator)
			if re.kind != .None {
				r.failed = fmt.tprintf("restore: %s", re.message)
				vm, _ = vm_create(cfg, allocator) // (for the deferred destroy)
				return
			}
		}
		res = resume(vm, nil, next_slice(slice, rng), context.temp_allocator)
	}
	if res.status == .Yielded {abort(vm)}
	strings.write_string(&out, output_take(vm, context.temp_allocator))
	r.output = strings.to_string(out)
	r.status = res.status
	r.units = vm.run_used
	r.heap = heap_hash(vm)
	if ok, problem := heap_check(vm); !ok {r.failed = fmt.tprintf("heap_check: %s", problem)}
	return
}

fuzz_generated :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	return fuzz_generated_lua(data, nil, allocator)
}

fuzz_check_lua :: proc(options: []string) -> string {
	if len(options) == 2 && options[0] == "--lua" {return ""}
	return "the options are `--lua <exe>`"
}

fuzz_generated_lua :: proc(data: []u8, options: []string, allocator: runtime.Allocator) -> u64 {
	src := string(data)
	rng := base.rng_make(xxhash.XXH64(data))
	straight, ok := fuzz_run_program(src, 0, &rng, false, false, allocator)
	if straight.failed != "" {fuzz.fail("straight: %s", straight.failed)}
	if !ok {return fuzz.sig_mix(1, u64(len(data) > 0))}
	runs := [?]struct {
		name:      string,
		slice:     int,
		snapshots: bool,
		gc_stress: bool,
		same_heap: bool,
	} {
		{"in slices of 1..97", -1, false, false, true},
		{"restored at every slice of 13", 13, true, false, true},
		{"under gc_stress", 0, false, true, false},
	}
	for run in runs {
		r, _ := fuzz_run_program(src, run.slice, &rng, run.snapshots, run.gc_stress, allocator)
		if r.failed != "" {fuzz.fail("%s: %s", run.name, r.failed)}
		// Whether a run hits the memory limit may depend on the collector's timing.
		if run.gc_stress && (straight.status == .Error || r.status == .Error) {continue}
		if r.output != straight.output || r.status != straight.status {
			fuzz.fail(
				"%s: printed %q (%v); straight %q (%v)",
				run.name,
				r.output,
				r.status,
				straight.output,
				straight.status,
			)
		} else if run.same_heap && r.heap != straight.heap {
			fuzz.fail("%s: the heap differs", run.name)
		}
	}
	if len(options) == 2 && straight.status == .Done && fuzz_generated_intact(src) {
		if problem := fuzz_compare_lua(options[1], src, straight.output); problem != "" {
			fuzz.fail("%s", problem)
		}
	}
	return fuzz.sig_mix(
		2,
		u64(straight.status),
		fuzz.sig_bucket(int(straight.units)),
		fuzz.sig_bucket(len(straight.output)),
	)
}

// A generated program's first line is "-- vxs-gen <XXH64 of the rest>": while it holds, the
// program is in the common subset and a reference Lua must print what we print.
@(private = "file")
GEN_MARK :: "-- vxs-gen "

fuzz_generated_intact :: proc(src: string) -> bool {
	if !strings.has_prefix(src, GEN_MARK) {return false}
	nl := strings.index_byte(src, '\n')
	if nl < 0 {return false}
	want, ok := strconv.parse_u64_of_base(src[len(GEN_MARK):nl], 16)
	return ok && want == xxhash.XXH64(transmute([]u8)src[nl + 1:])
}

fuzz_compare_lua :: proc(lua, src, ours: string) -> string {
	os.make_directory_all("build/tmp/fuzz")
	path := "build/tmp/fuzz/script.generated.lua"
	if os.write_entire_file_from_bytes(path, transmute([]u8)src) != nil {
		return fmt.tprintf("cannot write %s", path)
	}
	state, stdout, stderr, err := os.process_exec({command = {lua, path}}, context.temp_allocator)
	if err != nil {return fmt.tprintf("cannot run %s: %v", lua, err)}
	if !state.success {return fmt.tprintf("%s failed: %s", lua, string(stderr))}
	theirs, _ := strings.replace_all(string(stdout), "\r\n", "\n", context.temp_allocator)
	if theirs != ours {return fmt.tprintf("we print %q; %s prints %q", ours, lua, theirs)}
	return ""
}

// The generator: well-formed programs in the common subset of Lua 5.4 and ours, every loop
// bounded, the locals tracked with their types. The body runs inside pcall; the end prints
// a digest of the values met and whether the body raised.

@(private = "file")
Gen_Type :: enum {
	Int,
	Float,
	Str,
	Tab,
	Fun,
}

@(private = "file")
Gen_Local :: struct {
	name: string,
	type: Gen_Type,
}

@(private = "file")
Gen :: struct {
	rng:    ^base.Rng,
	b:      strings.Builder,
	locals: [dynamic]Gen_Local,
	names:  int,
	depth:  int,
	budget: int, // statements left
}

@(private = "file")
gen_int :: proc(g: ^Gen, n: int) -> int {return base.rng_int_max(g.rng, n)}

@(private = "file")
gen_name :: proc(g: ^Gen, prefix: string) -> string {
	g.names += 1
	return fmt.tprintf("%s%d", prefix, g.names)
}

@(private = "file")
gen_pick :: proc(g: ^Gen, t: Gen_Type) -> (string, bool) {
	count := 0
	for l in g.locals {if l.type == t {count += 1}}
	if count == 0 {return "", false}
	k := gen_int(g, count)
	for l in g.locals {
		if l.type != t {continue}
		if k == 0 {return l.name, true}
		k -= 1
	}
	return "", false
}

@(private = "file")
gen_expr :: proc(g: ^Gen, t: Gen_Type, depth: int) -> string {
	if name, ok := gen_pick(g, t); ok && gen_int(g, 3) == 0 {return name}
	leaf := depth <= 0 || gen_int(g, 3) == 0
	switch t {
	case .Int:
		if leaf {
			edges := [?]string {
				"0",
				"1",
				"-1",
				"7",
				"-3",
				"255",
				"math.maxinteger",
				"math.mininteger",
				"1000000007",
			}
			return edges[gen_int(g, len(edges))]
		}
		a, b := gen_expr(g, .Int, depth - 1), gen_expr(g, .Int, depth - 1)
		switch gen_int(g, 12) {
		case 0:
			return fmt.tprintf("(%s + %s)", a, b)
		case 1:
			return fmt.tprintf("(%s - %s)", a, b)
		case 2:
			return fmt.tprintf("(%s * %s)", a, b)
		case 3:
			return fmt.tprintf("(%s & %s)", a, b)
		case 4:
			return fmt.tprintf("(%s | %s)", a, b)
		case 5:
			return fmt.tprintf("(%s ~ %s)", a, b)
		case 6:
			return fmt.tprintf("(%s << %d)", a, gen_int(g, 70) - 3)
		case 7:
			return fmt.tprintf("(%s >> %d)", a, gen_int(g, 70) - 3)
		case 8:
			return fmt.tprintf("#%s", gen_expr(g, .Str, depth - 1))
		case 9:
			return fmt.tprintf("(- %s)", a)
		case 10:
			// (a nonzero divisor: a zero one raises, which only pcall bodies do)
			return fmt.tprintf("(%s // ((%s %% 5) + 7))", a, b)
		case 11:
			return fmt.tprintf("math.abs(%s)", a)
		}
	case .Float:
		if leaf {
			edges := [?]string {
				"0.5",
				"-0.0",
				"1e300",
				"2^53",
				"3.25",
				"-1.5",
				"(1/0)",
				"(-1/0)",
				"0.1",
			}
			return edges[gen_int(g, len(edges))]
		}
		switch gen_int(g, 6) {
		case 0:
			return fmt.tprintf(
				"(%s + %s)",
				gen_expr(g, .Float, depth - 1),
				gen_expr(g, .Float, depth - 1),
			)
		case 1:
			return fmt.tprintf(
				"(%s * %s)",
				gen_expr(g, .Float, depth - 1),
				gen_expr(g, .Int, depth - 1),
			)
		case 2:
			return fmt.tprintf(
				"(%s / %s)",
				gen_expr(g, .Int, depth - 1),
				gen_expr(g, .Int, depth - 1),
			)
		case 3:
			return fmt.tprintf("(%s ^ 2)", gen_expr(g, .Float, depth - 1))
		case 4:
			return fmt.tprintf(
				"(%s %% %s)",
				gen_expr(g, .Float, depth - 1),
				gen_expr(g, .Float, depth - 1),
			)
		case 5:
			return fmt.tprintf("math.sqrt(math.abs(%s))", gen_expr(g, .Float, depth - 1))
		}
	case .Str:
		if leaf {
			edges := [?]string{`"a"`, `"hello"`, `""`, `"x y z"`, `"123"`, `"%d"`, `"\0nul"`}
			return edges[gen_int(g, len(edges))]
		}
		switch gen_int(g, 7) {
		case 0:
			return fmt.tprintf(
				"(%s .. %s)",
				gen_expr(g, .Str, depth - 1),
				gen_expr(g, .Str, depth - 1),
			)
		case 1:
			return fmt.tprintf("tostring(%s)", gen_expr(g, .Int, depth - 1))
		case 2:
			return fmt.tprintf("string.rep(%s, %d)", gen_expr(g, .Str, depth - 1), gen_int(g, 4))
		case 3:
			return fmt.tprintf(
				"string.sub(%s, %d, %d)",
				gen_expr(g, .Str, depth - 1),
				gen_int(g, 7) - 3,
				gen_int(g, 7) - 3,
			)
		case 4:
			return fmt.tprintf("string.upper(%s)", gen_expr(g, .Str, depth - 1))
		case 5:
			return fmt.tprintf(
				"string.format(\"%%d:%%s\", %s, %s)",
				gen_expr(g, .Int, depth - 1),
				gen_expr(g, .Str, depth - 1),
			)
		case 6:
			return fmt.tprintf(
				"(string.gsub(%s, \"[aeiou]\", \"#\"))",
				gen_expr(g, .Str, depth - 1),
			)
		}
	case .Tab:
		if leaf {return "{}"}
		return fmt.tprintf(
			"{{%s, %s, %s}}",
			gen_expr(g, .Int, depth - 1),
			gen_expr(g, .Str, depth - 1),
			gen_expr(g, .Float, depth - 1),
		)
	case .Fun:
		x := gen_name(g, "p")
		return fmt.tprintf("function(%s) return %s + %s end", x, x, gen_expr(g, .Int, depth - 1))
	}
	return "nil"
}

@(private = "file")
gen_line :: proc(g: ^Gen, format: string, args: ..any) {
	for _ in 0 ..< g.depth {strings.write_string(&g.b, "  ")}
	fmt.sbprintf(&g.b, format, ..args)
	strings.write_byte(&g.b, '\n')
}

@(private = "file")
gen_block :: proc(g: ^Gen, n: int) {
	mark := len(g.locals)
	g.depth += 1
	for _ in 0 ..< n {
		if g.budget <= 0 {break}
		gen_stmt(g)
	}
	g.depth -= 1
	resize(&g.locals, mark)
}

@(private = "file")
gen_local :: proc(g: ^Gen, t: Gen_Type, value: string) -> string {
	name := gen_name(g, "v")
	gen_line(g, "local %s = %s", name, value)
	append(&g.locals, Gen_Local{name, t})
	return name
}

@(private = "file")
gen_stmt :: proc(g: ^Gen) {
	g.budget -= 1
	deep := g.depth < 4
	switch gen_int(g, 16) {
	case 0, 1:
		t := Gen_Type(gen_int(g, 4))
		gen_local(g, t, gen_expr(g, t, 3))
	case 2:
		t := Gen_Type(gen_int(g, 3))
		if name, ok := gen_pick(g, t); ok {gen_line(g, "%s = %s", name, gen_expr(g, t, 2))}
	case 3:
		t := Gen_Type(gen_int(g, 3))
		gen_line(g, "emit(%s)", gen_expr(g, t, 3))
	case 4:
		if !deep {return}
		gen_line(g, "if %s < %s then", gen_expr(g, .Int, 2), gen_expr(g, .Int, 2))
		gen_block(g, 1 + gen_int(g, 3))
		gen_line(g, "else")
		gen_block(g, 1 + gen_int(g, 2))
		gen_line(g, "end")
	case 5:
		if !deep {return}
		i := gen_name(g, "i")
		steps := [?]string{"", ", 2", ", -1", ", 0.5"}
		step := steps[gen_int(g, 4)]
		lo, hi := gen_int(g, 4), gen_int(g, 8)
		if step == ", -1" {lo, hi = hi, lo}
		gen_line(g, "for %s = %d, %d%s do", i, lo, hi, step)
		mark := len(g.locals)
		append(&g.locals, Gen_Local{i, .Float if step == ", 0.5" else .Int})
		gen_block(g, 1 + gen_int(g, 3))
		resize(&g.locals, mark)
		gen_line(g, "end")
	case 6:
		if !deep {return}
		c := gen_name(g, "c")
		gen_line(g, "local %s = 0", c)
		gen_line(g, "while %s < %d do", c, 1 + gen_int(g, 6))
		g.depth += 1
		gen_line(g, "%s = %s + 1", c, c)
		g.depth -= 1
		gen_block(g, 1 + gen_int(g, 2))
		gen_line(g, "end")
	case 7:
		if t, ok := gen_pick(g, .Tab); ok {
			switch gen_int(g, 4) {
			case 0:
				gen_line(g, "%s[#%s + 1] = %s", t, t, gen_expr(g, .Int, 2))
			case 1:
				gen_line(g, "%s[#%s] = nil", t, t)
			case 2:
				gen_line(g, "%s.k%d = %s", t, gen_int(g, 4), gen_expr(g, .Str, 2))
			case 3:
				gen_line(g, "emit(#%s)", t)
			}
		} else {
			gen_local(g, .Tab, gen_expr(g, .Tab, 2))
		}
	case 8:
		if !deep {return}
		f := gen_name(g, "f")
		a, b := gen_name(g, "a"), gen_name(g, "a")
		gen_line(g, "local function %s(%s, %s)", f, a, b)
		mark := len(g.locals)
		append(&g.locals, Gen_Local{a, .Int}, Gen_Local{b, .Int})
		gen_block(g, gen_int(g, 3))
		g.depth += 1
		gen_line(g, "return %s", gen_expr(g, .Int, 2))
		g.depth -= 1
		resize(&g.locals, mark)
		gen_line(g, "end")
		gen_local(
			g,
			.Int,
			fmt.tprintf("%s(%s, %s)", f, gen_expr(g, .Int, 2), gen_expr(g, .Int, 2)),
		)
	case 9:
		// Closures capturing a fresh loop variable each iteration.
		fs, i := gen_name(g, "fs"), gen_name(g, "i")
		gen_line(g, "local %s = {{}}", fs)
		gen_line(
			g,
			"for %s = 1, %d do %s[%s] = function() return %s * %s end end",
			i,
			1 + gen_int(g, 4),
			fs,
			i,
			i,
			gen_expr(g, .Int, 1),
		)
		gen_line(g, "for _, f in ipairs(%s) do emit(f()) end", fs)
	case 10:
		// pcall around what raises: a zero divisor, error with a value, a bad index.
		body := [?]string {
			"return 1 // 0",
			"return 1 % 0",
			"error({code = 7})",
			"error(\"boom\")",
			"local t = nil; return t.x",
			"return {} < {}",
			"return \"a\" + 1",
		}
		gen_line(g, "emit((pcall(function() %s end)))", body[gen_int(g, len(body))])
	case 11:
		mt := gen_name(g, "mt")
		gen_line(
			g,
			"local %s = {{__add = function(a, b) return a.v + b.v end, __eq = function(a, b) return a.v == b.v end, __lt = function(a, b) return a.v < b.v end, __le = function(a, b) return a.v <= b.v end, __len = function(a) return a.v end, __call = function(a, x) return a.v * x end, __concat = function(a, b) return \"cat\" end, __unm = function(a) return -a.v end, __index = function(t, k) return k .. \"!\" end}}",
			mt,
		)
		o1 := gen_local(
			g,
			.Tab,
			fmt.tprintf("setmetatable({{v = %s}}, %s)", gen_expr(g, .Int, 1), mt),
		)
		o2 := gen_local(
			g,
			.Tab,
			fmt.tprintf("setmetatable({{v = %s}}, %s)", gen_expr(g, .Int, 1), mt),
		)
		gen_line(
			g,
			"emit(%s + %s) emit(%s == %s) emit(%s < %s) emit(%s <= %s) emit(#%s) emit(%s(3)) emit(%s .. %s) emit(-%s) emit(%s.zz)",
			o1,
			o2,
			o1,
			o2,
			o1,
			o2,
			o2,
			o1,
			o1,
			o1,
			o1,
			o2,
			o2,
			o1,
		)
	case 12:
		va := gen_name(g, "va")
		gen_line(g, "local function %s(...) return select('#', ...), ... end", va)
		gen_line(g, "emit((%s(%s, nil, %s)))", va, gen_expr(g, .Int, 1), gen_expr(g, .Str, 1))
		gen_line(g, "emit(select('#', %s()))", va)
	case 13:
		co := gen_name(g, "co")
		gen_line(
			g,
			"local %s = coroutine.wrap(function(a) for i = 1, 3 do a = a + coroutine.yield(a * i) end return a end)",
			co,
		)
		gen_line(
			g,
			"emit(%s(%s)) emit(%s(1)) emit(%s(2)) emit(%s(3))",
			co,
			gen_expr(g, .Int, 1),
			co,
			co,
			co,
		)
	case 14:
		s := gen_expr(g, .Str, 2)
		gen_line(
			g,
			"emit((string.find(%s, \"l\", 1, true))) emit(string.byte(%s .. \"q\", 1)) emit(string.reverse(%s))",
			s,
			s,
			s,
		)
	case 15:
		t := gen_local(g, .Tab, "{}")
		gen_line(
			g,
			"for k = 1, %d do %s[k] = (k * %d) %% 11 end",
			2 + gen_int(g, 8),
			t,
			1 + gen_int(g, 9),
		)
		gen_line(g, "table.sort(%s) emit(table.concat(%s, \",\"))", t, t)
	}
}

PROGRAM_HEAD :: `local out = {}
local function show(v)
  local t = type(v)
  if t == "number" then
    if v ~= v then return "nan" end
    return math.type(v) .. ":" .. tostring(v)
  elseif t == "table" then
    return "table#" .. #v
  elseif t == "function" or t == "thread" then
    return t
  end
  return tostring(v)
end
local function emit(v) out[#out + 1] = show(v) end
local ok = pcall(function()
`

PROGRAM_TAIL :: `end)
print(table.concat(out, " "))
print(ok)
`

// fuzz_generate_program writes one generated program.
fuzz_generate_program :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	g := Gen {
		rng    = rng,
		b      = strings.builder_make(context.temp_allocator),
		locals = make([dynamic]Gen_Local, context.temp_allocator),
		budget = 8 + base.rng_int_max(rng, 32),
	}
	strings.write_string(&g.b, PROGRAM_HEAD)
	for g.budget > 0 {gen_stmt(&g)}
	strings.write_string(&g.b, PROGRAM_TAIL)
	body := strings.to_string(g.b)
	append(out, fmt.tprintf("%s%016x\n", GEN_MARK, xxhash.XXH64(transmute([]u8)body)))
	append(out, body)
}

// --- script.bytecode

fuzz_bytecode :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	vm, ve := vm_create(fuzz_config(), allocator)
	if ve.kind != .None {
		fuzz.fail("vm_create: %s", ve.message)
		return 0
	}
	defer vm_destroy(vm)
	fn, ce := compile(vm, string(data), "bytecode", allocator = context.temp_allocator)
	if ce.kind != .None {return fuzz.sig_mix(1, u64(ce.kind))}
	// The protos of the module, then mutations of their instructions from the input's hash.
	protos := make([dynamic]Ref, context.temp_allocator)
	append(&protos, obj(vm, as_ref(fn), Closure).proto)
	for i := 0; i < len(protos); i += 1 {
		p := obj(vm, protos[i], Proto)
		for v in values_of(vm, p.protos, p.protos_len) {append(&protos, as_ref(v))}
	}
	rng := base.rng_make(xxhash.XXH64(data) ~ 0x51c)
	for _ in 0 ..< 1 + base.rng_int_max(&rng, 4) {
		p := obj(vm, protos[base.rng_int_max(&rng, len(protos))], Proto)
		code := bytes_of(vm, p.code, Instr, p.code_len)
		at := base.rng_int_max(&rng, len(code))
		switch base.rng_int_max(&rng, 6) {
		case 0:
			code[at] ~= Instr(1) << uint(base.rng_int_max(&rng, 32))
		case 1:
			code[at] = (code[at] &~ 0x7f) | Instr(base.rng_int_max(&rng, int(max(Op)) + 3))
		case 2:
			set_arg_a(&code[at], u32(base.rng_int_max(&rng, 256)))
		case 3:
			set_arg_b(&code[at], u32(base.rng_int_max(&rng, 256)))
		case 4:
			set_arg_c(&code[at], u32(base.rng_int_max(&rng, 256)))
		case 5:
			other := base.rng_int_max(&rng, len(code))
			code[at], code[other] = code[other], code[at]
		}
	}
	for pr in protos {
		if ok, _ := verify_proto(vm, pr); !ok {return fuzz.sig_mix(2)}
	}
	r := call(vm, fn, nil, FUZZ_SLICE, context.temp_allocator)
	if r.status == .Suspended || r.status == .Yielded {abort(vm)}
	if ok, problem := heap_check(vm); !ok {fuzz.fail("heap_check: %s", problem)}
	return fuzz_signature(3 + u64(r.status), r.error, vm.run_used)
}

// --- script.snapshot

// fuzz_generate_snapshot: a generated program run to a suspension, snapshotted.
fuzz_generate_snapshot :: proc(rng: ^base.Rng, out: ^[dynamic]u8) {
	src := make([dynamic]u8, context.temp_allocator)
	fuzz_generate_program(rng, &src)
	vm, ve := vm_create(fuzz_config(), context.temp_allocator)
	if ve.kind != .None {return}
	defer vm_destroy(vm)
	fn, ce := compile(vm, string(src[:]), "gen", allocator = context.temp_allocator)
	if ce.kind != .None {return}
	r := call(vm, fn, nil, i64(1 + base.rng_int_max(rng, 2000)), context.temp_allocator)
	_ = r
	append(out, ..snapshot(vm, context.temp_allocator))
}

fuzz_snapshot :: proc(data: []u8, allocator: runtime.Allocator) -> u64 {
	vm, e := restore_unchecked(data, fuzz_config(), allocator)
	if e.kind != .None {return fuzz.sig_mix(1, fuzz.sig_text(e.message))}
	defer vm_destroy(vm)
	status := Run_Status.Done
	switch vm.state {
	case .Suspended, .Yielded:
		res := resume(vm, nil, FUZZ_SLICE, context.temp_allocator)
		for i := 0; res.status == .Suspended && i < 20; i += 1 {
			res = resume(vm, nil, FUZZ_SLICE, context.temp_allocator)
		}
		status = res.status
		if vm.state != .Idle {abort(vm)}
	case .Idle, .Running:
	}
	if ok, problem := heap_check(vm); !ok {fuzz.fail("heap_check after a restore: %s", problem)}
	return fuzz.sig_mix(2, u64(status), fuzz.sig_bucket(int(vm.run_used)))
}

// FUZZ_CORPUS: the conformance files, the source fuzzer's corpus.
FUZZ_CORPUS := #load_directory("testdata/conformance")
