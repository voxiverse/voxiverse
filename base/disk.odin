package base

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The disk layer: every write of a save goes through here, so that it is
// durable (synced, not just handed to the OS) and so that tests can make the
// "process" die at any one operation (Disk_Faults) and look at what is left.
// The OS calls that differ are in disk_linux.odin, disk_darwin.odin,
// disk_windows.odin; what core:os does the same everywhere is used as is.
//
// Everything is an operation that may fail; the first failure of a batch is
// what the caller logs. A Disk with faults, once crashed, refuses everything,
// like a dead process.

DISK_PIECE :: 64 * 1024 // a write goes in pieces of this size (a fault can tear between them)

Disk_Error :: enum u8 {
	None,
	Failed, // the OS refused (the path is in the log)
	Crashed, // a test's fault fired: the process is "dead"
}

Disk :: struct {
	faults: ^Disk_Faults, // nil in production
}

// Disk_Faults: tests only. Operation number `countdown` is torn (a write puts
// a seeded prefix of its piece, a rename or remove happens or not by a seeded
// coin) and every later one does nothing. With power_loss, the crash also
// cuts every file written since its last sync to a seeded length.
Disk_Faults :: struct {
	countdown:  int, // the operation to tear (1 = the first); 0: none
	ops:        int, // operations so far
	crashed:    bool,
	rng:        Rng,
	power_loss: bool,
	unsynced:   [dynamic]Unsynced,
}

Unsynced :: struct {
	path:   string, // (owned)
	synced: i64, // the length the last sync made safe
}

disk_faults_destroy :: proc(f: ^Disk_Faults) {
	for u in f.unsynced {delete(u.path)}
	delete(f.unsynced)
	f.unsynced = nil
}

// disk_count: counts one operation; .Crashed when it is torn or after.
@(private = "file")
disk_count :: proc(d: ^Disk) -> (torn: bool, err: Disk_Error) {
	f := d.faults
	if f == nil {return false, .None}
	if f.crashed {return false, .Crashed}
	f.ops += 1
	if f.countdown > 0 && f.ops >= f.countdown {
		f.crashed = true
		return true, .None
	}
	return false, .None
}

// disk_coin: a seeded yes or no.
@(private = "file")
disk_coin :: proc(d: ^Disk) -> bool {
	return rng_int_max(&d.faults.rng, 2) == 1
}

// disk_die: the fault fired (after the torn operation): lose what a power cut
// loses.
@(private = "file")
disk_die :: proc(d: ^Disk) -> Disk_Error {
	f := d.faults
	if f.power_loss {
		for u in f.unsynced {
			info, err := os.stat(u.path, context.temp_allocator)
			if err != nil {continue}
			size := i64(info.size)
			if size <= u.synced {continue}
			keep := u.synced + i64(rng_int_max(&f.rng, int(size - u.synced) + 1))
			if file, oerr := os.open(u.path, {.Write}); oerr == nil {
				os.truncate(file, keep)
				os.close(file)
			}
		}
	}
	return .Crashed
}

@(private = "file")
disk_track :: proc(d: ^Disk, path: string, synced: i64) {
	f := d.faults
	if f == nil || !f.power_loss {return}
	for &u in f.unsynced {
		if u.path == path {
			u.synced = synced
			return
		}
	}
	append(&f.unsynced, Unsynced{strings.clone(path), synced})
}

@(private = "file")
disk_untrack :: proc(d: ^Disk, path: string, to := "") {
	f := d.faults
	if f == nil {return}
	for u, i in f.unsynced {
		if u.path == path {
			if to == "" {
				delete(u.path)
				unordered_remove(&f.unsynced, i)
			} else {
				f.unsynced[i].path = strings.clone(to)
				delete(u.path)
			}
			return
		}
	}
}

// disk_write creates or truncates path and writes data, in pieces, then syncs
// and closes it.
disk_write :: proc(d: ^Disk, path: string, data: []u8) -> Disk_Error {
	if _, err := disk_count(d); err != .None {return err}
	f := d.faults
	file, oerr := os.create(path)
	if oerr != nil {
		disk_log("create", path, oerr)
		return .Failed
	}
	defer os.close(file)
	if f != nil {disk_untrack(d, path); disk_track(d, path, 0)}
	rest := data
	for len(rest) > 0 || len(data) == 0 {
		piece := rest[:min(len(rest), DISK_PIECE)]
		if f != nil && len(data) > 0 {
			torn, err := disk_count(d)
			if err != .None {return err}
			if torn {
				os.write(file, piece[:rng_int_max(&f.rng, len(piece) + 1)])
				return disk_die(d)
			}
		}
		if _, werr := os.write(file, piece); werr != nil {
			disk_log("write", path, werr)
			return .Failed
		}
		rest = rest[len(piece):]
		if len(data) == 0 {break}
	}
	return disk_sync_file(d, file, path)
}

// disk_sync_file makes a file's data safe (the OS's strongest flush).
disk_sync_file :: proc(d: ^Disk, file: ^os.File, path: string) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {return disk_die(d)}
	if serr := file_sync(file); serr != nil {
		disk_log("sync", path, serr)
		return .Failed
	}
	if d.faults != nil {disk_untrack(d, path)}
	return .None
}

// disk_sync_path makes a file's data safe by its path (the save worker syncs the
// journal segment the server thread has open).
disk_sync_path :: proc(d: ^Disk, path: string) -> Disk_Error {
	file, err := os.open(path, {.Write})
	if err != nil {
		disk_log("open", path, err)
		return .Failed
	}
	defer os.close(file)
	return disk_sync_file(d, file, path)
}

// disk_append opens path (made if missing) at its end, writes data, and syncs
// if sync is set; for journal segments.
disk_append :: proc(d: ^Disk, path: string, data: []u8, sync := false) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	file, oerr := os.open(path, {.Write, .Create}, os.Permissions_Default_File)
	if oerr != nil {
		disk_log("open", path, oerr)
		return .Failed
	}
	defer os.close(file)
	size, _ := os.seek(file, 0, .End)
	if d.faults != nil {disk_track(d, path, size)}
	if torn {
		os.write(file, data[:rng_int_max(&d.faults.rng, len(data) + 1)])
		return disk_die(d)
	}
	if _, werr := os.write(file, data); werr != nil {
		disk_log("append", path, werr)
		return .Failed
	}
	if sync {return disk_sync_file(d, file, path)}
	return .None
}

// disk_truncate cuts path to size bytes.
disk_truncate :: proc(d: ^Disk, path: string, size: i64) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {
		if disk_coin(d) {_ = disk_truncate_now(path, size)}
		return disk_die(d)
	}
	if !disk_truncate_now(path, size) {return .Failed}
	return .None
}

@(private = "file")
disk_truncate_now :: proc(path: string, size: i64) -> bool {
	file, oerr := os.open(path, {.Write})
	if oerr != nil {
		disk_log("open", path, oerr)
		return false
	}
	defer os.close(file)
	if terr := os.truncate(file, size); terr != nil {
		disk_log("truncate", path, terr)
		return false
	}
	return true
}

// disk_rename moves from over to (replacing it), atomically.
disk_rename :: proc(d: ^Disk, from, to: string) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {
		if disk_coin(d) {
			_ = file_rename(from, to)
			if d.faults != nil {disk_untrack(d, from, to)}
		}
		return disk_die(d)
	}
	if rerr := file_rename(from, to); rerr != nil {
		disk_log("rename", from, rerr)
		return .Failed
	}
	if d.faults != nil {disk_untrack(d, from, to)}
	return .None
}

// disk_remove deletes a file (one that is not there is fine).
disk_remove :: proc(d: ^Disk, path: string) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {
		if disk_coin(d) {_ = os.remove(path)}
		return disk_die(d)
	}
	if rerr := os.remove(path); rerr != nil && rerr != .Not_Exist {
		disk_log("remove", path, rerr)
		return .Failed
	}
	if d.faults != nil {disk_untrack(d, path)}
	return .None
}

// disk_mkdir makes a directory and its parents.
disk_mkdir :: proc(d: ^Disk, path: string) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {
		if disk_coin(d) {_ = os.make_directory_all(path)}
		return disk_die(d)
	}
	if merr := os.make_directory_all(path); merr != nil && merr != .Exist {
		disk_log("mkdir", path, merr)
		return .Failed
	}
	return .None
}

// disk_sync_dir makes the entries of a directory (its renames, creations and
// removals) safe. (Windows: a no-op; its renames write through.)
disk_sync_dir :: proc(d: ^Disk, path: string) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {return disk_die(d)}
	if !dir_sync(path) {
		disk_log("sync directory", path, nil)
		return .Failed
	}
	return .None
}

// disk_link makes to another name for from (a hard link; a copy where the
// file system has none).
disk_link :: proc(d: ^Disk, from, to: string) -> Disk_Error {
	torn, err := disk_count(d)
	if err != .None {return err}
	if torn {
		if disk_coin(d) {_ = os.link(from, to)}
		return disk_die(d)
	}
	if lerr := os.link(from, to); lerr != nil {
		if cerr := os.copy_file(to, from); cerr != nil {
			disk_log("link", from, cerr)
			return .Failed
		}
	}
	return .None
}

// disk_replace replaces path with data, atomically and durably: a temporary
// file next to it, synced, renamed over it, the directory synced.
disk_replace :: proc(d: ^Disk, path: string, data: []u8) -> Disk_Error {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	disk_write(d, tmp, data) or_return
	disk_rename(d, tmp, path) or_return
	return disk_sync_dir(d, filepath.dir(path))
}

@(private = "file")
disk_log :: proc(what, path: string, err: any) {
	fmt.eprintfln("disk: %s failed path=%s error=%v", what, path, err)
}

cstring_temp :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}
