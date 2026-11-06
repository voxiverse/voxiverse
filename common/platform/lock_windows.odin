#+build windows
package platform_common

import "core:sys/windows"

import "common:base"

// lock_file opens path (made if missing) with no sharing and writes text into it. ok is
// false if another process (or another open of it) has it; the holder's text cannot be
// read then (holder is ""). Windows closes the handle with the process.
@(private)
lock_file :: proc(path, text: string) -> (lock: base.File_Lock, holder: string, ok: bool) {
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
	return {uintptr(h), true}, "", true
}

// unlock_file releases the lock (the file stays).
@(private)
unlock_file :: proc(l: ^base.File_Lock) {
	if l.ok {windows.CloseHandle(windows.HANDLE(l.handle))}
	l^ = {}
}
