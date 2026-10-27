package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../base"

// Backups: a backup is a directory under backups/ holding every file of a
// committed generation, as hard links (a copy where the file system has none):
// saves never change a file in place, they rename new ones over, so the old
// inode stays with the backup and a backup costs a directory entry per file.
// Journal segments are appended to afterwards; the world.cfg in the backup
// records where each ended, so a restore cuts them as the journal's start does.
// Built as <name>.tmp/ and renamed when complete.

BACKUPS_DIR :: "backups"

// backup_make: the universe's files as backups/<name>. "" or what failed.
backup_make :: proc(dir, name: string, d: ^base.Disk) -> string {
	files := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &files)
	root := full_path(dir, fmt.tprintf("%s/%s", BACKUPS_DIR, name))
	tmp := strings.concatenate({root, ".tmp"}, context.temp_allocator)
	if os.exists(root) {return ""}
	os.remove_all(tmp)
	for rel in files {
		if strings.has_suffix(rel, ".new") || strings.has_suffix(rel, ".tmp") || rel == TX_FILE {
			continue
		}
		to := full_path(tmp, rel)
		if err := base.disk_mkdir(d, filepath.dir(to)); err != .None {
			return fmt.tprintf("cannot make %s (%v)", filepath.dir(to), err)
		}
		if err := base.disk_link(d, full_path(dir, rel), to); err != .None {
			return fmt.tprintf("cannot link %s (%v)", rel, err)
		}
	}
	if err := base.disk_mkdir(d, tmp);
	   err != .None {return fmt.tprintf("cannot make %s (%v)", tmp, err)}
	if err := base.disk_rename(d, tmp, root); err != .None {
		return fmt.tprintf("cannot finish the backup %s (%v)", name, err)
	}
	base.disk_sync_dir(d, filepath.dir(root))
	log.infof("server backup made name=%s files=%d", name, len(files))
	return ""
}

// backup_stamp: the UTC time part of a rolling backup's name.
backup_stamp :: proc() -> string {
	t := time.now()
	y, mo, da := time.date(t)
	h, mi, se := time.clock(t)
	return fmt.tprintf("%04d%02d%02d-%02d%02d%02d", y, int(mo), da, h, mi, se)
}

// A rolling backup is made after the first committed save of a run, then once
// BACKUP_EVERY ticks of play have passed; the newest BACKUP_KEEP are kept
// (pre-migration-* and pre-restore-* are never removed by themselves).
BACKUP_EVERY :: 54_000 // 30 minutes of play
BACKUP_KEEP :: 5

// backup_names: the rolling backups (g<generation>-<time>), oldest first.
backup_names :: proc(dir: string) -> []string {
	entries, err := os.read_all_directory_by_path(
		full_path(dir, BACKUPS_DIR),
		context.temp_allocator,
	)
	names := make([dynamic]string, context.temp_allocator)
	if err != nil {return names[:]}
	for e in entries {
		if e.type == .Directory &&
		   strings.has_prefix(e.name, "g") &&
		   !strings.has_suffix(e.name, ".tmp") {
			append(&names, e.name)
		}
	}
	slice.sort(names[:])
	return names[:]
}

// backup_rotate removes the oldest rolling backups beyond keep, and the
// unfinished ones a crash left.
backup_rotate :: proc(dir: string, keep: int) {
	root := full_path(dir, BACKUPS_DIR)
	if entries, err := os.read_all_directory_by_path(root, context.temp_allocator); err == nil {
		for e in entries {
			if strings.has_suffix(e.name, ".tmp") {os.remove_all(full_path(root, e.name))}
		}
	}
	names := backup_names(dir)
	for name in names[:max(0, len(names) - keep)] {
		os.remove_all(full_path(root, name))
		log.infof("server removed an old backup name=%s", name)
	}
}

// backup_run: a rolling backup of the committed generation, then rotation. A
// backup that fails never affects the save: it is logged.
backup_run :: proc(dir: string, generation: u64, keep: int, d: ^base.Disk) {
	name := fmt.tprintf("g%08d-%s", generation, backup_stamp())
	if problem := backup_make(dir, name, d); problem != "" {
		log.warnf("server backup failed name=%s problem=%s", name, problem)
		return
	}
	backup_rotate(dir, keep)
}

// universe_restore puts a backup's files in place of the universe's, as one
// transaction after a pre-restore backup. name is a directory of backups/, or
// "latest" (the newest rolling one). "" or what is wrong.
universe_restore :: proc(dir, name: string, d: ^base.Disk) -> string {
	if problem := store_recover(dir, d); problem != "" {return problem}
	name := name
	if name == "latest" {
		names := backup_names(dir)
		if len(names) == 0 {return "there is no backup to restore"}
		name = names[len(names) - 1]
	}
	if name == "" || strings.contains(name, "/") || strings.contains(name, "\\") || name == ".." {
		return fmt.tprintf("%q is not a backup name", name)
	}
	root := full_path(dir, fmt.tprintf("%s/%s", BACKUPS_DIR, name))
	if !os.exists(root) {return fmt.tprintf("there is no backup %s", name)}
	generation := u64(0)
	if cfg, err := os.read_entire_file_from_path(
		full_path(dir, UNIVERSE_FILE),
		context.temp_allocator,
	); err == nil {
		text, _ := text_value(string(cfg), "generation")
		generation, _ = strconv.parse_u64(text, 10)
	}
	if problem := backup_make(dir, fmt.tprintf("pre-restore-g%d", generation), d); problem != "" {
		return fmt.tprintf("the backup before the restore failed: %s", problem)
	}
	b := batch_make(dir, generation + 1, 0, d)
	defer batch_free(b)
	have := make([dynamic]string, context.temp_allocator)
	walk_files(root, "", &have)
	for rel in have {
		if strings.has_suffix(rel, ".new") ||
		   strings.has_suffix(rel, ".tmp") ||
		   rel == TX_FILE {continue}
		data, err := os.read_entire_file_from_path(full_path(root, rel), context.temp_allocator)
		if err != nil {return fmt.tprintf("cannot read %s in the backup (%v)", rel, err)}
		if rel == UNIVERSE_FILE {data = restamp_generation(data, generation + 1)}
		batch_stage(b, rel, data)
	}
	now := make([dynamic]string, context.temp_allocator)
	walk_files(dir, "", &now)
	for rel in now {
		if strings.has_suffix(rel, ".new") || strings.has_suffix(rel, ".tmp") {continue}
		in_backup := false
		for h in have {if h == rel {in_backup = true; break}}
		if !in_backup {batch_delete(b, rel)}
	}
	batch_run(b)
	if b.problem != "" {return strings.clone(b.problem, context.temp_allocator)}
	log.infof("server restored the universe from=%s generation=%d", name, generation + 1)
	return ""
}

// restamp_generation: universe.cfg with its generation line set.
restamp_generation :: proc(cfg: []u8, generation: u64) -> []u8 {
	out := strings.builder_make(context.temp_allocator)
	rest := string(cfg)
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(strings.trim_space(line), "generation") {
			fmt.sbprintfln(&out, "generation = %d", generation)
		} else {
			fmt.sbprintfln(&out, "%s", line)
		}
	}
	return out.buf[:]
}
