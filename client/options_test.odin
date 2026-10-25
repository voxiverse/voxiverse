package client

import "core:os"
import "core:path/filepath"
import "core:testing"

import "../font"
import "../platform"
import "../ui"

// A UI test's app: the font and the UI, nothing else.
@(private = "file")
ui_app :: proc(t: ^testing.T) -> ^App {
	app := new(App)
	ok: bool
	app.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, ui.init(&app.ui, &app.font))
	app.settings = SETTINGS_DEFAULTS
	app.scripted = true // (nothing saved)
	return app
}

@(private = "file")
ui_app_free :: proc(app: ^App) {
	ui.destroy(&app.ui)
	free(app)
}

// ui_frame draws one frame of the app's screen with input.
@(private = "file")
ui_frame :: proc(app: ^App, input: ui.Input = {}) {
	ui.begin_frame(&app.ui, input, {1280, 720}, 1)
	#partial switch app.screen {
	case .Options:
		options_screen(app, &app.ui)
	case .Worlds:
		worlds_screen(app, &app.ui)
	}
	ui.end_frame(&app.ui)
	app.input.pressed = {}
}

// click: the widget saying label, as a player clicks it (over it, down, up).
@(private = "file")
click :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	r, found := ui.find_widget(&app.ui, label)
	if !testing.expectf(
		t,
		found && r.w > 0,
		"no %q on the screen",
		label,
		loc = loc,
	) {return false}
	p := ui.Vec2{r.x + r.w / 2, r.y + r.h / 2}
	ui_frame(app, {mouse = p})
	ui_frame(app, {mouse = p, mouse_pressed = {.Left}, mouse_down = {.Left}})
	ui_frame(app, {mouse = p, mouse_released = {.Left}})
	ui_frame(app, {mouse = p}) // what the click changed, drawn
	return true
}

// Options: the tabs, a choice cycling, and a key bound by pressing it (or
// a mouse button), Escape leaving it, Reset Keys.
@(test)
test_options_screen :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	app.screen = .Options
	ui_frame(app)

	click(t, app, "Clouds: On")
	testing.expect(t, !app.settings.clouds)
	click(t, app, "Max frame rate: Unlimited")
	testing.expect_value(t, app.settings.max_fps, 30) // round to the first

	click(t, app, "Controls")
	testing.expect_value(t, app.options.tab, Options_Tab.Controls)
	click(t, app, "Space") // jump's key
	testing.expect(t, app.options.listening != 0)
	app.input.pressed = {.G}
	ui_frame(app)
	testing.expect_value(t, app.settings.keys.jump, platform.Key.G)
	testing.expect_value(t, app.options.listening, 0)

	// A mouse button binds too, and clicks nothing beneath.
	click(t, app, "G")
	app.input.pressed = {.Mouse_4}
	ui_frame(app)
	testing.expect_value(t, app.settings.keys.jump, platform.Key.Mouse_4)
	testing.expect_value(t, app.options.listening, 0)

	// Escape: as it was.
	click(t, app, "Mouse Button 4")
	escape(app)
	ui_frame(app)
	testing.expect(t, app.options.listening == 0 && app.settings.keys.jump == .Mouse_4)
	testing.expect_value(t, app.screen, Screen.Options)

	// Reset Keys, at the bottom: scrolled to.
	ui_frame(app, {mouse = {640, 360}, wheel = {0, -100}})
	click(t, app, "Reset Keys")
	testing.expect(t, app.settings.keys == DEFAULT_BINDINGS)

	click(t, app, "Done")
	testing.expect_value(t, app.screen, Screen.Title)
	free_all(context.temp_allocator)
}

// Each key's scan code finds the key again (the table has no slips).
@(test)
test_keys_by_place :: proc(t: ^testing.T) {
	for code, k in platform.SCANCODES {
		if code == 0 {continue}
		got := platform.key_from_scancode(u32(code & 0xff), code & 0xE000 != 0)
		testing.expectf(t, got == k, "scan code %x: %v, not %v", code, got, k)
	}
	testing.expect_value(t, key_label(nil, .Left_Shift), "Left Shift")
	testing.expect_value(t, key_label(nil, .Mouse_Right), "Right Button")
}

// Singleplayer: the saves newest first; select, rename, delete (asked
// first).
@(test)
test_saves_screen :: proc(t: ^testing.T) {
	dir := "build/test/saves"
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.set_env("VX_SAVES", dir)
	defer os.unset_env("VX_SAVES")
	for name in ([]string{"Old", "Castle"}) {
		save := filepath.join({dir, name}, context.temp_allocator) or_else ""
		os.make_directory_all(save)
		cfg := filepath.join({save, "universe.cfg"}, context.temp_allocator) or_else ""
		testing.expect(t, os.write_entire_file(cfg, []u8{}) == nil)
	}
	app := ui_app(t)
	defer ui_app_free(app)
	defer worlds_destroy(&app.worlds)
	worlds_refresh(&app.worlds)
	testing.expect_value(t, len(app.worlds.entries), 2)
	app.screen = .Worlds
	ui_frame(app)

	click(t, app, "Castle")
	testing.expect(t, app.worlds.selected >= 0)
	testing.expect_value(t, app.worlds.entries[app.worlds.selected].name, "Castle")

	// Edit: the name, renamed on Save.
	click(t, app, "Edit")
	testing.expect_value(t, app.worlds.mode, Saves_Mode.Edit)
	clear(&app.worlds.name)
	append(&app.worlds.name, "Fort")
	ui_frame(app)
	click(t, app, "Save")
	testing.expect_value(t, app.worlds.mode, Saves_Mode.List)
	testing.expect(t, os.exists("build/test/saves/Fort") && !os.exists("build/test/saves/Castle"))

	// Delete: asked first; Cancel keeps it, Delete does not.
	// (Clicks on one save this close together would be a double-click: Play.)
	app.worlds.last_row = -1
	ui_frame(app)
	click(t, app, "Fort")
	click(t, app, "Delete")
	testing.expect_value(t, app.worlds.mode, Saves_Mode.Delete)
	click(t, app, "Cancel")
	testing.expect(t, os.exists("build/test/saves/Fort"))
	app.worlds.last_row = -1
	click(t, app, "Fort")
	click(t, app, "Delete")
	ui_frame(app)
	click(t, app, "Delete") // the dialog's
	testing.expect(t, !os.exists("build/test/saves/Fort"))
	testing.expect_value(t, len(app.worlds.entries), 1)
	free_all(context.temp_allocator)
}
