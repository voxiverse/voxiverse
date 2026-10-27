package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
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
	if err := base.disk_mkdir(d, tmp); err != .None {return fmt.tprintf("cannot make %s (%v)", tmp, err)}
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
