#+build linux, darwin
package base

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

@(private = "file")
LOCK_EX :: 2
@(private = "file")
LOCK_NB :: 4

// File_Lock: an exclusive lock on a file, held while it is open (the OS drops it
// with the process, so a crash leaves none).
File_Lock :: struct {
	fd: posix.FD,
	ok: bool,
}

// (close-on-exec: a child process must not keep the lock after the server has let go)
// file_lock takes the lock on path (made if missing) and writes text into it.
// ok is false if another process (or another open of it) holds it; holder is
// then what that one wrote (heap, "" if unreadable).
file_lock :: proc(path, text: string) -> (lock: File_Lock, holder: string, ok: bool) {
	cpath := cstring_temp(path)
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
	return {fd, true}, "", true
}

// file_unlock releases the lock (the file stays).
file_unlock :: proc(l: ^File_Lock) {
	if l.ok {posix.close(l.fd)}
	l^ = {}
}
