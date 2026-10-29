#+build !windows
package build

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// The driver's own lock. It is not base.file_lock on purpose: the driver has to
// build and run when the project it is building does not, so it may not import it.

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	@(link_name = "flock")
	flock_fd :: proc(fd: c.int, operation: c.int) -> c.int ---
}

@(private = "file")
LOCK_EX :: 2
@(private = "file")
LOCK_NB :: 4

// Build_Lock: an exclusive lock on a file, held while it is open. The OS drops it
// with the process, so a killed run never leaves one behind. The descriptor is
// close-on-exec: a game the run starts does not keep it.
Build_Lock :: struct {
	fd: posix.FD,
	ok: bool,
}

// lock_build takes path for this run and writes text into it. If another run holds
// it, it says which and waits for it to end. ok is false only if the file cannot be
// opened or locked at all.
lock_build :: proc(path, text: string) -> (lock: Build_Lock, ok: bool) {
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.RDWR, .CREAT, .CLOEXEC},
		{.IRUSR, .IWUSR, .IRGRP, .IROTH},
	)
	if fd < 0 {
		fmt.eprintfln("build: could not open the lock '%s': %v", path, posix.errno())
		return
	}
	if flock_fd(c.int(fd), LOCK_EX | LOCK_NB) != 0 {
		holder := "it did not say which"
		if data, err := os.read_entire_file_from_path(path, context.temp_allocator);
		   err == nil && len(strings.trim_space(string(data))) > 0 {
			holder = strings.trim_space(string(data))
		}
		fmt.eprintfln("build: waiting for another run to end (%s)", holder)
		if flock_fd(c.int(fd), LOCK_EX) != 0 {
			fmt.eprintfln("build: could not take the lock '%s': %v", path, posix.errno())
			posix.close(fd)
			return
		}
	}
	posix.ftruncate(fd, 0)
	if len(text) > 0 {posix.pwrite(fd, raw_data(text), uint(len(text)), 0)}
	return {fd, true}, true
}

// unlock_build releases it (the file stays).
unlock_build :: proc(l: ^Build_Lock) {
	if l.ok {posix.close(l.fd)}
	l^ = {}
}
