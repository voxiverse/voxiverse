package fuzz

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "common:base"

// The fuzz harness (Q1, docs/fuzzing.md). Odin's compiler has no coverage
// instrumentation, so the harness is guided by outcome signatures: each target returns a u64
// that says what the input made the decoder do (the error, the stage reached, a bucket of
// bytes consumed), and an input with a signature the run has not seen joins the corpus.

// Target is one decoder of untrusted input.
Target :: struct {
	name:       string, // "<area>.<thing>": pack.json, save.region
	run:        proc(data: []u8, allocator: runtime.Allocator) -> u64, // the signature
	seeds:      string, // the committed seed corpus: testdata/fuzz/<name>/
	dictionary: []string, // tokens the mutator inserts
	max_len:    int, // the cap on an input
	generate:   proc(rng: ^base.Rng, out: ^[dynamic]u8), // optional: a structured input
	alloc_cap:  int, // bytes live at once; 0: max_len * 64
	fixup:      proc(data: ^[dynamic]u8), // optional: repairs checksums after mutation (half the cases)
}

Failure :: enum {
	None,
	Failed, // the target called fail
	Leak, // an allocation of the case was not freed
	Over_Cap, // the case allocated past the target's cap
	Slow, // more than SLOW_US of this thread's CPU time
}

SLOW_US :: 2_000_000
HANG_SECONDS :: 20 // the watchdog's limit in wall time, loaded machines included

Case_Result :: struct {
	signature: u64,
	failure:   Failure,
	detail:    string, // allocated with the context's allocator
}

// The per-case state `fail` reaches.
Case :: struct {
	failed:  bool,
	message: [256]u8,
	length:  int,
}

@(thread_local)
current_case: ^Case

// fail marks the running case as failed (a check inside a target: "a refused import left
// files behind"). Outside a case it panics.
fail :: proc(format: string, args: ..any) {
	c := current_case
	if c == nil {panic(fmt.tprintf(format, ..args))}
	if c.failed {return}
	c.failed = true
	c.length = len(fmt.bprintf(c.message[:], format, ..args))
}

// Cap_Allocator tracks every allocation of a case, refuses those past the cap and remembers
// that one was.
Cap_Allocator :: struct {
	tracking: mem.Tracking_Allocator,
	limit:    int,
	exceeded: bool,
}

cap_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_ptr: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	c := (^Cap_Allocator)(data)
	t := &c.tracking
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if int(t.current_memory_allocated) + size > c.limit {
			c.exceeded = true
			return nil, .Out_Of_Memory
		}
	case .Resize, .Resize_Non_Zeroed:
		if int(t.current_memory_allocated) + size - old_size > c.limit {
			c.exceeded = true
			return nil, .Out_Of_Memory
		}
	}
	return mem.tracking_allocator_proc(t, mode, size, alignment, old_ptr, old_size, loc)
}

// run_case runs the target once on data under the contract: no leak, no allocation past the
// cap, not slow, no failed check. A panic or a bad access ends the process (the crash hook
// saves the input first).
run_case :: proc(t: ^Target, data: []u8) -> (res: Case_Result) {
	cap_alloc: Cap_Allocator
	mem.tracking_allocator_init(&cap_alloc.tracking, context.allocator, context.allocator)
	cap_alloc.limit = t.alloc_cap if t.alloc_cap > 0 else t.max_len * 64
	allocator := runtime.Allocator{cap_proc, &cap_alloc}

	context.logger = log.nil_logger() // a decoder logs what it refuses: not here
	c: Case
	current_case = &c
	defer current_case = nil
	crash_input_set(t, data)
	started := base.thread_cpu_us()
	watchdog_begin()
	res.signature = t.run(data, allocator)
	watchdog_end()
	elapsed := base.thread_cpu_us() - started
	free_all(context.temp_allocator)

	switch {
	case c.failed:
		res.failure = .Failed
		res.detail = strings.clone(string(c.message[:c.length]))
	case cap_alloc.exceeded:
		res.failure = .Over_Cap
		res.detail = fmt.aprintf("allocated past %d bytes", cap_alloc.limit)
	case len(cap_alloc.tracking.allocation_map) > 0:
		res.failure = .Leak
		for _, entry in cap_alloc.tracking.allocation_map {
			res.detail = fmt.aprintf(
				"leak: %d bytes allocated at %s:%d",
				entry.size,
				filepath.base(entry.location.file_path),
				entry.location.line,
			)
			break
		}
	case len(cap_alloc.tracking.bad_free_array) > 0:
		res.failure = .Failed
		res.detail = strings.clone("a bad free")
	case elapsed > SLOW_US:
		res.failure = .Slow
		res.detail = fmt.aprintf("took %d ms of CPU time", elapsed / 1000)
	}
	// What the case leaked is freed here, so one leak is one failure, not a leak of the run.
	for ptr in cap_alloc.tracking.allocation_map {free(ptr, cap_alloc.tracking.backing)}
	mem.tracking_allocator_destroy(&cap_alloc.tracking)
	return
}

Config :: struct {
	seed:    u64,
	cases:   int, // 0: until seconds
	seconds: f64,
	out_dir: string, // crash files: <out_dir>/<target>/
	keep:    string, // write the corpus here when given
	regress: bool, // replay the regression files first
}

Report :: struct {
	cases:      int,
	corpus:     int,
	signatures: int,
	failures:   [dynamic]string, // one line each, naming the file
}

seed_of :: proc(seed: u64, name: string) -> u64 {
	return seed ~ xxhash.XXH64(transmute([]u8)name)
}

// run_target fuzzes one target: the regression files, the seeds, then mutations of the
// corpus until the budget ends.
run_target :: proc(t: ^Target, cfg: Config) -> (report: Report) {
	context.assertion_failure_proc = assertion_failure
	crash_install(t, cfg)
	out := join({cfg.out_dir, t.name})
	os.make_directory_all(out)

	record :: proc(report: ^Report, t: ^Target, cfg: Config, data: []u8, res: Case_Result) {
		path := save_failure(t, cfg, data, res.detail)
		defer delete(path)
		append(
			&report.failures,
			fmt.aprintf("%s: %v: %s (%s)", t.name, res.failure, res.detail, path),
		)
	}

	if cfg.regress {
		for file in list_files(join({t.seeds, "regress"})) {
			data, err := os.read_entire_file_from_path(file, context.allocator)
			if err != nil {continue}
			res := run_case(t, data)
			report.cases += 1
			if res.failure != .None {
				append(
					&report.failures,
					fmt.aprintf("%s: %v: %s (%s)", t.name, res.failure, res.detail, file),
				)
			}
			delete(data)
			delete(res.detail)
		}
	}

	rng := base.rng_make(seed_of(cfg.seed, t.name))
	corpus: Corpus
	corpus_init(&corpus)
	defer corpus_destroy(&corpus)
	for file in list_files(t.seeds) {
		data, err := os.read_entire_file_from_path(file, context.allocator)
		if err != nil {continue}
		defer delete(data)
		if len(data) > t.max_len {continue}
		res := run_case(t, data)
		report.cases += 1
		corpus_offer(&corpus, data, res.signature)
		if res.failure != .None {record(&report, t, cfg, data, res)}
		delete(res.detail)
	}
	if t.generate != nil {
		for _ in 0 ..< 8 {
			gen := make([dynamic]u8)
			t.generate(&rng, &gen)
			if len(gen) > t.max_len {resize(&gen, t.max_len)}
			res := run_case(t, gen[:])
			report.cases += 1
			corpus_offer(&corpus, gen[:], res.signature)
			if res.failure != .None {record(&report, t, cfg, gen[:], res)}
			delete(res.detail)
			delete(gen)
		}
	}
	if len(corpus.inputs) == 0 {corpus_offer(&corpus, {}, 0xffff_ffff)}

	start := time.tick_now()
	for i := 0;; i += 1 {
		if cfg.cases > 0 {
			if i >= cfg.cases {break}
		} else if time.duration_seconds(time.tick_since(start)) >= cfg.seconds {
			break
		}
		input := make_input(t, &rng, &corpus)
		res := run_case(t, input)
		report.cases += 1
		corpus_offer(&corpus, input, res.signature)
		if res.failure != .None {record(&report, t, cfg, input, res)}
		delete(res.detail)
		delete(input)
	}
	report.corpus = len(corpus.inputs)
	report.signatures = len(corpus.seen)
	if cfg.keep != "" {
		corpus_write(&corpus, join({cfg.keep, t.name}))
	}
	return
}

// make_input: a mutation of a corpus input (or a generated one, one case in sixteen).
make_input :: proc(t: ^Target, rng: ^base.Rng, corpus: ^Corpus) -> []u8 {
	buf := make([dynamic]u8) // (explicitly: a generator may switch the context's allocator)
	if t.generate != nil && base.rng_int_max(rng, 16) == 0 {
		t.generate(rng, &buf)
	} else {
		pick := corpus.inputs[base.rng_int_max(rng, len(corpus.inputs))]
		append(&buf, ..pick)
	}
	other := corpus.inputs[base.rng_int_max(rng, len(corpus.inputs))]
	for _ in 0 ..< 1 + base.rng_int_max(rng, 8) {
		mutate(rng, &buf, other, t.dictionary)
	}
	if t.fixup != nil && base.rng_int_max(rng, 2) == 0 {t.fixup(&buf)}
	if len(buf) > t.max_len {resize(&buf, t.max_len)}
	return buf[:]
}

// run_file runs one input and says how it went (build fuzz <target> --case <file>).
run_file :: proc(t: ^Target, cfg: Config, path: string) -> (Case_Result, bool) {
	context.assertion_failure_proc = assertion_failure
	crash_install(t, cfg)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return {}, false}
	defer delete(data)
	return run_case(t, data), true
}

list_files :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return nil}
	for info in infos {
		if info.type == .Regular {
			append(&out, join({dir, info.name}))
		}
	}
	return out[:]
}

// join: a path from parts, with "/" (every OS takes it).
join :: proc(parts: []string) -> string {
	return strings.join(parts, "/", context.temp_allocator)
}
