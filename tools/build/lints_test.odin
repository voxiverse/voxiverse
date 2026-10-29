package build

import "core:testing"

@(test)
test_ui_literal_lint_names_file_and_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	found := lint_ui_literals("client/screen_x.odin", "a := 1\nui.button(ctx, \"Play\", r)\n")
	testing.expect_value(t, len(found), 1)
	testing.expect_value(
		t,
		found[0],
		"client/screen_x.odin:2: a string literal in ui.button: use tr(key)",
	)
	testing.expect_value(
		t,
		len(
			lint_ui_literals(
				"f",
				"ui.button(ctx, tr(.Play), r, id = \"play\")\n// toast(\"x\")\n",
			),
		),
		0,
	)
}

@(test)
test_colour_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, len(lint_colour_literals("f", "c := ui.Color{1, 2, 3, 4}\n")), 1)
	testing.expect_value(t, len(lint_colour_literals("f", "// ui.Color{ in a comment\n")), 0)
}

@(test)
test_mode_name_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, len(lint_mode_names("f", "if m == \"creative\" {}\n")), 1)
	testing.expect_value(t, len(lint_mode_names("f", "if m != \"base:survival\" {}\n")), 1)
	testing.expect_value(t, len(lint_mode_names("f", "if m == MODE {} // == \"creative\"\n")), 0)
}
