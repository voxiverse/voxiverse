#+build !linux
package base

// resident_memory is the process's resident memory in bytes (0 where the OS
// does not tell us cheaply).
resident_memory :: proc() -> int {
	return 0
}
