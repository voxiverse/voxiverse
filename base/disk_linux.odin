package base

import "core:os"
import "core:sys/posix"

file_sync :: proc(f: ^os.File) -> os.Error {return os.sync(f)}

file_rename :: proc(from, to: string) -> os.Error {return os.rename(from, to)}

// dir_sync: fsync on the directory opened read-only.
dir_sync :: proc(path: string) -> bool {
	cpath := cstring_temp(path)
	fd := posix.open(cpath, {})
	if fd < 0 {return false}
	defer posix.close(fd)
	return posix.fsync(fd) == .OK
}
