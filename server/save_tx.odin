package server

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import "../base"
import "../common/game"

// The save transaction: a save writes every file or none.
//
//  1. Prepare: each file of the save is written as <path>.new (synced).
//  2. Commit: save.tx, listing the renames and deletions with the CRC of each
//     .new file, is written with disk_replace. It is the commit point.
//  3. Apply: each .new is renamed over its final name, deletions done, each
//     directory touched synced, and save.tx removed.
//
// store_recover runs first when a universe is opened: a whole save.tx is
// applied again (a rename whose .new is gone and whose file has the recorded
// CRC was done already); no save.tx means the save had not committed, and
// every .new and .tmp is removed, leaving the previous generation whole.
//
// The batch is built on the server thread (the files encoded, as ever) and
// run by the save worker, a base.Jobs with one thread (none in a stepped
// server: the batch runs inside save, which the crash tests rely on).

TX_FILE :: "save.tx"
TX_MAGIC :: "VXTX"
TX_FORMAT :: 1

Tx_Kind :: enum u8 {
	Rename = 1, // .new over the final name
	Delete = 2,
}

// Prepared: one file of a batch. Paths are relative to the universe, with '/'.
Prepared :: struct {
	path:  string,
	bytes: []u8,
}

// Save_Batch: everything one save writes (heap: it is handed to the worker).
Save_Batch :: struct {
	dir:        string,
	generation: u64,
	age:        u64,
	files:      [dynamic]Prepared,
	deletes:    [dynamic]string,
	disk:       ^base.Disk,
	// The worker's result.
	problem:    string, // "" when it committed and applied
	done:       bool, // (atomic)
}

@(private = "file")
heap :: proc() -> runtime.Allocator {return runtime.heap_allocator()}

batch_make :: proc(dir: string, generation, age: u64, disk: ^base.Disk) -> ^Save_Batch {
	a := heap()
	b := new(Save_Batch, a)
	b.dir = strings.clone(dir, a)
	b.generation, b.age, b.disk = generation, age, disk
	b.files = make([dynamic]Prepared, a)
	b.deletes = make([dynamic]string, a)
	return b
}

batch_free :: proc(b: ^Save_Batch) {
	a := heap()
	for f in b.files {
		delete(f.path, a)
		delete(f.bytes, a)
	}
	for d in b.deletes {delete(d, a)}
	delete(b.files)
	delete(b.deletes)
	delete(b.dir, a)
	delete(b.problem, a)
	free(b, a)
}

// batch_stage adds a file (later staging of the same path replaces it).
batch_stage :: proc(b: ^Save_Batch, rel: string, data: []u8) {
	a := heap()
	for &f in b.files {
		if f.path == rel {
			delete(f.bytes, a)
			f.bytes = slice.clone(data, a)
			return
		}
	}
	append(&b.files, Prepared{strings.clone(rel, a), slice.clone(data, a)})
	// (a file staged after being deleted is not deleted)
	for d, i in b.deletes {
		if d == rel {
			delete(d, a)
			unordered_remove(&b.deletes, i)
			break
		}
	}
}

batch_delete :: proc(b: ^Save_Batch, rel: string) {
	a := heap()
	for f, i in b.files {
		if f.path == rel {
			delete(f.path, a)
			delete(f.bytes, a)
			unordered_remove(&b.files, i)
			break
		}
	}
	for d in b.deletes {if d == rel {return}}
	append(&b.deletes, strings.clone(rel, a))
}

// relative_path: path (under dir) as the transaction names it.
relative_path :: proc(dir, path: string) -> string {
	rel := path
	if strings.has_prefix(path, dir) {rel = strings.trim_left(path[len(dir):], "/\\")}
	when ODIN_OS == .Windows {
		rel, _ = strings.replace_all(rel, "\\", "/", context.temp_allocator)
	}
	return rel
}

@(private = "file")
full_path :: proc(dir, rel: string) -> string {
	return filepath.join({dir, rel}, context.temp_allocator) or_else rel
}

@(private = "file")
disk_problem :: proc(what, path: string, err: base.Disk_Error) -> string {
	return fmt.aprintf("%s %s (%v)", what, path, err, allocator = heap())
}

// batch_run prepares, commits and applies b. The first problem is left in
// b.problem. Runs on the save worker (or inline).
batch_run :: proc(b: ^Save_Batch) {
	defer sync.atomic_store(&b.done, true)
	d := b.disk
	// 1. Prepare.
	made := make(map[string]bool, 8, context.temp_allocator)
	for f in b.files {
		path := full_path(b.dir, f.path)
		parent := filepath.dir(path)
		if parent not_in made {
			if err := base.disk_mkdir(d, parent); err != .None {
				b.problem = disk_problem("cannot make", parent, err)
				return
			}
			made[parent] = true
		}
		if err := base.disk_write(d, strings.concatenate({path, ".new"}, context.temp_allocator), f.bytes);
		   err != .None {
			b.problem = disk_problem("cannot write", path, err)
			return
		}
	}
	// 2. Commit.
	tx := tx_encode(b)
	tx_path := full_path(b.dir, TX_FILE)
	if err := base.disk_replace(d, tx_path, tx); err != .None {
		b.problem = disk_problem("cannot commit", tx_path, err)
		return
	}
	// 3. Apply.
	if problem := tx_apply(d, b.dir, tx); problem != "" {b.problem = problem}
}

@(private = "file")
tx_encode :: proc(b: ^Save_Batch) -> []u8 {
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	for c in TX_MAGIC {game.write_u8(&w, u8(c))}
	game.write_u32(&w, TX_FORMAT)
	game.write_varint64(&w, b.generation)
	game.write_varint64(&w, b.age)
	game.write_varint(&w, u32(len(b.files) + len(b.deletes)))
	for f in b.files {
		game.write_u8(&w, u8(Tx_Kind.Rename))
		game.write_string(&w, f.path)
		game.write_u32(&w, hash.crc32(f.bytes))
	}
	for p in b.deletes {
		game.write_u8(&w, u8(Tx_Kind.Delete))
		game.write_string(&w, p)
		game.write_u32(&w, 0)
	}
	game.write_u32(&w, hash.crc32(w.buf[:]))
	return w.buf[:]
}

Tx_Op :: struct {
	kind: Tx_Kind,
	path: string,
	crc:  u32,
}

// tx_decode: the operations of a whole save.tx.
tx_decode :: proc(data: []u8) -> (ops: [dynamic]Tx_Op, generation, age: u64, ok: bool) {
	if len(data) < 4 + 4 + 4 || string(data[:4]) != TX_MAGIC {return}
	body := data[:len(data) - 4]
	tail := game.reader_make(data[len(data) - 4:])
	if game.read_u32(&tail) != hash.crc32(body) {return}
	r := game.reader_make(body[4:])
	if game.read_u32(&r) != TX_FORMAT {return}
	generation = game.read_varint64(&r)
	age = game.read_varint64(&r)
	n := game.read_varint(&r)
	if !r.ok || n > 1 << 20 {return}
	ops = make([dynamic]Tx_Op, context.temp_allocator)
	for _ in 0 ..< n {
		kind := Tx_Kind(game.read_u8(&r))
		path := game.read_string(&r, 1024)
		crc := game.read_u32(&r)
		if !r.ok || (kind != .Rename && kind != .Delete) || !tx_path_safe(path) {return}
		append(&ops, Tx_Op{kind, path, crc})
	}
	return ops, generation, age, game.reader_finish(&r)
}

// tx_path_safe: a relative path that stays inside the universe.
@(private = "file")
tx_path_safe :: proc(p: string) -> bool {
	if p == "" || p[0] == '/' || strings.contains(p, "\\") || strings.contains(p, ":") {return false}
	for part in strings.split(p, "/", context.temp_allocator) {
		if part == "" || part == ".." || part == "." {return false}
	}
	return true
}

// tx_apply: renames, deletions, directory syncs, then save.tx removed. Safe
// to run again after a crash in the middle.
tx_apply :: proc(d: ^base.Disk, dir: string, tx: []u8) -> string {
	ops, _, _, ok := tx_decode(tx)
	if !ok {return fmt.aprintf("save.tx does not read", allocator = heap())}
	dirs := make(map[string]bool, 8, context.temp_allocator)
	for op in ops {
		path := full_path(dir, op.path)
		dirs[filepath.dir(path)] = true
		switch op.kind {
		case .Rename:
			new_path := strings.concatenate({path, ".new"}, context.temp_allocator)
			if os.exists(new_path) {
				if err := base.disk_rename(d, new_path, path); err != .None {
					return disk_problem("cannot replace", path, err)
				}
			} else {
				// Done already (or damaged: the file must have the recorded CRC).
				data, err := os.read_entire_file_from_path(path, context.temp_allocator)
				if err != nil || hash.crc32(data) != op.crc {
					return fmt.aprintf(
						"this save is damaged (%s): restore a backup (--restore)",
						op.path,
						allocator = heap(),
					)
				}
			}
		case .Delete:
			if err := base.disk_remove(d, path); err != .None {
				return disk_problem("cannot delete", path, err)
			}
		}
	}
	for sub in dirs {
		if err := base.disk_sync_dir(d, sub); err != .None {
			return disk_problem("cannot sync", sub, err)
		}
	}
	tx_path := full_path(dir, TX_FILE)
	if err := base.disk_remove(d, tx_path); err != .None {
		return disk_problem("cannot remove", tx_path, err)
	}
	if err := base.disk_sync_dir(d, dir); err != .None {
		return disk_problem("cannot sync", dir, err)
	}
	return ""
}

// store_recover brings a universe directory to a whole generation. "" when it
// did; else what is wrong (the open fails with it).
store_recover :: proc(dir: string, d: ^base.Disk) -> string {
	tx_path := full_path(dir, TX_FILE)
	if data, err := os.read_entire_file_from_path(tx_path, context.temp_allocator); err == nil {
		if _, _, _, ok := tx_decode(data); ok {
			log.infof("server finishing a save that committed dir=%s", dir)
			problem := tx_apply(d, dir, data)
			if problem != "" {
				defer delete(problem, heap())
				return strings.clone(problem, context.temp_allocator)
			}
			return ""
		}
	}
	// Not committed: what it prepared goes.
	leftovers := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &leftovers)
	removed := 0
	for rel in leftovers {
		if strings.has_suffix(rel, ".new") || strings.has_suffix(rel, ".tmp") || rel == TX_FILE {
			if base.disk_remove(d, full_path(dir, rel)) == .None {removed += 1}
		}
	}
	if removed > 0 {log.infof("server removed an unfinished save files=%d dir=%s", removed, dir)}
	return ""
}

// walk_files lists the files under dir/rel (relative, '/'), without the
// directories backups/, telemetry/ and exports/.
walk_files :: proc(dir, rel: string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(full_path(dir, rel), context.temp_allocator)
	if err != nil {return}
	for e in entries {
		sub := e.name if rel == "" else strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if rel == "" && (e.name == "backups" || e.name == "telemetry" || e.name == "exports") {
				continue
			}
			walk_files(dir, sub, out)
		} else {
			append(out, sub)
		}
	}
}

// ---- the store's side: staging, the worker, the result ----

// Carry: the files of a save that failed, written again by the next one.
Carry :: struct {
	files:   [dynamic]Prepared,
	deletes: [dynamic]string,
}

carry_clear :: proc(c: ^Carry) {
	a := heap()
	for f in c.files {
		delete(f.path, a)
		delete(f.bytes, a)
	}
	for p in c.deletes {delete(p, a)}
	clear(&c.files)
	clear(&c.deletes)
}

// store_stage starts collecting a save's files; false if one is being
// collected already (a world saved inside a save).
store_stage :: proc(s: ^Server) -> (started: bool) {
	st := &s.store
	if st.dir == "" || st.staging != nil {return false}
	save_wait(s)
	st.staging = batch_make(st.dir, st.generation + 1, age_of(s), &st.disk)
	// What a failed save carried comes first (anything staged since replaces it).
	for f in st.carry.files {batch_stage(st.staging, f.path, f.bytes)}
	for p in st.carry.deletes {batch_delete(st.staging, p)}
	return true
}

// store_write: path (in the universe) is part of the save being collected;
// outside a save it is replaced at once. False if it could not be.
store_write :: proc(s: ^Server, path: string, data: []u8) -> bool {
	st := &s.store
	if st.staging != nil {
		batch_stage(st.staging, relative_path(st.dir, path), data)
		return true
	}
	save_wait(s) // (the worker may be renaming over it)
	if err := base.disk_replace(&st.disk, path, data); err != .None {
		log.errorf("server cannot write path=%s error=%v", path, err)
		return false
	}
	return true
}

// store_delete: path is removed with the save (at once outside one).
store_delete :: proc(s: ^Server, path: string) {
	st := &s.store
	if st.staging != nil {
		batch_delete(st.staging, relative_path(st.dir, path))
		return
	}
	save_wait(s)
	base.disk_remove(&st.disk, path)
}

// store_commit hands the collected files to the worker; with wait, returns when
// it is done. False if that save failed (logged).
store_commit :: proc(s: ^Server, wait: bool) -> bool {
	st := &s.store
	b := st.staging
	st.staging = nil
	if b == nil {return true}
	carry_clear(&st.carry)
	st.inflight = b
	if !st.jobs_ready {
		base.jobs_init(&st.jobs, "save", 0 if s.config.stepped else 1, heap())
		st.jobs_ready = true
	}
	base.jobs_submit(&st.jobs, proc(data: rawptr) {
			batch_run((^Save_Batch)(data))
		}, b)
	if wait {return save_wait(s)}
	return save_poll(s)
}

// save_wait blocks until the batch in flight is done; false if it failed.
save_wait :: proc(s: ^Server) -> bool {
	st := &s.store
	for st.inflight != nil && !sync.atomic_load(&st.inflight.done) {
		sync.cpu_relax()
	}
	return save_poll(s)
}

// save_poll collects a finished batch (each tick): its generation counts, or its
// files wait for the next save. True unless a failure was just collected.
save_poll :: proc(s: ^Server) -> bool {
	st := &s.store
	b := st.inflight
	if b == nil || !sync.atomic_load(&b.done) {return true}
	st.inflight = nil
	defer batch_free(b)
	if b.problem == "" {
		st.generation = b.generation
		st.saved_at = b.age
		return true
	}
	log.errorf("server save failed generation=%d problem=%s", b.generation, b.problem)
	// Its files are written again by the next save (unless newer ones replace them).
	a := heap()
	for f in b.files {
		append(&st.carry.files, Prepared{strings.clone(f.path, a), slice.clone(f.bytes, a)})
	}
	for p in b.deletes {append(&st.carry.deletes, strings.clone(p, a))}
	return false
}

// store_workers_stop waits for the worker and frees it.
store_workers_stop :: proc(s: ^Server) {
	st := &s.store
	save_wait(s)
	if st.staging != nil {batch_free(st.staging); st.staging = nil}
	if st.jobs_ready {
		base.jobs_destroy(&st.jobs)
		st.jobs_ready = false
	}
	carry_clear(&st.carry)
}
