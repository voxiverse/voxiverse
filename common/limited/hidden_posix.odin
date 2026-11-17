#+build !windows
package limited

import "core:os"

// start_hidden starts desc: there is no console window to hide outside Windows.
start_hidden :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	return os.process_start(desc)
}
