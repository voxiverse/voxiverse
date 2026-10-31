#+build windows
package base

import "core:sys/windows"

// File_Lock: a file opened with no sharing, held while it is open (Windows
// closes it with the process, so a crash leaves none).
File_Lock :: struct {
	handle: windows.HANDLE,
	ok:     bool,
}

// file_lock opens path (made if missing) with no sharing and writes text into
// it. ok is false if another process (or another open of it) has it; the
// holder's text cannot be read then (holder is "").
file_lock :: proc(path, text: string) -> (lock: File_Lock, holder: string, ok: bool) {
	wpath := windows.utf8_to_wstring(path, context.temp_allocator)
	h := windows.CreateFileW(
		wpath,
		windows.GENERIC_READ | windows.GENERIC_WRITE,
		0,
		nil,
		windows.OPEN_ALWAYS,
		windows.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if h == windows.INVALID_HANDLE_VALUE {return}
	if len(text) > 0 {
		written: windows.DWORD
		windows.WriteFile(h, raw_data(text), windows.DWORD(len(text)), &written, nil)
	}
	windows.SetEndOfFile(h)
	return {h, true}, "", true
}

// file_unlock releases the lock (the file stays).
file_unlock :: proc(l: ^File_Lock) {
	if l.ok {windows.CloseHandle(l.handle)}
	l^ = {}
}
