package base

import "core:os"
import "core:sys/windows"
import "core:time"

file_sync :: proc(f: ^os.File) -> os.Error {return os.sync(f)}

// A rename that writes through (the entry is on disk when it returns, so no
// directory sync), retried while an indexer or a virus scanner holds the file.
file_rename :: proc(from, to: string) -> os.Error {
	wfrom := windows.utf8_to_wstring(from, context.temp_allocator)
	wto := windows.utf8_to_wstring(to, context.temp_allocator)
	for attempt in 0 ..< 5 {
		if windows.MoveFileExW(
			wfrom,
			wto,
			windows.MOVEFILE_REPLACE_EXISTING | windows.MOVEFILE_WRITE_THROUGH,
		) {
			return nil
		}
		code := windows.GetLastError()
		if code != windows.ERROR_SHARING_VIOLATION && code != windows.ERROR_ACCESS_DENIED {break}
		if attempt < 4 {time.sleep(20 * time.Millisecond)}
	}
	return os.rename(from, to) // (reports the error the usual way)
}

dir_sync :: proc(path: string) -> bool {return true}
