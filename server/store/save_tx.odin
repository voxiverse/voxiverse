package store

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import "common:base"
import "common:game"

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
	export_to:  string, // after the commit, the universe as a .vxu file here (export.odin)
	syncs:      [dynamic]string, // files the worker makes safe before the commit (journal segments)
	regions:    [dynamic]^Region_Job, // regions the worker compacts and encodes (compact.odin)
	disk:       ^base.Disk,
	backup:     int, // > 0: a rolling backup follows the commit, keeping this many
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
	b.regions = make([dynamic]^Region_Job, a)
	b.syncs = make([dynamic]string, a)
	return b
}

batch_free :: proc(b: ^Save_Batch) {
	a := heap()
	for f in b.files {
		delete(f.path, a)
		delete(f.bytes, a)
	}
	for d in b.deletes {delete(d, a)}
	for j in b.regions {region_job_free(j)}
	delete(b.regions)
	for p in b.syncs {delete(p, a)}
	delete(b.syncs)
	delete(b.files)
	delete(b.deletes)
	delete(b.dir, a)
	delete(b.problem, a)
	delete(b.export_to, a)
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

// batch_sync: the worker syncs this file (absolute path) before it commits.
batch_sync :: proc(b: ^Save_Batch, path: string) {
	for p in b.syncs {if p == path {return}}
	append(&b.syncs, strings.clone(path, heap()))
}

batch_has :: proc(b: ^Save_Batch, rel: string) -> bool {
	for f in b.files {if f.path == rel {return true}}
	return false
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
	// (Windows spells a joined path with '\\' and a configured one with '/':
	// compare with one separator, or the prefix is missed and the file lands
	// in a nested directory of its own path.)
	slashed :: proc(s: string) -> string {
		when ODIN_OS == .Windows {
			r, _ := strings.replace_all(s, "\\", "/", context.temp_allocator)
			return r
		} else {
			return s
		}
	}
	d, p := slashed(dir), slashed(path)
	if strings.has_prefix(p, d) {p = p[len(d):]}
	return strings.trim_left(p, "/")
}

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
	// 0. The regions: compacted and encoded here, off the server thread.
	for j in b.regions {region_job_run(b, j)}
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
		if err := base.disk_write(
			d,
			strings.concatenate({path, ".new"}, context.temp_allocator),
			f.bytes,
		); err != .None {
			b.problem = disk_problem("cannot write", path, err)
			return
		}
	}
	for path in b.syncs {
		if err := base.disk_sync_path(d, path); err != .None {
			b.problem = disk_problem("cannot sync", path, err)
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
	if problem := tx_apply(d, b.dir, tx); problem != "" {
		b.problem = problem
		return
	}
	if b.export_to != "" {
		if why := export_write(b.dir, b.export_to, d); why != "" {
			log.errorf("server export failed file=%s problem=%s", b.export_to, why)
		}
	}
	// 4. A backup, if one is due (it never affects the save).
	if b.backup > 0 {backup_run(b.dir, b.generation, b.backup, d)}
}

@(private)
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
@(private)
tx_path_safe :: proc(p: string) -> bool {
	if p == "" ||
	   p[0] == '/' ||
	   strings.contains(p, "\\") ||
	   strings.contains(p, ":") {return false}
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
// directories backups/, telemetry/, analytics/ (the session recordings) and exports/.
walk_files :: proc(dir, rel: string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(full_path(dir, rel), context.temp_allocator)
	if err != nil {return}
	for e in entries {
		sub :=
			e.name if rel == "" else strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if rel == "" &&
			   (e.name == "backups" ||
					   e.name == "telemetry" ||
					   e.name == "analytics" ||
					   e.name == "exports") {
				continue
			}
			walk_files(dir, sub, out)
		} else if rel != "" || e.name != UNIVERSE_LOCK {
			append(out, sub)
		}
	}
}
