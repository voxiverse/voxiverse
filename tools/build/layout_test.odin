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
