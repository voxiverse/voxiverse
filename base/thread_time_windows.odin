#+build windows
package base

import "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetThreadTimes :: proc(thread: windows.HANDLE, creation, exit, kernel, user: ^windows.FILETIME) -> windows.BOOL ---
}

// thread_cpu_us is the CPU time this thread has used, in microseconds: what a
// budget test reads, so that other threads and processes taking the core
// during the measurement do not count.
thread_cpu_us :: proc() -> i64 {
	creation, exit, kernel, user: windows.FILETIME
	GetThreadTimes(windows.GetCurrentThread(), &creation, &exit, &kernel, &user)
	ticks :: proc(f: windows.FILETIME) -> i64 {
		return i64(u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime))
	}
	return (ticks(kernel) + ticks(user)) / 10 // 100 ns units
}
