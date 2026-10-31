package main


import "client:dev"
import "client:engine"
import "client:hud"
import "client:menu"
import "client:overlay"
import "client:prompt"
import "client:screen"
import "client:starfield"
import "client:ui"


// Screens, with overlays over them (overlay.odin). Escape backs out one
// level: the top overlay; else in a world it pauses, on the title it asks
// to quit.

handle_global_keys :: proc(app: ^engine.App, input: ^ui.Input) {
	if app.options.listening != .None {
		// The button pressed is being bound: only Escape or Start (leave
		// it) counts.
		if app.input.escape || .Start in app.input.pad_pressed {overlay.escape(app)}
		return
	}
	if app.input.console_toggle {engine.overlay_toggle(&app.overlays, .Console)}
	if .F3 in app.input.pressed {app.debug.overlay = !app.debug.overlay}
	if .F4 in app.input.pressed && app.screen == .Game {
		engine.overlay_toggle(&app.overlays, .Tuning)
		// Tuning is watching the game respond: no game menu in the way.
		if engine.overlay_is_open(&app.overlays, .Tuning) {
			engine.overlay_close(&app.overlays, .Options)
			engine.overlay_close(&app.overlays, .Game_Menu)
		}
	}
	hud.hud_keys(app)
	if engine.action_pressed(&app.actions, .Screenshot) {engine.screenshot_request(app, "")}
	if engine.action_pressed(&app.actions, .Fullscreen) {
		app.settings.fullscreen = !app.settings.fullscreen
		engine.settings_changed(app)
	}
	menu_actions(app, input)
	overlay.chat_keys(app, input)
	menu.chest_sync(app)
	menu.player_menu_keys(app)
	overlay.dial_keys(app)
	overlay.death_sync(app)
}

// menu_actions: what the menus take from the actions this frame: back and the
// game menu key, and the pad's navigation for the UI (input.nav and the rest;
// the keyboard's arrows, Enter and Space reach the UI as keys). While the
// on-screen keyboard is open, the bumpers step its cursor, the stick press is
// Shift and Start is Done, instead of changing tabs and pausing.
menu_actions :: proc(app: ^engine.App, input: ^ui.Input) {
	a := &app.actions
	app.prompts_count = 0
	input.pad = a.device == .Pad
	osk := ui.osk_is_open(&app.ui)
	if app.options.listening == .None && app.actions.context_ == .Menu {
		// (While a binding listens, every button is for the binding.)
		dirs := [4]struct {
			action: engine.Action,
			nav:    ui.Nav,
		}{{.Menu_Up, .Up}, {.Menu_Down, .Down}, {.Menu_Left, .Left}, {.Menu_Right, .Right}}
		for d in dirs {
			if d.action in a.nav_pad {input.nav += {d.nav}}
		}
		if .Menu_Confirm in a.pad_acts {input.nav += {.Confirm}}
		if .Menu_Back in a.pad_acts {input.nav += {.Back}}
		if .Menu_Secondary in a.pad_acts {input.nav += {.Secondary}}
		if .Menu_Tertiary in a.pad_acts {input.nav += {.Tertiary}}
		stick := engine.stick_shape(
			{a.pad_axes[.Right_X], a.pad_axes[.Right_Y]},
			app.settings.stick_dead_zone,
		)
		input.nav_scroll = -stick.y * NAV_SCROLL_ROWS * min(app.last_frame_ms / 1000, 0.1)
		if osk {
			if engine.action_pressed(a, .Tab_Prev) {input.osk_cursor -= 1}
			if engine.action_pressed(a, .Tab_Next) {input.osk_cursor += 1}
			input.osk_shift = .Left_Stick in a.pad_pressed
			if engine.action_pressed(a, .Pause) {input.nav += {.Start}}
		}
	}
	if app.input.escape || engine.action_pressed(a, .Menu_Back) {
		overlay.escape(app)
	} else if engine.action_pressed(a, .Pause) && !osk {
		overlay.pause_toggle(app)
	}
}

NAV_SCROLL_ROWS :: 10 // rows a second the right stick scrolls a list at full deflection

// Each screen and dialog draws in its own id scope, so equal labels in
// different places (the title's "Quit" and the dialog's "Quit") are distinct
// widgets.
app_ui :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "screen")
	defer ui.pop_id(ctx)
	if app.screen != .Game {
		// Every menu screen over the stars.
		starfield.starfield_update(
			&app.stars,
			app.last_frame_ms / 1000,
			app.settings.reduce_motion,
		)
		starfield.starfield_draw(ctx, &app.stars, app.settings.reduce_motion)
	}
	switch app.screen {
	case .Title:
		screen.title_screen(app, ctx)
	case .Options:
		screen.options_screen(app, ctx)
	case .Credits:
		screen.credits_screen(app, ctx)
	case .Universes:
		screen.universes_screen(app, ctx)
	case .Creation:
		screen.creation_screen(app, ctx)
	case .Multiplayer:
		screen.multiplayer_screen(app, ctx)
	case .Game:
		hud.game_screen(app, ctx)
	case .Failed:
		screen.failed_screen(app, ctx)
	}
	if app.debug.overlay {dev.debug_overlay(app, ctx)}
	if app.settings.show_fps {dev.fps_overlay(app, ctx)}
	overlay.draw_overlays(app, ctx)
	screen.ignite_ui(app, ctx)
	overlay.toasts_ui(app, ctx)
	if !(app.hud_hidden && app.screen == .Game && app.overlays.count == 0) {
		prompt.prompt_bar(app, ctx, prompt.prompt_items(app)) // (F1 hides it with the rest of the HUD)
	}
}
