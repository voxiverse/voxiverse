package client

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../base"
import "../common/game"
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

// ---------------------------------------------------------------------------
// Menus with a pad (M42): every screen and dialog driven by pad events alone:
// no mouse, no keys, no direct calls to escape.
// ---------------------------------------------------------------------------

// pad_frame: one frame as app_frame makes it, without window or GPU: the
// events, the actions, the menus' own actions (back, pause, the pad's
// navigation), the chat and dial keys, then what is on the screen.
pad_frame :: proc(app: ^App, events: ..platform.Event) {
	input_update(&app.input, events)
	actions_sync(app, 1.0 / 60)
	input := ui_input(&app.input, 1)
	menu_actions(app, &input)
	chat_keys(app, &input)
	dial_keys(app)
	ui.begin_frame(&app.ui, input, {1280, 720}, 1)
	s := app.session
	if app.screen == .Game && s != nil && s.state == .Playing && s.loading == nil {
		draw_overlays(app, &app.ui) // (the world itself needs a GPU)
		prompt_bar(app, &app.ui, prompt_items(app))
	} else {
		app_ui(app, &app.ui)
	}
	ui.end_frame(&app.ui)
}

// pad_tap: a button pressed and let go.
pad_tap :: proc(app: ^App, button: platform.Pad_Button) {
	pad_frame(app, platform.Pad_Button_Event{pad = 0, button = button, pressed = true})
	pad_frame(app, platform.Pad_Button_Event{pad = 0, button = button, pressed = false})
}

// pad_go: a D-pad tap in direction dir.
pad_go :: proc(app: ^App, dir: ui.Nav) {
	#partial switch dir {
	case .Up:
		pad_tap(app, .Dpad_Up)
	case .Down:
		pad_tap(app, .Dpad_Down)
	case .Left:
		pad_tap(app, .Dpad_Left)
	case .Right:
		pad_tap(app, .Dpad_Right)
	}
}

// pad_focus: Down, then Up, until the focused widget says label.
pad_focus :: proc(t: ^testing.T, app: ^App, label: string, loc := #caller_location) -> bool {
	passed := make([dynamic]string, context.temp_allocator)
	if ui.focused_label(&app.ui) == label {return true}
	for dir in ([2]ui.Nav{.Down, .Up}) {
		for _ in 0 ..< PAD_FOCUS_TAPS {
			pad_go(app, dir)
			now := ui.focused_label(&app.ui)
			if now == label {return true}
			append(&passed, now)
		}
	}
	testing.expectf(
		t,
		false,
		"the focus never reached %q; it passed %v",
		label,
		passed[:],
		loc = loc,
	)
	return false
}

PAD_FOCUS_TAPS :: 80 // (the Controls tab is a long column)

// pad_type: on an open keyboard, to each key by directions and Confirm; the
// stick press for capitals.
pad_type :: proc(t: ^testing.T, app: ^App, text: string, loc := #caller_location) {
	ctx := &app.ui
	testing.expectf(t, ui.osk_is_open(ctx), "no keyboard open", loc = loc)
	for i in 0 ..< len(text) {
		ch := text[i]
		upper := ch >= 'A' && ch <= 'Z'
		if upper != ctx.osk.shift {pad_tap(app, .Left_Stick)}
		label := text[i:i + 1]
		for _ in 0 ..< 40 {
			if ui.focused_label(ctx) == label {break}
			target, found := ui.find_widget(ctx, label)
			if !testing.expectf(t, found, "no key %q", label, loc = loc) {return}
			from, _ := ui.find_widget(ctx, ui.focused_label(ctx))
			dir: ui.Nav
			switch {
			case target.y > from.y + 1:
				dir = .Down
			case target.y < from.y - 1:
				dir = .Up
			case target.x > from.x:
				dir = .Right
			case:
				dir = .Left
			}
			pad_go(app, dir)
		}
		testing.expectf(t, ui.focused_label(ctx) == label, "could not reach %q", label, loc = loc)
		pad_tap(app, .A)
	}
}

pad_connect :: proc(app: ^App, family: platform.Pad_Family) {
	pad_frame(app, platform.Pad_Connect_Event{pad = 0, connected = true, family = family})
	pad_tap(app, .Right_Stick) // (the first press makes it the device in use)
}

// Rig: an app with a session of its own, as the inventory test makes one.
Rig :: struct {
	app:  ^App,
	s:    ^Session,
	pipe: game.Pipe,
}

rig_make :: proc(t: ^testing.T) -> ^Rig {
	r := new(Rig)
	r.app = ui_app(t)
	app := r.app
	ok: bool
	app.symbol_font, ok = font.load(SYMBOL_FONT_DATA)
	testing.expect(t, ok)
	app.ui.glyphs.fallback = &app.symbol_font
	testing.expect(t, prompt_icons_init(&app.prompt_icons, &app.ui))
	console_init(&app.console)
	line_editor_init(&app.chat)
	game.pipe_init(&r.pipe)
	r.s = new(Session)
	r.s.endpoint = {&r.pipe, .Client}
	game.writer_init(&r.s.writer)
	r.s.welcome.address = game.address_derive(3)
	return r
}

rig_free :: proc(r: ^Rig) {
	s := r.s
	r.app.session = nil
	for c in s.characters {delete(c)}
	delete(s.characters)
	for n in s.notices {delete(n)}
	delete(s.notices)
	for e in s.chat {delete(e.text)}
	delete(s.chat)
	virtual.arena_destroy(&s.arena)
	game.writer_destroy(&s.writer)
	game.pipe_destroy(&r.pipe)
	free(s)
	delete(r.app.new_character)
	line_editor_destroy(&r.app.chat)
	console_destroy(&r.app.console)
	worlds_destroy(&r.app.worlds)
	multiplayer_destroy(&r.app.multiplayer)
	ui_app_free(r.app)
	free(r)
}

@(test)
test_menus_with_a_pad :: proc(t: ^testing.T) {
	dir := "build/test/pad_saves"
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
	r := rig_make(t)
	defer rig_free(r)
	app := r.app
	pad_connect(app, .Xbox)
	testing.expect_value(t, app.actions.device, Device.Pad)

	// The title: Singleplayer is lit at once; A opens the saves.
	testing.expect_value(t, ui.focused_label(&app.ui), "Singleplayer")
	pad_tap(app, .A)
	testing.expect_value(t, app.screen, Screen.Worlds)
	testing.expect_value(t, len(app.worlds.entries), 2)
	// The list: Down selects, and leaves at its last row.
	testing.expect_value(t, ui.focused_label(&app.ui), "saves")
	pad_go(app, .Down)
	pad_go(app, .Down)
	testing.expect_value(t, app.worlds.selected, 1)
	pad_go(app, .Down)
	testing.expect(t, ui.focused_label(&app.ui) != "saves", "Down at the last row leaves the list")

	// Create: the name on the keyboard, B closes it (text kept), Cancel.
	pad_focus(t, app, "Play Selected Save")
	pad_go(app, .Right)
	testing.expect_value(t, ui.focused_label(&app.ui), "Create New Save")
	pad_tap(app, .A)
	testing.expect_value(t, app.worlds.mode, Saves_Mode.Create)
	testing.expect_value(t, ui.focused_label(&app.ui), "name")
	pad_tap(app, .A) // Confirm on a text field: the keyboard
	testing.expect(t, ui.osk_is_open(&app.ui))
	for _ in 0 ..< len("New Save") {pad_tap(app, .X)} 	// X is Backspace
	testing.expect_value(t, len(app.worlds.name), 0)
	pad_type(t, app, "Pad")
	testing.expect_value(t, string(app.worlds.name[:]), "Pad")
	pad_tap(app, .B)
	testing.expect(t, !ui.osk_is_open(&app.ui))
	testing.expect_value(t, app.worlds.mode, Saves_Mode.Create) // (B closed the keyboard first)
	pad_frame(app)
	found := false
	for text in app.ui.texts {if text == "Pad" {found = true}}
	testing.expect(t, found, "the name is seen in the field")
	pad_focus(t, app, "Create Save")
	pad_go(app, .Right)
	testing.expect_value(t, ui.focused_label(&app.ui), "Cancel")
	pad_tap(app, .A)
	testing.expect_value(t, app.worlds.mode, Saves_Mode.List)
	pad_tap(app, .B)
	testing.expect_value(t, app.screen, Screen.Title)

	// Multiplayer: the name asked for, typed, Done; Direct Connection: an
	// address, Cancel; B.
	pad_focus(t, app, "Multiplayer")
	pad_tap(app, .A)
	testing.expect_value(t, app.screen, Screen.Multiplayer)
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.Name)
	testing.expect_value(t, ui.focused_label(&app.ui), "name")
	pad_tap(app, .A)
	pad_type(t, app, "pad_1")
	pad_tap(app, .Start) // Done: the name is given
	testing.expect(t, !ui.osk_is_open(&app.ui))
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.List)
	testing.expect_value(t, player_name(&app.settings), "pad_1")
	pad_focus(t, app, "Direct Connection")
	pad_tap(app, .A)
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.Direct)
	testing.expect_value(t, ui.focused_label(&app.ui), "address")
	clear(&app.multiplayer.address)
	pad_tap(app, .A)
	pad_type(t, app, "127.0.0.1:1")
	testing.expect_value(t, string(app.multiplayer.address[:]), "127.0.0.1:1")
	pad_tap(app, .B)
	pad_focus(t, app, "Join Server")
	pad_go(app, .Right)
	testing.expect_value(t, ui.focused_label(&app.ui), "Cancel")
	pad_tap(app, .A)
	testing.expect_value(t, app.multiplayer.mode, Multiplayer_Mode.List)
	pad_tap(app, .B)
	testing.expect_value(t, app.screen, Screen.Title)

	// Options: RB through every tab and LB back, a slider by Right, a choice
	// by Left, jump's pad button rebound to X and back, Done.
	pad_focus(t, app, "Options")
	pad_tap(app, .A)
	testing.expect_value(t, app.screen, Screen.Options)
	for tab in 1 ..< len(Options_Tab) {
		pad_tap(app, .Right_Bumper)
		testing.expect_value(t, app.options.tab, Options_Tab(tab))
	}
	for tab := len(Options_Tab) - 2; tab >= 0; tab -= 1 {
		pad_tap(app, .Left_Bumper)
		testing.expect_value(t, app.options.tab, Options_Tab(tab))
	}
	pad_tap(app, .Right_Bumper) // Audio
	pad_focus(t, app, "Master volume")
	pad_go(app, .Right)
	testing.expect(t, abs(app.settings.volume - 0.85) < 0.001)
	pad_tap(app, .Left_Bumper) // Video
	pad_focus(t, app, "Clouds: On")
	pad_go(app, .Left)
	testing.expect(t, !app.settings.clouds)
	testing.expect_value(t, ui.focused_label(&app.ui), "Clouds: Off")
	pad_tap(app, .Right_Bumper)
	pad_tap(app, .Right_Bumper) // Controls
	testing.expect_value(t, app.options.tab, Options_Tab.Controls)
	pad_focus(t, app, "Space") // jump's key
	testing.expect(t, app.options.scroll > 0, "the body scrolled to keep the focus in view")
	pad_go(app, .Right) // its pad cell
	testing.expect_value(t, ui.focused_label(&app.ui), "A")
	pad_tap(app, .A)
	testing.expect_value(t, app.options.listening, Action.Jump)
	pad_tap(app, .X)
	testing.expect_value(t, app.settings.pad.jump, platform.Pad_Button.X)
	testing.expect_value(t, ui.focused_label(&app.ui), "X") // the cell is focused again
	pad_tap(app, .A)
	pad_tap(app, .A)
	testing.expect_value(t, app.settings.pad.jump, platform.Pad_Button.A)
	pad_focus(t, app, "Done")
	pad_tap(app, .A)
	testing.expect_value(t, app.screen, Screen.Title)

	// Quit Game: the dialog's Cancel is lit; A keeps playing.
	pad_focus(t, app, "Quit Game")
	pad_tap(app, .A)
	testing.expect(t, overlay_is_open(&app.overlays, .Quit_Dialog))
	testing.expect_value(t, ui.focused_label(&app.ui), "Cancel")
	pad_tap(app, .A)
	testing.expect(t, !overlay_is_open(&app.overlays, .Quit_Dialog) && !app.quit)
	testing.expect_value(t, ui.focused_label(&app.ui), "Quit Game") // (back where it was)

	// The consent question: No thanks is lit, so mashing A never opts in.
	overlay_open(&app.overlays, .Consent)
	pad_frame(app)
	testing.expect_value(t, ui.focused_label(&app.ui), "No thanks")
	pad_tap(app, .A)
	testing.expect(t, app.settings.share_asked && !app.settings.share_data)
	testing.expect(t, !overlay_is_open(&app.overlays, .Consent))

	// The failed screen: Back is lit.
	app.failed = {
		title  = "Cannot join",
		reason = strings.clone("the server said no"),
		back   = .Title,
	}
	app.screen = .Failed
	pad_frame(app)
	testing.expect_value(t, ui.focused_label(&app.ui), "Back to Title Screen")
	pad_tap(app, .A)
	testing.expect_value(t, app.screen, Screen.Title)

	// With a session: the characters, the loading screen, the game menu, the
	// dial and the chat.
	s := r.s
	app.session = s
	app.screen = .Game
	append(&s.characters, strings.clone("alice"), strings.clone("bob"))
	s.state = .Choosing
	pad_frame(app)
	testing.expect_value(t, ui.focused_label(&app.ui), "alice")
	pad_focus(t, app, "bob")
	pad_tap(app, .A)
	testing.expect_value(t, s.state, Session_State.Connecting)
	testing.expect_value(t, s.config.name, "bob")
	// Loading: Cancel is lit (pressing it ends the session, which needs the GPU).
	s.loading = Loading{}
	pad_frame(app)
	testing.expect_value(t, ui.focused_label(&app.ui), "Cancel")
	s.loading = nil
	// A new character, typed.
	s.state = .Choosing
	pad_frame(app)
	pad_focus(t, app, "new character")
	pad_tap(app, .A)
	pad_type(t, app, "cy")
	pad_tap(app, .Start) // Done: chosen
	testing.expect_value(t, s.state, Session_State.Connecting)
	testing.expect_value(t, s.config.name, "cy")

	s.state = .Playing
	pad_frame(app)
	testing.expect(t, game_controls(app))
	pad_tap(app, .Start) // the game menu
	testing.expect(t, overlay_is_open(&app.overlays, .Game_Menu))
	testing.expect_value(t, ui.focused_label(&app.ui), "Back to Game")
	pad_focus(t, app, "Options")
	pad_tap(app, .A)
	testing.expect(t, overlay_is_open(&app.overlays, .Options))
	pad_tap(app, .B)
	testing.expect(t, !overlay_is_open(&app.overlays, .Options))
	testing.expect(t, overlay_is_open(&app.overlays, .Game_Menu))
	pad_focus(t, app, "Back to Game")
	pad_tap(app, .A)
	testing.expect_value(t, app.overlays.count, 0)
	pad_tap(app, .Start) // Start opens it and closes it
	testing.expect(t, overlay_is_open(&app.overlays, .Game_Menu))
	pad_tap(app, .Start)
	testing.expect_value(t, app.overlays.count, 0)

	// The dial: seven symbols by directions and A, one erased by X.
	dial_open(app, {10, 20, 30})
	pad_frame(app)
	d := &app.dial
	pad_tap(app, .A) // 0
	pad_go(app, .Down)
	pad_tap(app, .A) // one row down
	pad_go(app, .Right)
	pad_tap(app, .A)
	testing.expect_value(t, d.count, 3)
	pad_tap(app, .X) // erased
	testing.expect_value(t, d.count, 2)
	for _ in 0 ..< 4 {pad_tap(app, .A)}
	testing.expect_value(t, d.count, 6)
	testing.expect(t, overlay_is_open(&app.overlays, .Dial))
	pad_tap(app, .A)
	testing.expect(t, !overlay_is_open(&app.overlays, .Dial))
	m, decoded := game.decode_client(s.writer.buf[:])
	_, is_dial := m.(game.Dial)
	testing.expect(t, decoded && is_dial, "no Dial sent")
	clear(&s.writer.buf)

	// The chat: opened by D-pad Up, "hi" typed, sent by Start.
	pad_tap(app, .Dpad_Up)
	testing.expect(t, overlay_is_open(&app.overlays, .Chat))
	pad_frame(app)
	testing.expect(t, ui.osk_is_open(&app.ui), "the chat opens with the keyboard")
	pad_type(t, app, "hi")
	testing.expect_value(t, string(app.chat.text[:]), "hi")
	pad_tap(app, .Start)
	testing.expect(t, !overlay_is_open(&app.overlays, .Chat))
	m, decoded = game.decode_client(s.writer.buf[:])
	said, is_chat := m.(game.Chat)
	testing.expect(t, decoded && is_chat, "no chat line sent")
	testing.expect_value(t, said.text, "hi")
	// B closes the keyboard, B again the chat.
	pad_tap(app, .Dpad_Up)
	pad_frame(app)
	testing.expect(t, ui.osk_is_open(&app.ui))
	pad_tap(app, .B)
	testing.expect(t, !ui.osk_is_open(&app.ui) && overlay_is_open(&app.overlays, .Chat))
	pad_tap(app, .B)
	testing.expect_value(t, app.overlays.count, 0)
	free_all(context.temp_allocator)
}

// The hints follow the device: keycaps while the keyboard is used last, the
// disc and letter of an Xbox pad, the PlayStation's symbols; the setting can
// pin them.
@(test)
test_prompts_follow_device :: proc(t: ^testing.T) {
	r := rig_make(t)
	defer rig_free(r)
	app := r.app
	has :: proc(app: ^App, g: Prompt_Glyph) -> bool {
		for seen in prompts_seen(app) {if seen == g {return true}}
		return false
	}
	key :: proc(k: platform.Key) -> platform.Event {
		return platform.Key_Event{key = k, symbol = k, pressed = true}
	}
	// The title, after a key.
	pad_frame(app, key(.G))
	pad_frame(app)
	testing.expect_value(t, app.actions.device, Device.Keyboard)
	testing.expect(t, has(app, {.Keycap, "Enter"}), "Enter's keycap")
	testing.expect(t, has(app, {.Keycap, "Esc"}), "Esc's keycap")
	// An Xbox pad.
	pad_connect(app, .Xbox)
	pad_tap(app, .Left_Bumper)
	testing.expect_value(t, app.actions.device, Device.Pad)
	pad_frame(app)
	testing.expect(t, has(app, {.Disc, "A"}) && has(app, {.Disc, "B"}), "the Xbox discs")
	testing.expect(t, !has(app, {.Keycap, "Enter"}))
	// A PlayStation pad: the cross and the circle.
	pad_connect(app, .PlayStation)
	pad_tap(app, .Left_Bumper)
	pad_frame(app)
	testing.expect(t, has(app, {.Cross, ""}) && has(app, {.Ring, ""}), "the PlayStation symbols")
	// Pinned to the keyboard: still keycaps after a pad press.
	app.settings.button_prompts = 1
	pad_tap(app, .Left_Bumper)
	pad_frame(app)
	testing.expect(t, has(app, {.Keycap, "Enter"}), "pinned to the keyboard")
	app.settings.button_prompts = 2 // pinned to Xbox on a PlayStation pad
	pad_frame(app)
	testing.expect(t, has(app, {.Disc, "A"}), "pinned to Xbox")
	// A Switch pad's letters are its own; the Deck's are the Xbox's.
	app.settings.button_prompts = 0
	pad_connect(app, .Switch)
	pad_tap(app, .Left_Bumper)
	pad_frame(app)
	testing.expect(t, has(app, {.Disc, "B"}) && has(app, {.Disc, "A"}), "Switch letters")

	// The glyphs are all made: drawn, none empty, edges anti-aliased.
	pixels := make([][4]u8, PROMPT_ICON_SIZE * PROMPT_ICON_SIZE, context.temp_allocator)
	seen_icons := make(map[ui.Icon]bool, 32, context.temp_allocator)
	for shape in Prompt_Shape {
		prompt_shape_pixels(shape, pixels)
		covered, partial := 0, 0
		for p in pixels {
			if p.a > 0 {covered += 1}
			if p.a > 0 && p.a < 255 {partial += 1}
		}
		testing.expectf(t, covered > 0, "%v is empty", shape)
		testing.expectf(t, partial > 0 || shape == .Dpad, "%v has no smooth edge", shape)
		seen_icons[app.prompt_icons[shape]] = true
	}
	testing.expect_value(t, len(seen_icons), len(Prompt_Shape))
	free_all(context.temp_allocator)
}
