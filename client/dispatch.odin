package client


import "ui"


// Screens, with overlays over them (overlay.odin). Escape backs out one
// level: the top overlay; else in a world it pauses, on the title it asks
// to quit.

handle_global_keys :: proc(app: ^App, input: ^ui.Input) {
	if app.options.listening != .None {
		// The button pressed is being bound: only Escape or Start (leave
		// it) counts.
		if app.input.escape || .Start in app.input.pad_pressed {escape(app)}
		return
	}
	if app.input.console_toggle {overlay_toggle(&app.overlays, .Console)}
	if .F3 in app.input.pressed {app.debug.overlay = !app.debug.overlay}
	if .F4 in app.input.pressed && app.screen == .Game {
		overlay_toggle(&app.overlays, .Tuning)
		// Tuning is watching the game respond: no game menu in the way.
		if overlay_is_open(&app.overlays, .Tuning) {
			overlay_close(&app.overlays, .Options)
			overlay_close(&app.overlays, .Game_Menu)
		}
	}
	hud_keys(app)
	if action_pressed(&app.actions, .Screenshot) {screenshot_request(app, "")}
	if action_pressed(&app.actions, .Fullscreen) {
		app.settings.fullscreen = !app.settings.fullscreen
		settings_changed(app)
	}
	menu_actions(app, input)
	chat_keys(app, input)
	chest_sync(app)
	player_menu_keys(app)
	dial_keys(app)
}

// menu_actions: what the menus take from the actions this frame: back and the
// game menu key, and the pad's navigation for the UI (input.nav and the rest;
// the keyboard's arrows, Enter and Space reach the UI as keys). While the
// on-screen keyboard is open, the bumpers step its cursor, the stick press is
// Shift and Start is Done, instead of changing tabs and pausing.
menu_actions :: proc(app: ^App, input: ^ui.Input) {
	a := &app.actions
	app.prompts_count = 0
	input.pad = a.device == .Pad
	osk := ui.osk_is_open(&app.ui)
	if app.options.listening == .None && app.actions.context_ == .Menu {
		// (While a binding listens, every button is for the binding.)
		dirs := [4]struct {
			action: Action,
			nav:    ui.Nav,
		}{{.Menu_Up, .Up}, {.Menu_Down, .Down}, {.Menu_Left, .Left}, {.Menu_Right, .Right}}
		for d in dirs {
			if d.action in a.nav_pad {input.nav += {d.nav}}
		}
		if .Menu_Confirm in a.pad_acts {input.nav += {.Confirm}}
		if .Menu_Back in a.pad_acts {input.nav += {.Back}}
		if .Menu_Secondary in a.pad_acts {input.nav += {.Secondary}}
		if .Menu_Tertiary in a.pad_acts {input.nav += {.Tertiary}}
		stick := stick_shape(
			{a.pad_axes[.Right_X], a.pad_axes[.Right_Y]},
			app.settings.stick_dead_zone,
		)
		input.nav_scroll = -stick.y * NAV_SCROLL_ROWS * min(app.last_frame_ms / 1000, 0.1)
		if osk {
			if action_pressed(a, .Tab_Prev) {input.osk_cursor -= 1}
			if action_pressed(a, .Tab_Next) {input.osk_cursor += 1}
			input.osk_shift = .Left_Stick in a.pad_pressed
			if action_pressed(a, .Pause) {input.nav += {.Start}}
		}
	}
	if app.input.escape || action_pressed(a, .Menu_Back) {
		escape(app)
	} else if action_pressed(a, .Pause) && !osk {
		pause_toggle(app)
	}
}

NAV_SCROLL_ROWS :: 10 // rows a second the right stick scrolls a list at full deflection

// Each screen and dialog draws in its own id scope, so equal labels in
// different places (the title's "Quit" and the dialog's "Quit") are distinct
// widgets.
app_ui :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "screen")
	defer ui.pop_id(ctx)
	if app.screen != .Game {
		// Every menu screen over the stars.
		starfield_update(&app.stars, app.last_frame_ms / 1000, app.settings.reduce_motion)
		starfield_draw(ctx, &app.stars, app.settings.reduce_motion)
	}
	switch app.screen {
	case .Title:
		title_screen(app, ctx)
	case .Options:
		options_screen(app, ctx)
	case .Credits:
		credits_screen(app, ctx)
	case .Universes:
		universes_screen(app, ctx)
	case .Multiplayer:
		multiplayer_screen(app, ctx)
	case .Game:
		game_screen(app, ctx)
	case .Failed:
		failed_screen(app, ctx)
	}
	if app.debug.overlay {debug_overlay(app, ctx)}
	if app.settings.show_fps {fps_overlay(app, ctx)}
	draw_overlays(app, ctx)
	toasts_ui(app, ctx)
	if !(app.hud_hidden && app.screen == .Game && app.overlays.count == 0) {
		prompt_bar(app, ctx, prompt_items(app)) // (F1 hides it with the rest of the HUD)
	}
}
