package build

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// The content cache (issue #67): a step whose inputs are, byte for byte, what they
// were when it last succeeded is not done again: a test binary is run without
// compiling it, a cross-OS object build or a formatting check is not repeated, a
// shader is not recompiled. A step's key is a hash over what it was asked to do
// (its command and the compiler's version) and the content of every file it read
// (XXH3, 128 bits: a content hash against accidents, not attackers);
// for an Odin compile that is the compiler's own list (-export-dependencies: every
// source and every #load'ed file) plus the names in each of their directories, so a
// file added beside them (a new `_linux.odin`) counts too. A key is kept only when
// no input changed while the step ran (each input older than its start), so an edit
// made during a build is never taken for the built one. Nothing is decided by
// modification time alone: a stale result would be a wrong one.

CACHE_DIR :: "build/cache"
CACHE_VERSION :: "1" // bump when what a key covers changes

Digest :: u128

// file digests, once per run: many compiles read the same core files.
@(private = "file")
digests: map[string]Digest

// file_digest: the hash of a file's content.
file_digest :: proc(path: string) -> (d: Digest, ok: bool) {
	if found, has := digests[path]; has {return found, true}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return {}, false}
	d = content_digest(data)
	digests[strings.clone(path)] = d
	return d, true
}

// content_digest: the hash of data (as file_digest gives a file's).
content_digest :: proc(data: []byte) -> Digest {
	return xxhash.XXH3_128(data)
}

// Key_Builder: the parts of one key, in order.
Key_Builder :: struct {
	state: xxhash.XXH3_state,
	ok:    bool, // false once an input could not be read: no key
}

key_begin :: proc(k: ^Key_Builder, kind: string) {
	xxhash.XXH3_init_state(&k.state)
	xxhash.XXH3_128_reset(&k.state)
	k.ok = true
	key_text(k, CACHE_VERSION)
	key_text(k, kind)
	key_text(k, odin_version())
	key_text(k, ODIN_OS_STRING)
	key_text(k, ODIN_ARCH_STRING)
}

// key_text adds a string (its length first, so "ab"+"c" is not "a"+"bc").
key_text :: proc(k: ^Key_Builder, s: string) {
	n := len(s)
	xxhash.XXH3_128_update(&k.state, transmute([]u8)fmt.tprintf("%d:", n))
	xxhash.XXH3_128_update(&k.state, transmute([]u8)s)
}

// key_file adds a file's name and content.
key_file :: proc(k: ^Key_Builder, path: string) {
	d, ok := file_digest(path)
	if !ok {k.ok = false; return}
	key_text(k, path)
	bytes := transmute([16]u8)d
	xxhash.XXH3_128_update(&k.state, bytes[:])
}

// key_listing adds the names in a directory (sorted), so a file added or removed
// there changes the key.
key_listing :: proc(k: ^Key_Builder, dir: string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {k.ok = false; return}
	names := make([dynamic]string, context.temp_allocator)
	for e in entries {append(&names, e.name)}
	slice.sort(names[:])
	key_text(k, dir)
	for n in names {key_text(k, n)}
}

key_end :: proc(k: ^Key_Builder) -> (key: string, ok: bool) {
	if !k.ok {return "", false}
	d := transmute([16]u8)xxhash.XXH3_128_digest(&k.state)
	return string(hex.encode(d[:], context.temp_allocator)), true
}

// compiler_version: `odin version`'s output, read once a run (a new compiler is new
// input); a test sets it instead.
compiler_version: string

odin_version :: proc() -> string {
	if compiler_version == "" {
		out, ok := capture({"odin", "version"})
		compiler_version = strings.clone(strings.trim_space(out)) if ok else "unknown"
	}
	return compiler_version
}

// digests_forget drops the remembered digests (a test changes files between keys).
digests_forget :: proc() {
	for path in digests {delete(path)}
	delete(digests)
	digests = {}
}

// Odin_Inputs: what a compile read, as -export-dependencies:json writes it.
Odin_Inputs :: struct {
	source_files: []string,
	load_files:   []string,
}

// odin_key: the key of an Odin compile (cmd, without the dependency flags) from the
// inputs its last run listed in deps; ok is false without a list or with an input
// gone. newer_than (when set) also fails it if an input changed after that time.
odin_key :: proc(
	cmd: []string,
	deps: string,
	newer_than: time.Time = {},
) -> (
	key: string,
	ok: bool,
) {
	data, err := os.read_entire_file_from_path(deps, context.temp_allocator)
	if err != nil {return "", false}
	inputs: Odin_Inputs
	if json.unmarshal(data, &inputs, allocator = context.temp_allocator) != nil {return "", false}
	if len(inputs.source_files) == 0 {return "", false}
	k: Key_Builder
	key_begin(&k, "odin")
	for part in cmd {key_text(&k, part)}
	files := slice.concatenate(
		[][]string{inputs.source_files, inputs.load_files},
		context.temp_allocator,
	)
	slice.sort(files)
	dirs := make(map[string]bool, context.temp_allocator)
	for f in files {
		key_file(&k, f)
		dirs[filepath.dir(f)] = true
		if newer_than != {} {
			info, serr := os.stat(f, context.temp_allocator)
			if serr != nil || time.diff(newer_than, info.modification_time) >= 0 {return "", false}
		}
	}
	sorted_dirs := make([dynamic]string, context.temp_allocator)
	for d in dirs {append(&sorted_dirs, d)}
	slice.sort(sorted_dirs[:])
	for d in sorted_dirs {key_listing(&k, d)}
	return key_end(&k)
}

// Odin_Step: one cached Odin compile: its record is CACHE_DIR/<name>.key, its
// input list CACHE_DIR/<name>.deps.json.
Odin_Step :: struct {
	name:    string,
	cmd:     []string, // the compile, without the dependency flags
	output:  string, // a file it makes that must still be there ("" when none is kept)
	started: time.Time, // set by odin_step_command
}

@(private = "file")
step_paths :: proc(s: ^Odin_Step) -> (record, deps: string) {
	record = path_join({CACHE_DIR, strings.concatenate({s.name, ".key"})})
	deps = path_join({CACHE_DIR, strings.concatenate({s.name, ".deps.json"})})
	return
}

// output_stamp: the output's size and time, so a hit is refused if it was replaced.
@(private = "file")
output_stamp :: proc(path: string) -> (stamp: string, ok: bool) {
	if path == "" {return "-", true}
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {return "", false}
	return fmt.tprintf("%d %d", info.size, time.time_to_unix_nano(info.modification_time)), true
}

// odin_step_fresh: whether the step's inputs and output are what they were when it
// last succeeded.
odin_step_fresh :: proc(s: ^Odin_Step) -> bool {
	record, deps := step_paths(s)
	saved, err := os.read_entire_file_from_path(record, context.temp_allocator)
	if err != nil {return false}
	key, ok := odin_key(s.cmd, deps)
	if !ok {return false}
	stamp, has := output_stamp(s.output)
	if !has {return false}
	return string(saved) == strings.concatenate({key, "\n", stamp, "\n"}, context.temp_allocator)
}

// odin_step_command: the step's command with the flags that list its inputs; it
// forgets the last success first (until odin_step_succeeded, the step is not fresh).
odin_step_command :: proc(s: ^Odin_Step) -> []string {
	record, deps := step_paths(s)
	os.make_directory_all(CACHE_DIR)
	os.remove(record)
	s.started = time.now()
	return slice.concatenate(
		[][]string {
			s.cmd,
			{
				"-export-dependencies:json",
				strings.concatenate({"-export-dependencies-file:", deps}),
			},
		},
	)
}

// odin_step_succeeded records the step as done for its inputs, unless one changed
// while it ran (then the next run does it again).
odin_step_succeeded :: proc(s: ^Odin_Step) {
	record, deps := step_paths(s)
	key, ok := odin_key(s.cmd, deps, s.started)
	if !ok {return}
	stamp, has := output_stamp(s.output)
	if !has {return}
	_ = os.write_entire_file(record, fmt.tprintf("%s\n%s\n", key, stamp))
}
