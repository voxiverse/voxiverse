package client

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

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
	case .Title:
		title_screen(app, &app.ui)
	case .Options:
		options_screen(app, &app.ui)
	case .Worlds:
		worlds_screen(app, &app.ui)
	case .Multiplayer:
		multiplayer_screen(app, &app.ui)
	case .Failed:
		failed_screen(app, &app.ui)
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

// Multiplayer: the first visit asks for a name (kept in the settings);
// Direct Connection opens and cancels back to the list.
@(test)
test_multiplayer_screen :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	defer multiplayer_destroy(&app.multiplayer)
	multiplayer_open(app)
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.Name)
	ui_frame(app)
	append(&app.multiplayer.name, "no spaces")
	ui_frame(app)
	_, enabled := ui.find_widget(&app.ui, "Done") // not a valid name: Done is off
	testing.expect(t, !enabled)
	clear(&app.multiplayer.name)
	append(&app.multiplayer.name, "alice")
	ui_frame(app)
	click(t, app, "Done")
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.List)
	testing.expect_value(t, player_name(&app.settings), "alice")

	click(t, app, "Direct Connection")
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.Direct)
	click(t, app, "Cancel")
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.List)
	click(t, app, "Back")
	testing.expect_value(t, app.screen, Screen.Title)
	free_all(context.temp_allocator)
}

// No developer word on a player's screen: every menu screen and Options
// tab drawn, what it says read back.
@(test)
test_screens_speak_plainly :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	defer worlds_destroy(&app.worlds)
	defer multiplayer_destroy(&app.multiplayer)

	WORDS :: []string{"universe", "scratch", "chunk", "session", "mesh", "interest", "var", "null"}
	check :: proc(t: ^testing.T, app: ^App, what: string) {
		ui_frame(app)
		testing.expectf(t, len(app.ui.texts) > 2, "%s says nothing", what)
		for text in app.ui.texts {
			lower := strings.to_lower(text, context.temp_allocator)
			for w in WORDS {
				testing.expectf(t, !strings.contains(lower, w), "%s says %q", what, text)
			}
		}
	}
	app.screen = .Title
	check(t, app, "the title")
	// (A save of its own: VX_SAVES is the saves test's, running alongside.)
	append(
		&app.worlds.entries,
		Save_Entry{strings.clone("Home"), strings.clone("Home"), time.now()},
	)
	app.screen = .Worlds
	check(t, app, "Singleplayer")
	app.worlds.selected = 0
	for mode in Saves_Mode {
		app.worlds.mode, app.worlds.more = mode, true
		check(t, app, fmt.tprint("Singleplayer", mode))
	}
	multiplayer_open(app)
	for mode in Multiplayer_Mode {
		app.multiplayer.mode = mode
		check(t, app, fmt.tprint("Multiplayer", mode))
	}
	multiplayer_close(&app.multiplayer)
	app.screen = .Options
	for tab in Options_Tab {
		app.options.tab = tab
		check(t, app, fmt.tprint("Options", tab))
	}
	app.failed = {"Could Not Join", strings.clone("No answer from the server."), .Title}
	app.screen = .Failed
	check(t, app, "the failure screen")
	click(t, app, "Back to Title Screen")
	testing.expect_value(t, app.screen, Screen.Title)
	free_all(context.temp_allocator)
}
