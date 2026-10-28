package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

import "../base"

// The migration registry. A save from an older format is brought to
// SAVE_FORMAT when it is opened: a backup first (backups/pre-migration-<from>),
// then every migration from its format on, in order, on one Migrator that stages
// its writes; everything staged commits as one transaction (save_tx.odin). A
// failing migration commits nothing.
//
// The rules for writing one are in docs/saves.md: it reads only files of its
// `from` format, with readers frozen beside it; it is never edited once released;
// it is tested from a committed fixture (assets/fixtures/save-v<from>).
// The registry is empty (M47a): older formats are refused, not migrated, before
// 1.0 (docs/saves.md).

Migration :: struct {
	from: int, // the format it reads; it leaves from + 1
	name: string, // what it does, for the log
	run:  proc(m: ^Migrator) -> bool, // false: m.why says why
}

Migrator :: struct {
	dir:        string, // the universe
	disk:       ^base.Disk,
	generation: u64, // the one the transaction commits
	staged:     map[string][]u8, // writes not committed yet, by relative path
	deletes:    [dynamic]string,
	why:        string,
}

@(rodata)
MIGRATIONS := [?]Migration{}

Migrate_Result :: struct {
	from, to: int,
	ok:       bool,
	why:      string,
}

// mig_read: a file's bytes, the staged version if any (temp allocator).
mig_read :: proc(m: ^Migrator, rel: string) -> ([]u8, bool) {
	if data, staged := m.staged[rel]; staged {return data, true}
	for d in m.deletes {if d == rel {return nil, false}}
	data, err := os.read_entire_file_from_path(full_path(m.dir, rel), context.temp_allocator)
	return data, err == nil
}

mig_write :: proc(m: ^Migrator, rel: string, data: []u8) {
	m.staged[rel] = slice.clone(data, context.temp_allocator)
	for d, i in m.deletes {
		if d == rel {unordered_remove(&m.deletes, i); break}
	}
}

mig_delete :: proc(m: ^Migrator, rel: string) {
	delete_key(&m.staged, rel)
	append(&m.deletes, rel)
}

// mig_list: the files of a directory (relative paths) ending in suffix, staged
// ones included, deleted ones left out, sorted.
mig_list :: proc(m: ^Migrator, rel_dir, suffix: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	entries, _ := os.read_all_directory_by_path(full_path(m.dir, rel_dir), context.temp_allocator)
	for e in entries {
		rel := strings.concatenate({rel_dir, "/", e.name}, context.temp_allocator)
		if e.type != .Directory && strings.has_suffix(e.name, suffix) && !mig_deleted(m, rel) {
			append(&out, rel)
		}
	}
	for rel in m.staged {
		if strings.has_prefix(rel, rel_dir) &&
		   strings.has_suffix(rel, suffix) &&
		   strings.count(rel, "/") == strings.count(rel_dir, "/") + 1 &&
		   !slice.contains(out[:], rel) {
			append(&out, rel)
		}
	}
	slice.sort(out[:])
	return out[:]
}

@(private = "file")
mig_deleted :: proc(m: ^Migrator, rel: string) -> bool {
	for d in m.deletes {if d == rel {return true}}
	return false
}

// migrate_universe brings the universe in dir from its format to SAVE_FORMAT
// (a backup first).
migrate_universe :: proc(
	dir: string,
	disk: ^base.Disk,
	from: int,
	generation: u64,
	extra: []Migration = nil, // (tests: a migration made to fail)
) -> Migrate_Result {
	res := Migrate_Result {
		from = from,
		to   = SAVE_FORMAT,
	}
	m := Migrator {
		dir        = dir,
		disk       = disk,
		generation = generation + 1,
		staged     = make(map[string][]u8, 16, context.temp_allocator),
		deletes    = make([dynamic]string, context.temp_allocator),
	}
	if problem := backup_make(dir, fmt.tprintf("pre-migration-%d", from), disk); problem != "" {
		res.why = fmt.tprintf("the backup failed: %s", problem)
		return res
	}
	chain := make([dynamic]Migration, context.temp_allocator)
	append(&chain, ..MIGRATIONS[:])
	append(&chain, ..extra)
	for mig in chain {
		if mig.from < from {continue}
		log.infof(
			"server migrating the save from=%d to=%d what=%q",
			mig.from,
			mig.from + 1,
			mig.name,
		)
		if !mig.run(&m) {
			res.why = m.why
			return res
		}
	}
	// Every format line says the new one; the generation moves on.
	set_line(&m, UNIVERSE_FILE, "format", fmt.tprint(SAVE_FORMAT))
	set_line(&m, UNIVERSE_FILE, "generation", fmt.tprint(m.generation))
	for world in world_dirs(&m) {
		world_cfg := fmt.tprintf("%s/%s", world, WORLD_FILE)
		if _, ok := mig_read(&m, world_cfg); ok {
			set_line(&m, world_cfg, "format", fmt.tprint(SAVE_FORMAT))
		}
	}
	b := batch_make(dir, m.generation, 0, disk)
	defer batch_free(b)
	for rel, data in m.staged {batch_stage(b, rel, data)}
	for rel in m.deletes {batch_delete(b, rel)}
	batch_run(b)
	if b.problem != "" {
		res.why = strings.clone(b.problem, context.temp_allocator)
		return res
	}
	res.ok = true
	return res
}

@(private = "file")
set_line :: proc(m: ^Migrator, rel, key, value: string) {
	data, ok := mig_read(m, rel)
	if !ok {return}
	b := strings.builder_make(context.temp_allocator)
	found := false
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if eq := strings.index_byte(l, '='); eq > 0 && strings.trim_space(l[:eq]) == key {
			if !found {fmt.sbprintfln(&b, "%s = %s", key, value)}
			found = true
			continue
		}
		fmt.sbprintln(&b, line)
	}
	if !found {fmt.sbprintfln(&b, "%s = %s", key, value)}
	mig_write(m, rel, transmute([]u8)strings.to_string(b))
}

// store_migrate: the open's step after the format is known. Saves of an
// older format are refused, not migrated: before 1.0 nothing is compatible
// (the registry above is the way a later format will bring them on).
store_migrate :: proc(s: ^Server) -> bool {
	st := &s.store
	if st.format >= SAVE_FORMAT {return true}
	s.refusal = OLDER_BUILD
	log.errorf("server %s format=%d", OLDER_BUILD, st.format)
	return false
}

// OLDER_BUILD: why a world of an older format is not opened.
OLDER_BUILD :: "this world was made by an older build; create a new one"

// world_dirs: "worlds/<address>" for each world in the universe.
@(private = "file")
world_dirs :: proc(m: ^Migrator) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	entries, _ := os.read_all_directory_by_path(
		full_path(m.dir, WORLDS_DIR),
		context.temp_allocator,
	)
	for e in entries {
		if e.type == .Directory {
			append(&out, strings.concatenate({WORLDS_DIR, "/", e.name}, context.temp_allocator))
		}
	}
	slice.sort(out[:])
	return out[:]
}
