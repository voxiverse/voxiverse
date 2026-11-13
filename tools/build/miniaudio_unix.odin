#+build !windows
package build

import "core:fmt"
import "core:os"

// The game uses Odin's vendor:miniaudio (client/audio/device.odin). Its static
// library ships with the compiler on Windows only (miniaudio_windows.odin);
// here it is compiled once, into the Odin install, from the C source that
// comes with it (with cc, which linking needs anyway).
ensure_miniaudio :: proc() -> bool {
	// (On macOS the compiler's script writes, and the bindings link, lib/darwin/.)
	lib := path_join({ODIN_ROOT, "vendor", "miniaudio", "lib", "miniaudio.a"})
	when ODIN_OS == .Darwin {
		lib = path_join({ODIN_ROOT, "vendor", "miniaudio", "lib", "darwin", "miniaudio.a"})
	}
	if os.exists(lib) {return true}
	fmt.println("miniaudio: compiling Odin's vendor library (one time)")
	script := path_join({ODIN_ROOT, "vendor", "miniaudio", "src", "build_miniaudio.sh"})
	if !run({system_tool("sh"), script}) || !os.exists(lib) {
		fmt.eprintfln(
			"miniaudio: could not build %s - is a C compiler (cc) installed, and is %s writable?",
			lib,
			ODIN_ROOT,
		)
		return false
	}
	return true
}
