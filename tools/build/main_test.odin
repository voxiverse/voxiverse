package build

import "core:os"
import "core:slice"
import "core:strings"
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

// check type-checks every build the driver makes: a switch of the code's (`#config` with a
// boolean default) that no build configuration of check's sets against its default leaves
// the code under `when` it guards unchecked, as `when base.DEV` once was for 12 commits.
@(test)
test_check_sets_every_build_switch :: proc(t: ^testing.T) {
	for dir in SOURCE_DIRS {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		for entry in entries {
			if !strings.has_suffix(entry.name, ".odin") ||
			   strings.has_suffix(entry.name, "_test.odin") {continue}
			data, _ := os.read_entire_file_from_path(entry.fullpath, context.temp_allocator)
			rest := string(data)
			for {
				at := strings.index(rest, "#config(")
				if at < 0 {break}
				rest = rest[at + len("#config("):]
				close := strings.index_byte(rest, ')')
				if close < 0 {break}
				parts := strings.split(rest[:close], ",", context.temp_allocator)
				if len(parts) != 2 {continue}
				name, default := strings.trim_space(parts[0]), strings.trim_space(parts[1])
				other: string
				switch default {
				case "false", "ODIN_DEBUG":
					other = "true"
				case "true":
					other = "false"
				case:
					continue
				}
				define := strings.concatenate(
					{"-define:", name, "=", other},
					context.temp_allocator,
				)
				set := false
				for config in BUILD_CONFIGS {
					if slice.contains(config.defines, define) {set = true}
				}
				testing.expectf(t, set, "%s (%s): no check sets %s", name, entry.name, define)
			}
		}
	}
}
