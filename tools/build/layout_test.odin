package build

import "core:testing"

@(test)
test_layout_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	rows := parse_layout(
		"text\n| Folder | What | Patterns |\n|---|---|---|\n| `.` | root | `README.md`, `build.sh` |\n| `client/hud` | the HUD | `*.odin` |\n",
	)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[1].folder, "client/hud")
	testing.expect_value(t, len(rows[0].patterns), 2)
	testing.expect_value(
		t,
		len(lint_layout(rows, {"README.md", "build.sh", "client/hud/hotbar.odin"})),
		0,
	)
	// A name that matches no pattern, a folder that is not listed, a row with no file.
	testing.expect_value(
		t,
		len(lint_layout(rows, {"README.md", "notes.txt", "client/hud/a.odin"})),
		1,
	)
	testing.expect_value(
		t,
		len(lint_layout(rows, {"README.md", "build.sh", "client/hud/a.odin", "client/x/b.odin"})),
		1,
	)
	testing.expect_value(t, len(lint_layout(rows, {"README.md", "build.sh"})), 1)
}

@(test)
test_scratch_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, len(lint_scratch({"", "client/notes.txt", "a.log"})), 2)
	testing.expect_value(t, len(lint_scratch({})), 0)
}

@(test)
test_package_lists_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	packages := []string{"client/hud", "tools/build", "tests"}
	tests := []string{"client/hud", "tools/build"}
	dirs := []string{"client/hud", "tools", "tests"}
	run :: proc(tracked, with_tests, packages, test_packages, dirs: []string) -> int {
		return len(lint_package_lists(tracked, with_tests, packages, test_packages, dirs))
	}
	tracked := []string {
		"client/hud/a.odin",
		"tools/build/main.odin",
		"tests/x/y.odin",
		"docs/a.md",
	}
	// A folder with Odin missing from PACKAGES.
	testing.expect_value(t, run(tracked, {}, packages, tests, dirs), 1)
	complete := []string{"client/hud", "tools/build", "tests", "tests/x"}
	testing.expect_value(t, run(tracked, {}, complete, tests, dirs), 0)
	// An @(test) outside tests/ in a folder missing from TEST_PACKAGES; inside tests/ it passes.
	testing.expect_value(t, run(tracked, {"tests/x/y.odin"}, complete, tests, dirs), 0)
	testing.expect_value(t, run(tracked, {"client/hud/a.odin"}, complete, tests, dirs), 0)
	testing.expect_value(
		t,
		run(tracked, {"client/hud/a.odin"}, complete, {"tools/build"}, dirs),
		1,
	)
	// A TEST_PACKAGES entry that is not a package.
	testing.expect_value(t, run(tracked, {}, complete, {"client/hud", "client/x"}, dirs), 1)
	// A folder under none of SOURCE_DIRS.
	testing.expect_value(t, run(tracked, {}, complete, tests, {"client/hud", "tools"}), 1)
	// A sibling that only shares a prefix is not under a source dir.
	testing.expect_value(t, run({"tools2/a.odin"}, {}, {"tools2"}, {}, {"tools"}), 1)
}
