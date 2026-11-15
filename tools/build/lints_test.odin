package build

import "core:strings"
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
	testing.expect_value(
		t,
		len(lint_colour_literals("f", "ui.fill_rect(c, r, {0, 0, 0, 255})\n")),
		1,
	)
	testing.expect_value(
		t,
		len(lint_colour_literals("f", "ui.fill_rect(c, r, {255, 255, 255, u8(a)})\n")),
		1,
	)
	testing.expect_value(t, len(lint_colour_literals("f", "r := ui.Rect{0, 0, w, h}\n")), 0)
	testing.expect_value(t, len(lint_colour_literals("f", "// {0, 0, 0, 255}\n")), 0)
}

@(test)
test_mode_name_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, len(lint_mode_names("f", "if m == \"creative\" {}\n")), 1)
	testing.expect_value(t, len(lint_mode_names("f", "if m != \"base:survival\" {}\n")), 1)
	testing.expect_value(t, len(lint_mode_names("f", "if m == MODE {} // == \"creative\"\n")), 0)
}

@(test)
test_miniaudio_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	imp := "import ma \"vendor:miniaudio\"\n"
	testing.expect_value(t, len(lint_miniaudio("client/audio/clip.odin", imp)), 1)
	testing.expect_value(t, len(lint_miniaudio("client/audio/device.odin", imp)), 0)
	testing.expect_value(t, len(lint_miniaudio("server/x_test.odin", imp)), 1)
	testing.expect_value(
		t,
		len(lint_miniaudio("client/a.odin", "// \"vendor:miniaudio\" in a comment\n")),
		0,
	)
}

// The words are built here so that this file does not hold them as text of its own.
SLEEP :: "time" + ".sleep"
START :: "start(" + "&srv"

@(test)
test_test_timing_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	found := lint_test_timing("server/x_test.odin", "a := 1\n" + SLEEP + "(1)\n")
	testing.expect_value(t, len(found), 1)
	testing.expect_value(
		t,
		found[0],
		"server/x_test.odin:2: " + SLEEP + " in a unit test: step ticks, or move it to tests/",
	)
	testing.expect_value(t, len(lint_test_timing("f", "t := time.tick_" + "now()\n")), 1)
	testing.expect_value(t, len(lint_test_timing("f", "// " + SLEEP + "\n")), 0)
}

@(test)
test_test_server_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, len(lint_test_servers("f", "ok := " + START + ", cfg, {})\n")), 1)
	testing.expect_value(t, len(lint_test_servers("f", "h := harness_start(&h)\n")), 0)
}

@(test)
test_relative_import_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	found := lint_relative_imports(
		"client/x.odin",
		"package client\nimport \"../base\"\nimport \"ui\"\n",
	)
	testing.expect_value(t, len(found), 2)
	testing.expect_value(
		t,
		len(
			lint_relative_imports(
				"f",
				"import \"common:game\"\nimport \"core:fmt\"\nimport b \"common:base\"\nforeign import libc \"system:c\"\n",
			),
		),
		0,
	)
}

@(test)
test_collections_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	all := strings.join(COLLECTIONS, " ")
	testing.expect_value(t, len(lint_collections("build.sh", all)), 0)
	testing.expect_value(
		t,
		len(lint_collections("build.sh", "-collection:client=client")),
		len(COLLECTIONS) - 1,
	)
}

@(test)
test_game_import_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	imports := "package x\nimport \"server:core\"\nimport tag \"games:tag\"\nimport \"games:tag/client\"\n"
	// The main packages may import a game; the engine, the tools and the tests may not.
	testing.expect_value(t, len(lint_game_imports("server/dedicated/main.odin", imports)), 0)
	testing.expect_value(t, len(lint_game_imports("client/main/main.odin", imports)), 0)
	testing.expect_value(t, len(lint_game_imports("server/core/server.odin", imports)), 2)
	testing.expect_value(t, len(lint_game_imports("client/engine/app.odin", imports)), 2)
	testing.expect_value(t, len(lint_game_imports("tools/bench/main.odin", imports)), 2)
	testing.expect_value(t, len(lint_game_imports("tests/x_test.odin", imports)), 2)
	// A game imports itself (its client package its server one), never another game.
	testing.expect_value(t, len(lint_game_imports("games/tag/client/hud.odin", imports)), 0)
	testing.expect_value(t, len(lint_game_imports("games/tag/tag.odin", imports)), 0)
	testing.expect_value(t, len(lint_game_imports("games/flood/flood.odin", imports)), 2)
	// The list of every game the driver writes: the main packages' only.
	list := "import \"generated:games\"\n"
	testing.expect_value(t, len(lint_game_imports("server/dedicated/main.odin", list)), 0)
	testing.expect_value(t, len(lint_game_imports("server/core/server.odin", list)), 1)
	testing.expect_value(t, len(lint_game_imports("games/tag/tag.odin", list)), 1)
	// Not an import: a string that only mentions one.
	testing.expect_value(
		t,
		len(lint_game_imports("server/core/x.odin", "s := \"import \\\"games:tag\\\"\"\n")),
		0,
	)
}

@(test)
test_layer_files :: proc(t: ^testing.T) {
	testing.expect(t, is_layer_file("client/hud/hotbar.odin"))
	testing.expect(t, is_layer_file("client/console/line.odin"))
	testing.expect(t, is_layer_file("/home/x/voxiverse/client/screen/ignite.odin"))
	testing.expect(t, !is_layer_file("/home/x/voxiverse/client/engine/ignite.odin"))
	testing.expect(t, !is_layer_file("client/engine/hud_game.odin"))
	testing.expect(t, !is_layer_file("client/engine/session.odin"))
	testing.expect(t, !is_layer_file("client/hud/hud_test.odin"))
	testing.expect(t, !is_layer_file("client/dev/panels.odin"))
	testing.expect(t, !is_layer_file("hud_x.odin"))
}

@(test)
test_os_quarantine_lint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	imp := "foreign import libc \"system:c\"\n"
	testing.expect_value(t, len(lint_os_quarantine("common/base/x.odin", imp)), 1)
	testing.expect_value(t, len(lint_os_quarantine("client/audio/device.odin", imp)), 1)
	testing.expect_value(t, len(lint_os_quarantine("common/platform/x.odin", imp)), 0)
	testing.expect_value(t, len(lint_os_quarantine("client/platform/x.odin", imp)), 0)
	testing.expect_value(
		t,
		len(lint_os_quarantine("common/base/x.odin", "import \"core:os\"\n// foreign import\n")),
		0,
	)
}
