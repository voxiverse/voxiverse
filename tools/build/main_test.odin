package build

import "core:os"
import "core:testing"
import "core:time"

// A tool is stale when a file under any folder it is built from is newer than it, not
// only one in its own folder: `bench budgets -check` judged a build that lacked the
// engine's changes when only server/core had changed.
@(test)
test_tool_stale_looks_past_its_folder :: proc(t: ^testing.T) {
	root :: "build/tmp/tool_stale"
	os.remove_all(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(root + "/tool") == nil)
	testing.expect(t, os.make_directory_all(root + "/engine/deep") == nil)
	write :: proc(path: string, at: time.Time) {
		_ = os.write_entire_file(path, transmute([]u8)string("x"))
		_ = os.change_times(path, at, at)
	}
	then := time.from_nanoseconds(1_700_000_000 * i64(time.Second))
	write(root + "/tool/main.odin", then)
	write(root + "/engine/deep/code.odin", then)
	exe := root + "/exe"
	dirs := []string{root + "/tool", root + "/engine"}
	testing.expect(t, tool_stale(exe, dirs), "no executable is stale")
	write(exe, time.time_add(then, time.Hour))
	testing.expect(t, !tool_stale(exe, dirs))
	write(root + "/engine/deep/code.odin", time.time_add(then, 2 * time.Hour))
	testing.expect(t, tool_stale(exe, dirs), "a change in the engine left the tool fresh")
}
