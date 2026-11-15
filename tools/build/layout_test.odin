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

// A game's folders are one row for every game: `<game>` stands for a game's name.
@(test)
test_layout_game_shape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	rows := parse_layout(
		"| `games` | the games | `README.md` |\n| `games/<game>` | a game | `*.odin` |\n",
	)
	testing.expect_value(t, rows[1].folder, "games/<game>")
	ok := []string{"games/README.md", "games/tag/tag.odin", "games/king_of_hill/rules.odin"}
	testing.expect_value(t, len(lint_layout(rows, ok)), 0)
	// A name that is not singular snake_case, a file the shape does not allow, a folder
	// below the shape: each is reported.
	testing.expect_value(t, len(lint_layout(rows, {"games/README.md", "games/Tag/tag.odin"})), 2)
	testing.expect_value(t, len(lint_layout(rows, {"games/README.md", "games/tag/notes.txt"})), 1)
	testing.expect_value(
		t,
		len(lint_layout(rows, {"games/README.md", "games/tag/tag.odin", "games/tag/x/a.odin"})),
		1,
	)
	// A shape no game has yet is a stale row, as a folder with no file is.
	testing.expect_value(t, len(lint_layout(rows, {"games/README.md"})), 1)
	testing.expect(t, row_matches("games/<game>/client", "games/tag/client"))
	testing.expect(t, !row_matches("games/<game>/client", "games/tag"))
	testing.expect(t, !row_matches("games/<game>", "games/_tag"))
	testing.expect(t, !row_matches("games/<game>", "games/tag/client"))
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

@(test)
test_cap_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, parse_cap("x\n\nCap: `70` files per package.\n"), 70)
	testing.expect_value(t, parse_cap("no cap here"), 0)
	tracked := []string {
		"a/x.odin",
		"a/y.odin",
		"a/y_test.odin",
		"a/z_test.odin",
		"b/x.odin",
		"b/notes.md",
	}
	testing.expect_value(t, len(lint_cap(2, tracked)), 0)
	testing.expect_value(t, len(lint_cap(1, tracked)), 1)
	testing.expect_value(t, len(lint_cap(0, tracked)), 1)
}
