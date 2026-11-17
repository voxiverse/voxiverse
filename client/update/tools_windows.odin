#+build windows
package update

import "core:os"
import "core:path/filepath"
import win "core:sys/windows"

// tools_find: Windows' own curl.exe and tar.exe (bsdtar, which reads zips), in the system
// folder (C:\Windows\System32), not whatever another program put earlier in PATH; ok
// false without either. The paths are allocated with allocator.
tools_find :: proc(allocator := context.allocator) -> (tools: Tools, ok: bool) {
	buf: [win.MAX_PATH]u16
	n := win.GetSystemDirectoryW(raw_data(buf[:]), u32(len(buf)))
	if n == 0 || int(n) >= len(buf) {return}
	system, err := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	if err != nil {return}
	tools.curl, _ = filepath.join({system, "curl.exe"}, allocator)
	tools.tar, _ = filepath.join({system, "tar.exe"}, allocator)
	return tools, os.is_file(tools.curl) && os.is_file(tools.tar)
}
