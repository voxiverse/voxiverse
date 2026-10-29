#+build windows
package build

import "core:fmt"
import "core:sys/windows"
import "core:time"

// The driver's own lock (see lock_posix.odin; it is not base.file_lock on purpose).

// Build_Lock: a file opened with no sharing, held while it is open. Windows closes
// it with the process, so a killed run never leaves one behind.
Build_Lock :: struct {
	handle: windows.HANDLE,
	ok:     bool,
}

// lock_build takes path for this run and writes text into it. If another run holds
// it, it waits for it to end (the holder's text cannot be read while it is held).
// ok is false only if the file cannot be opened for another reason.
lock_build :: proc(path, text: string) -> (lock: Build_Lock, ok: bool) {
	wpath := windows.utf8_to_wstring(path, context.temp_allocator)
	said := false
	for {
		h := windows.CreateFileW(
			wpath,
			windows.GENERIC_READ | windows.GENERIC_WRITE,
			0,
			nil,
			windows.OPEN_ALWAYS,
			windows.FILE_ATTRIBUTE_NORMAL,
			nil,
		)
		if h != windows.INVALID_HANDLE_VALUE {
			if len(text) > 0 {
				written: windows.DWORD
				windows.WriteFile(h, raw_data(text), windows.DWORD(len(text)), &written, nil)
			}
			windows.SetEndOfFile(h)
			return {h, true}, true
		}
		if windows.GetLastError() != windows.ERROR_SHARING_VIOLATION {
			fmt.eprintfln("build: could not open the lock '%s'", path)
			return
		}
		if !said {
			fmt.eprintln("build: waiting for another run to end")
			said = true
		}
		time.sleep(200 * time.Millisecond)
	}
}

// unlock_build releases it (the file stays).
unlock_build :: proc(l: ^Build_Lock) {
	if l.ok {windows.CloseHandle(l.handle)}
	l^ = {}
}
