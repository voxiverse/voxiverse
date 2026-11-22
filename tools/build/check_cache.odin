package build

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// `check` does not run a job again whose inputs are, byte for byte, those of a job that
// passed before (`check --all` and the gate run every one). A job's inputs are its command
// (flags, defines, target, the collections it names), the driver's own executable, the
// compiler (its version, the `odin` on PATH, and every file under its root by size and
// time: `core:`, `base:`, `vendor:`) and the files the compiler can read for it: every
// `.odin` file in its package's folder whatever its build tags, the same for every folder
// a string literal there names through one of the command's collections (`"common:base"`,
// imports or not) or an `import` names by a relative path, and so on down, and the files a
// `#load`, `#load_directory`, `#load_hash` or `#exists` names. A directive's path that
// continues past its first literal (`"../../build/textures/" + NAME`) stands for that
// literal's folder with everything under it; one that starts with no literal leaves its
// package's jobs never skipped. What passed is kept in CHECK_PASSES as a digest of those
// inputs; a failed job is not kept, nor one whose inputs changed while it ran.

// Digest: an XXH3-128 of some bytes (a file, a folder's listing, a job's inputs).
Digest :: u128

// CHECK_PASSES: the digests of the inputs of the jobs (and of the files the format check
// passed) that passed, one in hex a line, the newest first; CHECK_PASSES_KEPT of them.
CHECK_PASSES :: "build/check_passes"
CHECK_PASSES_KEPT :: 20000

// Check_Inputs: what one look at a job's inputs has read, each file and folder once.
Check_Inputs :: struct {
	files:    map[string]Digest,
	trees:    map[string]Tree_Digest,
	packages: map[string]Package_Inputs,
	tools:    Digest, // the driver's executable and the compiler
	known:    bool, // tools was read: when false nothing is skipped or kept
}

Tree_Digest :: struct {
	digest: Digest,
	exact:  bool, // the whole folder was read
}

// Package_Inputs: a folder's `.odin` files, what they load and what they may import.
Package_Inputs :: struct {
	digest:           Digest,
	collection_paths: []string, // literals of the form "<name>:<path>"
	folders:          []string, // folders a relative import names
	exact:            bool, // every load was read: false, the jobs over it are never skipped
}

// Source_Refs: what a source file can make the compiler read (source_refs).
Source_Refs :: struct {
	collection_paths: [dynamic]string,
	imports:          [dynamic]string, // relative import paths
	loads:            [dynamic]Load_Ref,
	exact:            bool, // every loading directive's path starts with a literal
}

// Load_Ref: a path a loading directive names, from the folder of its file. folder: the
// literal only starts the path, so it stands for its folder and everything under it.
Load_Ref :: struct {
	path:   string,
	folder: bool,
}

digest_of :: proc(data: []u8) -> Digest {
	return Digest(xxhash.XXH3_128_default(data))
}

// check_inputs_make: a look at inputs, starting with the tools (check_tools_digest).
check_inputs_make :: proc() -> Check_Inputs {
	inputs: Check_Inputs
	inputs.tools, inputs.known = check_tools_digest()
	return inputs
}

// check_tools_digest: the driver's executable and the compiler: `odin version`, `odin
// root`, the `odin` on PATH and every file under the root by path, size and time (its
// libraries are read by every job, and digesting them all would cost more than the jobs
// it skips). ok is false when one of them cannot be read.
check_tools_digest :: proc() -> (digest: Digest, ok: bool) {
	b := strings.builder_make()
	driver := os.read_entire_file_from_path(os.args[0], context.allocator) or_else nil
	odin_exe := exe_on_path("odin") or_return
	odin, err := os.read_entire_file_from_path(odin_exe, context.allocator)
	if driver == nil || err != nil {return}
	version := capture({"odin", "version"}) or_return
	root := capture({"odin", "root"}) or_return
	root = strings.trim_space(root)
	fmt.sbprintf(
		&b,
		"driver %032x\nodin %s %032x\n%s\n",
		digest_of(driver),
		odin_exe,
		digest_of(odin),
		version,
	)
	lines := make([dynamic]string)
	w := os.walker_create(root)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.type == .Directory && info.name == ".git" {os.walker_skip_dir(&w); continue}
		append(
			&lines,
			fmt.aprintf("%s %d %d", info.fullpath, info.size, info.modification_time._nsec),
		)
	}
	if _, walk_err := os.walker_error(&w); walk_err != nil {return}
	slice.sort(lines[:])
	fmt.sbprintf(&b, "root %s\n%s", root, strings.join(lines[:], "\n"))
	return digest_of(transmute([]u8)strings.to_string(b)), true
}

// exe_on_path: the file a command named name runs, found on PATH.
exe_on_path :: proc(name: string) -> (path: string, ok: bool) {
	dirs, _ := os.split_path_list(os.get_env("PATH", context.allocator), context.allocator)
	for dir in dirs {
		if dir == "" {continue}
		candidate := path_join({dir, strings.concatenate({name, exe_suffix()})})
		if os.exists(candidate) && !os.is_dir(candidate) {return candidate, true}
	}
	return
}

// file_digest: a file's contents, or (absent or unreadable) a digest saying so.
file_digest :: proc(inputs: ^Check_Inputs, path: string) -> Digest {
	if found, ok := inputs.files[path]; ok {return found}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	d :=
		digest_of(data) if err == nil else digest_of(transmute([]u8)fmt.tprintf("\x00absent %s", path))
	inputs.files[strings.clone(path)] = d
	return d
}

// tree_digest: a file's contents, or a folder's: every path under it, what it is and
// each file's contents.
tree_digest :: proc(inputs: ^Check_Inputs, path: string) -> Tree_Digest {
	if found, ok := inputs.trees[path]; ok {return found}
	result := Tree_Digest {
		exact = true,
	}
	info, err := os.stat(path, context.allocator)
	if err != nil {
		result.digest = digest_of(transmute([]u8)fmt.tprintf("\x00absent %s", path))
	} else if info.type != .Directory {
		result.digest = file_digest(inputs, path)
	} else {
		lines := make([dynamic]string)
		w := os.walker_create(path)
		for entry in os.walker_walk(&w) {
			d := Digest(0) if entry.type == .Directory else file_digest(inputs, entry.fullpath)
			append(&lines, fmt.aprintf("%s %v %032x", entry.fullpath, entry.type, d))
		}
		if _, walk_err := os.walker_error(&w); walk_err != nil {result.exact = false}
		os.walker_destroy(&w)
		slice.sort(lines[:])
		result.digest = digest_of(transmute([]u8)strings.join(lines[:], "\n"))
	}
	inputs.trees[strings.clone(path)] = result
	return result
}

// package_inputs: the folder dir as a package: its `.odin` files, what they load, and the
// paths they may import.
package_inputs :: proc(inputs: ^Check_Inputs, dir: string) -> Package_Inputs {
	if found, ok := inputs.packages[dir]; ok {return found}
	result := Package_Inputs {
		exact = true,
	}
	b := strings.builder_make()
	collection_paths := make([dynamic]string)
	folders := make([dynamic]string)
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {fmt.sbprintf(&b, "\x00unread %s %v\n", dir, err)}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.type == .Directory || filepath.ext(entry.name) != ".odin" {continue}
		path := path_join({dir, entry.name})
		text, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			result.exact = false
			continue
		}
		fmt.sbprintf(&b, "file %s %032x\n", entry.name, digest_of(text))
		refs := source_refs(string(text))
		result.exact = result.exact && refs.exact
		append(&collection_paths, ..refs.collection_paths[:])
		for p in refs.imports {append(&folders, path_join({dir, p}))}
		for load in refs.loads {
			literal := load.path
			if load.folder {
				cut := strings.last_index_byte(literal, '/')
				literal = literal[:cut + 1] if cut >= 0 else ""
			}
			at := literal if filepath.is_abs(literal) else path_join({dir, literal})
			tree := tree_digest(inputs, at)
			result.exact = result.exact && tree.exact
			fmt.sbprintf(&b, "load %s %v %032x\n", at, load.folder, tree.digest)
		}
	}
	result.digest = digest_of(transmute([]u8)strings.to_string(b))
	result.collection_paths = collection_paths[:]
	result.folders = folders[:]
	inputs.packages[strings.clone(dir)] = result
	return result
}

// source_refs reads an Odin file for what it can make the compiler read: every string
// literal of the form "<name>:<path>" (an import through a collection is one), the path of
// an `import` that names none (relative), and the paths of the loading directives. It
// skips comments, character literals and the insides of strings, so a quote in one of
// them does not throw the reading off. A loading directive whose argument does not start
// with a literal clears exact.
source_refs :: proc(text: string) -> Source_Refs {
	refs := Source_Refs {
		exact = true,
	}
	after_import := false // the next literal is an import's path
	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case strings.has_prefix(text[i:], "//"):
			for i < len(text) && text[i] != '\n' {i += 1}
		case strings.has_prefix(text[i:], "/*"):
			depth := 0
			for i < len(text) {
				if strings.has_prefix(text[i:], "/*") {
					depth += 1
					i += 2
				} else if strings.has_prefix(text[i:], "*/") {
					depth -= 1
					i += 2
					if depth == 0 {break}
				} else {
					i += 1
				}
			}
		case c == '"' || c == '`':
			literal: string
			literal, i = read_literal(text, i)
			if strings.index_byte(literal, ':') > 0 {
				append(&refs.collection_paths, literal)
			} else if after_import {
				append(&refs.imports, literal)
				if strings.index_byte(literal, '\\') >= 0 {refs.exact = false}
			}
			after_import = false
		case c == '\'':
			_, i = read_literal(text, i)
		case c == '#':
			j := ident_end(text, i + 1)
			name := text[i + 1:j]
			if strings.has_prefix(name, "load") || name == "exists" {
				if ref, ok := load_ref(text, j); ok {
					append(&refs.loads, ref)
				} else {
					refs.exact = false
				}
			}
			i = max(j, i + 1)
		case ident_start(c):
			j := ident_end(text, i)
			if text[i:j] == "import" {after_import = true}
			i = j
		case:
			i += 1
		}
	}
	return refs
}

// read_literal: the literal opening at text[i] (", ` or '), its insides as written, and
// where reading goes on.
@(private = "file")
read_literal :: proc(text: string, i: int) -> (literal: string, next: int) {
	quote := text[i]
	j := i + 1
	for j < len(text) {
		switch {
		case quote != '`' && text[j] == '\\':
			j += 2
			continue
		case text[j] == quote:
			return text[i + 1:j], j + 1
		case quote != '`' && text[j] == '\n':
			return text[i + 1:j], j // (unterminated: the compiler fails it)
		}
		j += 1
	}
	return text[i + 1:], len(text)
}

// load_ref: the path of the loading directive whose name ends at text[j], when its
// argument starts with a literal.
@(private = "file")
load_ref :: proc(text: string, j: int) -> (ref: Load_Ref, ok: bool) {
	k := skip_space(text, j)
	if k >= len(text) || text[k] != '(' {return}
	k = skip_space(text, k + 1)
	if k >= len(text) || (text[k] != '"' && text[k] != '`') {return}
	literal, next := read_literal(text, k)
	// (A collection, a drive or an escape: not read here, so never skipped.)
	if strings.index_byte(literal, ':') >= 0 || strings.index_byte(literal, '\\') >= 0 {return}
	k = skip_space(text, next)
	if k >= len(text) {return}
	switch text[k] {
	case ',', ')':
		return {literal, false}, true
	case '+':
		return {literal, true}, true
	}
	return
}

@(private = "file")
skip_space :: proc(text: string, i: int) -> int {
	i := i
	for i < len(text) && strings.index_byte(" \t\r\n", text[i]) >= 0 {i += 1}
	return i
}

@(private = "file")
ident_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
ident_end :: proc(text: string, i: int) -> int {
	i := i
	for i < len(text) && (ident_start(text[i]) || (text[i] >= '0' && text[i] <= '9')) {i += 1}
	return i
}

// command_collections: the collections cmd names (-collection:<name>=<folder>).
command_collections :: proc(cmd: []string) -> [][2]string {
	found := make([dynamic][2]string)
	for arg in cmd {
		if !strings.has_prefix(arg, "-collection:") {continue}
		name, _, folder := strings.partition(arg[len("-collection:"):], "=")
		append(&found, [2]string{name, folder})
	}
	return found[:]
}

// job_inputs_digest: the digest of the inputs of the job that runs cmd on the package in
// folder pkg; exact is false when one of them could not be read (never skipped).
job_inputs_digest :: proc(
	inputs: ^Check_Inputs,
	pkg: string,
	cmd: []string,
) -> (
	digest: Digest,
	exact: bool,
) {
	collections := command_collections(cmd)
	b := strings.builder_make()
	fmt.sbprintf(&b, "tools %032x\nhost %s\n", inputs.tools, host_target())
	for arg in cmd {fmt.sbprintf(&b, "arg %s\n", arg)}
	exact = inputs.known
	seen := make(map[string]bool)
	folders := make([dynamic]string)
	stack := make([dynamic]string)
	append(&stack, path_join({pkg}))
	for len(stack) > 0 {
		dir := pop(&stack)
		if seen[dir] {continue}
		seen[dir] = true
		append(&folders, dir)
		p := package_inputs(inputs, dir)
		exact = exact && p.exact
		append(&stack, ..p.folders)
		for path in p.collection_paths {
			name, _, rest := strings.partition(path, ":")
			for c in collections {
				if c[0] == name {append(&stack, path_join({c[1], rest}))}
			}
		}
	}
	slice.sort(folders[:])
	for dir in folders {
		fmt.sbprintf(&b, "package %s %032x\n", dir, inputs.packages[dir].digest)
	}
	return digest_of(transmute([]u8)strings.to_string(b)), exact
}

// check_cached runs, in parallel, the jobs whose inputs passed in no run passes remembers
// (every one with passes.all) and adds to passes.now the ones skipped and the ones that
// pass, a job only when its inputs read the same after it ran. ran: how many ran.
check_cached :: proc(jobs: []Check_Job, passes: ^Check_Passes) -> (ok: bool, ran: int) {
	inputs := check_inputs_make()
	run_list := make([dynamic]Check_Job)
	for &job in jobs {
		job.inputs, job.exact = job_inputs_digest(&inputs, job.pkg, job.cmd)
		if !passes.all && job.exact && passes.before[job.inputs] {
			append(&passes.now, job.inputs)
		} else {
			append(&run_list, job)
		}
	}
	if skipped := len(jobs) - len(run_list); skipped > 0 {
		fmt.printfln(
			"check  %d of %d unchanged since they passed (check --all runs them)",
			skipped,
			len(jobs),
		)
	}
	if len(run_list) == 0 {return true, 0}
	ok = run_checks(run_list[:])
	after := check_inputs_make()
	for job in run_list {
		if !job.passed || !job.exact {continue}
		if d, exact := job_inputs_digest(&after, job.pkg, job.cmd); exact && d == job.inputs {
			append(&passes.now, job.inputs)
		}
	}
	return ok, len(run_list)
}

// Check_Passes: the passes read from CHECK_PASSES and the ones this run has seen.
Check_Passes :: struct {
	before: map[Digest]bool,
	order:  []Digest, // as read: the newest first
	now:    [dynamic]Digest, // this run's passes, skipped or run
	all:    bool, // skip nothing (check --all)
	driver: Digest, // the driver's executable, which the per-file checks are code of
	known:  bool, // driver was read: when false no file is skipped or kept
}

// check_passes_read: the passes CHECK_PASSES (at path) keeps (none when it is not there).
check_passes_read :: proc(path: string, all: bool) -> Check_Passes {
	passes := Check_Passes {
		all = all,
	}
	if driver, err := os.read_entire_file_from_path(os.args[0], context.allocator); err == nil {
		passes.driver, passes.known = digest_of(driver), true
	}
	order := make([dynamic]Digest)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			d, ok := strconv.parse_u128_of_base(line, 16)
			if !ok || len(line) != 32 {continue}
			passes.before[d] = true
			append(&order, d)
		}
	}
	passes.order = order[:]
	return passes
}

// check_passes_write keeps this run's passes, then the older ones it did not see, up to
// CHECK_PASSES_KEPT, written whole under another name and renamed over.
check_passes_write :: proc(passes: ^Check_Passes, path: string) {
	b := strings.builder_make()
	kept := make(map[Digest]bool)
	for list in ([][]Digest{passes.now[:], passes.order}) {
		for d in list {
			if kept[d] || len(kept) >= CHECK_PASSES_KEPT {continue}
			kept[d] = true
			fmt.sbprintf(&b, "%032x\n", d)
		}
	}
	tmp := strings.concatenate({path, ".new"})
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)) != nil ||
	   os.rename(tmp, path) != nil {
		os.remove(tmp)
	}
}

// file_passed: whether the per-file check kind (its name, and whatever else it reads
// beside the file and the driver) passed the file at path holding text before (never
// with passes.all), and the digest to keep in passes.now when it passes now (zero: none).
file_passed :: proc(
	passes: ^Check_Passes,
	kind, path: string,
	text: []u8,
) -> (
	digest: Digest,
	passed: bool,
) {
	if !passes.known {return}
	material := fmt.tprintf("%s\n%032x\n%s\n%032x", kind, passes.driver, path, digest_of(text))
	digest = digest_of(transmute([]u8)material)
	return digest, !passes.all && passes.before[digest]
}

// file_pass keeps digest (file_passed's) as passed in this run.
file_pass :: proc(passes: ^Check_Passes, digest: Digest) {
	if digest != 0 {append(&passes.now, digest)}
}

// odinfmt_kind: the odinfmt on PATH, as format_kind names it ("" when it cannot be read).
odinfmt_kind :: proc() -> string {
	exe, found := exe_on_path("odinfmt")
	odinfmt, err := os.read_entire_file_from_path(exe, context.allocator)
	if !found || err != nil {return ""}
	return fmt.aprintf("fmt %s %032x\n", exe, digest_of(odinfmt))
}

// format_kind: what the format check of a file in folder dir reads beside the file and
// the driver: odinfmt (odinfmt_kind) and every odinfmt.json it may read, the folder's own
// and each one's above it. "" when odinfmt is "": the file is compared, never skipped.
format_kind :: proc(kinds: ^map[string]string, odinfmt, dir: string) -> string {
	if odinfmt == "" {return ""}
	if found, seen := kinds[dir]; seen {return found}
	b := strings.builder_make()
	strings.write_string(&b, odinfmt)
	at, _ := filepath.abs(dir, context.allocator)
	for {
		config := path_join({at, "odinfmt.json"})
		if data, err := os.read_entire_file_from_path(config, context.allocator); err == nil {
			fmt.sbprintf(&b, "%s %032x\n", config, digest_of(data))
		} else if os.exists(config) {
			fmt.sbprintf(&b, "%s unreadable\n", config)
		}
		up := filepath.dir(at)
		if up == at {break}
		at = up
	}
	kinds[strings.clone(dir)] = strings.to_string(b)
	return strings.to_string(b)
}
