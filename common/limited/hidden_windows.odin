#+build windows
package limited

import "core:os"
import win "core:sys/windows"

// start_hidden starts desc as os.process_start does (its stdout and stderr; stdin the null
// device; this process's environment), but with no console window: a windowed program
// (the game) that starts a console one (curl.exe, tar.exe) otherwise opens a window for
// it, which stays up as long as the child runs. os.process_start takes no creation flags.
start_hidden :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	assert(
		desc.env == nil && desc.working_dir == "" && desc.stdin == nil,
		"start_hidden: no environment, folder or stdin of its own",
	)
	line := win.utf8_to_wstring(command_line(desc.command), context.temp_allocator)
	null := win.CreateFileW(
		win.L("NUL"),
		win.GENERIC_READ | win.GENERIC_WRITE,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
		&win.SECURITY_ATTRIBUTES {
			nLength = size_of(win.SECURITY_ATTRIBUTES),
			bInheritHandle = true,
		},
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	defer win.CloseHandle(null)
	handle :: proc(f: ^os.File, null: win.HANDLE) -> win.HANDLE {
		return win.HANDLE(os.fd(f)) if f != nil else null
	}
	info: win.PROCESS_INFORMATION
	if !win.CreateProcessW(
		nil,
		line,
		nil,
		nil,
		true,
		win.CREATE_NO_WINDOW | win.NORMAL_PRIORITY_CLASS,
		nil,
		nil,
		&win.STARTUPINFOW {
			cb = size_of(win.STARTUPINFOW),
			hStdError = handle(desc.stderr, null),
			hStdOutput = handle(desc.stdout, null),
			hStdInput = null,
			dwFlags = win.STARTF_USESTDHANDLES,
		},
		&info,
	) {
		return {}, os.Platform_Error(win.GetLastError())
	}
	win.CloseHandle(info.hThread)
	return {pid = int(info.dwProcessId), handle = uintptr(info.hProcess)}, nil
}
