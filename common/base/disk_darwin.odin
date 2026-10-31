package base

import "core:os"
import "core:sys/posix"

// macOS: fsync does not reach the platter; F_FULLFSYNC (command 51, which
// core:sys/posix lacks) does, and fails on some file systems, where fsync is
// what there is.
F_FULLFSYNC :: 51

file_sync :: proc(f: ^os.File) -> os.Error {
	fd := posix.FD(os.fd(f))
	if posix.fcntl(fd, posix.FCNTL_Cmd(F_FULLFSYNC)) == 0 {return nil}
	return os.sync(f)
}

file_rename :: proc(from, to: string) -> os.Error {return os.rename(from, to)}

dir_sync :: proc(path: string) -> bool {
	cpath := cstring_temp(path)
	fd := posix.open(cpath, {})
	if fd < 0 {return false}
	defer posix.close(fd)
	return posix.fsync(fd) == .OK
}
