#+build linux, darwin
package platform_common

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

import "common:base"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

@(private = "file")
LOCK_EX :: 2
@(private = "file")
LOCK_NB :: 4

// lock_file takes an exclusive flock on path (made if missing; close-on-exec, so a child
// process does not keep the lock after the server has let go) and writes text into it.
// ok is false if another process (or another open of it) holds it; holder is then what
// that one wrote (heap, "" if unreadable). The OS drops the lock with the process.
@(private)
lock_file :: proc(path, text: string) -> (lock: base.File_Lock, holder: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	if flock(c.int(fd), LOCK_EX | LOCK_NB) != 0 {
		posix.close(fd)
		if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
			holder = strings.trim_space(string(data))
		}
		return
	}
	posix.ftruncate(fd, 0)
	if len(text) > 0 {posix.write(fd, raw_data(text), uint(len(text)))}
	return {uintptr(fd), true}, "", true
}

// unlock_file releases the lock (the file stays).
@(private)
unlock_file :: proc(l: ^base.File_Lock) {
	if l.ok {posix.close(posix.FD(l.handle))}
	l^ = {}
}
