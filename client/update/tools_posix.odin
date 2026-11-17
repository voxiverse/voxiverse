#+build !windows
package update

import "core:os"

// tools_find: the system's curl and tar (and ditto on macOS) where the OS keeps them;
// ok false without curl or tar. (The paths are constants; allocator is Windows'.)
tools_find :: proc(allocator := context.allocator) -> (tools: Tools, ok: bool) {
	first :: proc(paths: ..string) -> string {
		for p in paths {if os.is_file(p) {return p}}
		return ""
	}
	tools.curl = first("/usr/bin/curl", "/bin/curl")
	tools.tar = first("/usr/bin/tar", "/bin/tar")
	when ODIN_OS == .Darwin {
		tools.ditto = first("/usr/bin/ditto")
		if tools.ditto == "" {return tools, false}
	}
	return tools, tools.curl != "" && tools.tar != ""
}
