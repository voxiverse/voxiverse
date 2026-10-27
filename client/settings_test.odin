package client

import "core:os"
import "core:testing"

import "../base"
import "../common/game"
import "ui"

// Every variable table names real fields of supported types, with defaults
// inside their ranges.
@(test)
test_variable_tables :: proc(t: ^testing.T) {
	app: App
	for v in app_variables(&app) {
		testing.expectf(
			t,
			base.var_table_check(v.table),
			"table %q has a bad range or default",
			v.table.prefix,
		)
	}
}

@(test)
test_settings_round_trip :: proc(t: ^testing.T) {
	path := "build/test/settings_test.cfg"
	os.make_directory_all("build/test")
	os.set_env("VX_SETTINGS", path)
	defer os.unset_env("VX_SETTINGS")
	defer os.remove(path)

	a: App
	settings_load(&a) // no file yet: defaults
	testing.expect(t, a.settings == SETTINGS_DEFAULTS)
	a.settings.fov, a.settings.render_distance, a.settings.invert_mouse = 95, 20, true
	a.settings.keys.jump, a.settings.keys.attack = .G, .Mouse_5
	settings_save(&a)

	b: App
	settings_load(&b)
	testing.expect(t, a.settings == b.settings)

	// Scripted changes are never marked for saving.
	b.scripted = true
	settings_changed(&b)
	testing.expect(t, !b.settings_dirty)
}

@(test)
test_fps_counter :: proc(t: ^testing.T) {
	f: Fps
	gpu := new(base.Frame_Stats)
	defer free(gpu)
	for _ in 0 ..< 49 {fps_update(&f, 10, gpu)}
	testing.expect_value(t, f.fps, 0) // under half a second: nothing yet
	for _ in 0 ..< 3 {base.frame_stats_add(gpu, 4)}
	fps_update(&f, 10, gpu) // 50 frames in 500 ms
	testing.expectf(t, abs(f.fps - 100) < 1e-3, "fps %v", f.fps)
	testing.expectf(t, abs(f.frame_ms - 10) < 1e-3, "frame %v", f.frame_ms)
	testing.expect_value(t, f.gpu_ms, 4)
	// The next window stands alone: 250 frames of 2 ms.
	base.frame_stats_add(gpu, 1)
	for _ in 0 ..< 250 {fps_update(&f, 2, gpu)}
	testing.expectf(t, abs(f.fps - 500) < 1e-2, "fps %v", f.fps)
	testing.expect_value(t, f.gpu_ms, 1)
}

// Tab: one fit completes (and adds a space), several extend to what they
// share, and when that adds nothing they are listed.
@(test)
test_console_completion :: proc(t: ^testing.T) {
	commands := []string{"set", "save", "screen", "screenshot", "summon", "tp"}
	done, choices := complete_word("tp", commands)
	testing.expect(t, done == "tp " && choices == nil)
	done, choices = complete_word("su", commands)
	testing.expect_value(t, done, "summon ")
	done, choices = complete_word("scr", commands)
	testing.expect(t, done == "screen" && choices == nil, "extends to the shared part")
	done, choices = complete_word("screen", commands)
	testing.expect(t, done == "screen" && len(choices) == 2, "lists when it cannot extend")
	done, choices = complete_word("s", commands)
	testing.expect(t, done == "s" && len(choices) == 5)
	done, choices = complete_word("x", commands)
	testing.expect(t, done == "x" && choices == nil)
}

// History: typed lines (not twice in a row), walked with the draft kept.
@(test)
test_console_history :: proc(t: ^testing.T) {
	c: Line_Editor
	line_editor_init(&c)
	defer line_editor_destroy(&c)
	line_remember(&c, "time noon")
	line_remember(&c, "time noon")
	line_remember(&c, "  summon ")
	line_remember(&c, "")
	testing.expect_value(t, len(c.history), 2)
	append(&c.text, "half typed")
	e: ui.Text_Edit
	walk_history(&c, -1, &e)
	testing.expect_value(t, string(c.text[:]), "summon")
	walk_history(&c, -1, &e)
	walk_history(&c, -1, &e) // the oldest stays
	testing.expect_value(t, string(c.text[:]), "time noon")
	testing.expect_value(t, e.cursor, len("time noon"))
	walk_history(&c, 1, &e)
	walk_history(&c, 1, &e) // past the newest: the draft again
	testing.expect_value(t, string(c.text[:]), "half typed")
	testing.expect_value(t, c.browsing, -1)
}

// Commands run only when they can: the right number of arguments, in a
// world, with cheats; else a warning says why.
@(test)
test_console_command_needs :: proc(t: ^testing.T) {
	app := new(App)
	app.settings = SETTINGS_DEFAULTS
	defer free(app)
	console_init(&app.console)
	defer console_destroy(&app.console)
	@(static) ran: int
	ran = 0
	console_register(&app.console, {"poke", "poke <what>: test", proc(app: ^App, args: []string) {
				ran += 1
			}}, args = {1, 1}, needs = {.World}, node = "world.poke")
	last :: proc(c: ^Console) -> string {return(
			c.lines[(c.first + c.count - 1) % CONSOLE_MAX_LINES].text \
		)}

	console_execute(app, "poke")
	testing.expect_value(t, last(&app.console), "poke: usage: poke <what>")
	console_execute(app, "poke it")
	testing.expect_value(t, last(&app.console), "poke: not in a world")
	s := new(Session)
	defer free(s)
	app.session = s
	s.state = .Playing
	console_execute(app, "poke it")
	testing.expect_value(t, last(&app.console), "poke: not allowed on this server")
	append(&s.grants, game.Grant{pattern = "world.*", allow = true})
	defer delete(s.grants)
	console_execute(app, "poke it")
	testing.expect_value(t, ran, 1)
	app.session = nil
}
