package client

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../base"
import "font"
import "platform"
import "ui"

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
	actions_sync(app)
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
	app.input.pressed, app.input.pad_pressed = {}, {}
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
	// Jump's row is below the settings: scrolled to.
	app.options.scroll = 10 * (app.ui.theme.row_height + app.ui.theme.spacing)
	ui_frame(app)
	click(t, app, "Space") // jump's key
	testing.expect(t, app.options.listening != .None)
	app.input.pressed = {.G}
	ui_frame(app)
	testing.expect_value(t, app.settings.keys.jump, platform.Key.G)
	testing.expect_value(t, app.options.listening, Action.None)

	// A mouse button binds too, and clicks nothing beneath.
	click(t, app, "G")
	app.input.pressed = {.Mouse_4}
	ui_frame(app)
	testing.expect_value(t, app.settings.keys.jump, platform.Key.Mouse_4)
	testing.expect_value(t, app.options.listening, Action.None)

	// Escape: as it was.
	click(t, app, "Mouse Button 4")
	escape(app)
	ui_frame(app)
	testing.expect(t, app.options.listening == .None && app.settings.keys.jump == .Mouse_4)
	testing.expect_value(t, app.screen, Screen.Options)

	// Reset Keys, at the bottom: scrolled to.
	ui_frame(app, {mouse = {640, 360}, wheel = {0, -100}})
	click(t, app, "Reset Keys")
	testing.expect(t, app.settings.keys == DEFAULT_BINDINGS)
	testing.expect_value(t, app.screen, Screen.Options)

	click(t, app, "Done")
	testing.expect_value(t, app.screen, Screen.Title)
	free_all(context.temp_allocator)
}

// The gamepad's column: a click on jump's pad cell listens, the next pad
// button binds (and marks the clash with drop's X), Start leaves it as it
// was, Reset Pad Buttons restores the defaults.
@(test)
test_options_pad_bindings :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	app.screen = .Options
	app.options.tab = .Controls
	app.options.scroll = 10 * (app.ui.theme.row_height + app.ui.theme.spacing)
	ui_frame(app)
	// Jump's pad cell is the next to the right of its key's ("Space").
	pad_cell :: proc(t: ^testing.T, app: ^App) {
		r, found := ui.find_widget(&app.ui, "Space")
		testing.expect(t, found)
		p := ui.Vec2{r.x + r.w * 1.5, r.y + r.h / 2}
		ui_frame(app, {mouse = p})
		ui_frame(app, {mouse = p, mouse_pressed = {.Left}, mouse_down = {.Left}})
		ui_frame(app, {mouse = p, mouse_released = {.Left}})
		ui_frame(app, {mouse = p})
	}
	pad_cell(t, app)
	testing.expect_value(t, app.options.listening, Action.Jump)
	testing.expect(t, app.options.listening_pad)
	// Start leaves it as it is.
	app.input.pad_pressed = {.Start}
	ui_frame(app)
	testing.expect_value(t, app.options.listening, Action.Jump)
	in_: ui.Input
	app.input.pad_pressed = {.Start}
	actions_sync(app)
	handle_global_keys(app, &in_)
	testing.expect_value(t, app.options.listening, Action.None)
	testing.expect_value(t, app.settings.pad.jump, platform.Pad_Button.A)

	pad_cell(t, app)
	app.input.pad_pressed = {.X}
	ui_frame(app)
	testing.expect_value(t, app.settings.pad.jump, platform.Pad_Button.X)
	testing.expect_value(t, app.options.listening, Action.None)
	_, clash := binding_conflicts(&app.settings.keys, &app.settings.pad)
	testing.expect(t, .Jump in clash && .Drop in clash)

	ui_frame(app, {mouse = {640, 360}, wheel = {0, -100}})
	click(t, app, "Reset Pad Buttons")
	testing.expect(t, app.settings.pad == DEFAULT_PAD_BINDINGS)
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

// Q and E step the Options tabs, around; every option and every binding
// shows its help after the mouse rests on it; a Q typed in a text field is
// typing, not a step.
@(test)
test_options_tabs_by_keys :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	app.screen = .Options
	ui_frame(app)
	keys := app.settings.keys
	step :: proc(app: ^App, key: platform.Key) {
		app.input.pressed = {key}
		ui_frame(app)
		ui_frame(app) // (what the step changed, drawn)
	}
	want := [?]Options_Tab{.Audio, .Controls, .Accessibility, .Profile, .Video}
	for tab in want {
		step(app, keys.tab_next)
		testing.expect_value(t, app.options.tab, tab)
	}
	step(app, keys.tab_prev)
	testing.expect_value(t, app.options.tab, Options_Tab.Profile)
	testing.expect_value(t, tab_name(.Audio), "Audio")

	// Hovering a row, a half second on, shows its help (the first row's place
	// is where the rest follow: one row and its gap apart).
	table := settings_table()
	rest :: proc(t: ^testing.T, app: ^App, at: ui.Vec2, help: string, what: string) {
		time := app.ui.input.time
		ui_frame(app, {mouse = at, time = time + 1})
		ui_frame(app, {mouse = at, time = time + 1.5})
		found := false
		for text in app.ui.texts {found ||= text == help}
		testing.expectf(t, found, "%s shows no help", what)
		ui_frame(app, {mouse = {-100, -100}, time = time + 2}) // (moved away)
	}
	for tab in Options_Tab {
		app.options.tab, app.options.scroll = tab, 0
		ui_frame(app)
		row_h := f32(36 + 10) // row height and gap
		first: ui.Rect
		for field, i in OPTIONS_TABS[tab] {
			v, _ := base.var_find(table, field)
			if i == 0 {
				// The first row's rectangle, from its widget (the rows below it follow).
				label := var_label(table, v)
				if c, ok := base.var_choice(table, &app.settings, v); ok {
					label = fmt.tprintf("%s: %s", label, v.choices[c].label)
				}
				if kind, _ := base.var_kind(table, v); kind == .Text {label = v.field}
				r, found := ui.find_widget(&app.ui, label)
				testing.expectf(t, found, "no row for %s", field)
				first = r
			}
			at := ui.Vec2{first.x + 10, first.y + f32(i) * row_h + first.h / 2}
			rest(t, app, at, v.help, field)
		}
		if tab != .Controls {continue}
		// The bindings, each scrolled into view: the key's cell, the pad's cell.
		index := len(OPTIONS_TABS[tab]) + 2
		for g in 0 ..< len(BINDING_GROUPS) {
			index += 1 // the group's heading
			for a in binding_rows(app, g) {
				app.options.scroll = max(0, f32(index) * row_h - 200)
				ui_frame(app)
				y := first.y + f32(index) * row_h - app.options.scroll + first.h / 2
				field := action_field(a)
				if action_key(&app.settings.keys, a) != nil {
					v := &BINDING_VARS[0]
					for &x in BINDING_VARS {if x.field == field {v = &x}}
					rest(t, app, {first.x + first.w * 0.55, y}, v.help, field)
				}
				if action_pad(&app.settings.pad, a) != nil {
					v := &PAD_BINDING_VARS[0]
					for &x in PAD_BINDING_VARS {if x.field == field {v = &x}}
					rest(t, app, {first.x + first.w * 0.85, y}, v.help, field)
				}
				index += 1
			}
		}
	}

	// Typing Q into the name field changes the name, not the tab.
	app.options.tab, app.options.scroll = .Profile, 0
	ui_frame(app)
	click(t, app, "name")
	testing.expect(t, app.ui.edit.active)
	app.input.pressed = {keys.tab_prev}
	typed := []rune{'q'}
	ui_frame(app, {text = typed, mouse = {-100, -100}})
	testing.expect_value(t, app.options.tab, Options_Tab.Profile)
	testing.expect(t, strings.contains(base.var_text(&app.settings.name), "q"))
	free_all(context.temp_allocator)
}

// The screen is kept awake from the first frame, the title included.
@(test)
test_keep_awake_on_title :: proc(t: ^testing.T) {
	app := ui_app(t)
	defer ui_app_free(app)
	app.screen = .Title
	testing.expect(t, !app.window.keep_awake)
	keep_awake_update(app)
	testing.expect(t, app.window.keep_awake)
	platform.set_keep_awake(&app.window, false) // (let the screensaver be again)
}
