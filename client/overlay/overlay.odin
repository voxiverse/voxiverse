package overlay

import "client:console"
import "client:dev"
import "client:engine"
import "client:menu"
import "client:screen"
import "client:ui"

// Overlays: what is open over the screen, on one stack (the newest on top).
// Each declares what it takes: the keyboard (typing goes to it, game keys
// do not), the mouse (freed from looking), the world (paused, alone). The
// top one gets Escape; game controls run only while nothing takes the
// keyboard or the mouse. A new overlay is a row in OVERLAY_INFO, a
// draw_overlay case, and (when Escape does more than close it) a
// close_overlay case.

// escape: the top overlay backs out (closing, or a step within it); with
// none, the screen does (in a world: pause; on the title: ask to quit).
escape :: proc(app: ^engine.App) {
	if screen.options_cancel_listening(app) {return}
	if ui.osk_cancel(&app.ui) {return} 	// (B and Escape close the keyboard before the screen)
	if top, ok := engine.overlay_top(&app.overlays); ok {
		close_overlay(app, top)
		return
	}
	switch app.screen {
	case .Universes:
		// A card's menu, rename, delete or import back to the list first.
		if app.universes.mode != .List {app.universes.mode = .List} else {app.screen = .Title}
	case .Creation:
		app.screen = .Universes
	case .Options:
		if app.settings_dirty {engine.settings_save(app)}
		app.screen = .Title
	case .Credits:
		screen.credits_back(app)
	case .Multiplayer:
		screen.multiplayer_back(app)
	case .Game:
		// (Loading: nothing to pause; Cancel is on the screen.)
		if app.session == nil || app.session.loading == nil {
			engine.overlay_open(&app.overlays, .Game_Menu)
		}
	case .Failed:
		screen.failed_back(app)
	case .Title:
		engine.overlay_open(&app.overlays, .Quit_Dialog)
	}
}

// pause_toggle: the pad's Start. In a world with nothing open, the game
// menu; with in-game overlays open, each closed through its own close path
// (Options saving if dirty), back to playing; elsewhere nothing.
pause_toggle :: proc(app: ^engine.App) {
	if app.screen != .Game {return}
	top_open, open := engine.overlay_top(&app.overlays)
	if !open {
		if engine.game_controls(app) {engine.overlay_open(&app.overlays, .Game_Menu)}
		return
	}
	if top_open == .Death {return}
	for _ in 0 ..< 8 {
		top, ok := engine.overlay_top(&app.overlays)
		if !ok {return}
		close_overlay(app, top)
		if again, still := engine.overlay_top(&app.overlays); still && again == top {
			engine.overlay_close(&app.overlays, top) // a step back it kept: closed outright
		}
	}
}

// close_overlay: Escape on it (some take a step back first).
@(private = "file")
close_overlay :: proc(app: ^engine.App, which: engine.Overlay) {
	#partial switch which {
	case .Console:
		if engine.line_search_cancel(&app.console.line) {return}
	case .Chat:
		chat_close(app)
		return
	case .Crash_Report:
		engine.crash_offer_dismiss(app)
		return
	case .Death:
		return // (only Respawn leaves it)
	case .Devchat:
		engine.devchat_close(app)
		return
	case .Player_Menu:
		menu.player_menu_close(app)
		return
	case .Options:
		if app.settings_dirty {engine.settings_save(app)}
	}
	engine.overlay_close(&app.overlays, which) // (Options: back to the game menu below)
}

// draw_overlays draws the open overlays bottom to top (the top one drawn
// last: it takes the focus).
draw_overlays :: proc(app: ^engine.App, ctx: ^ui.Context) {
	open := app.overlays // (drawing may close some)
	for i in 0 ..< open.count {
		top := i == open.count - 1
		switch open.stack[i] {
		case .Game_Menu:
			if !engine.overlay_is_open(&app.overlays, .Options) {menu.game_menu(app, ctx)}
		case .Options:
			if screen.options_panel(app, ctx, true) {engine.overlay_close(&app.overlays, .Options)}
		case .Tuning:
			dev.tuning_panel(app, ctx)
		case .Chat:
			chat_ui(app, ctx, top)
		case .Player_Menu:
			menu.player_menu_ui(app, ctx, top)
		case .Console:
			console.console_ui(app, ctx, top)
		case .Quit_Dialog:
			quit_dialog(app, ctx)
		case .Dial:
			dial_ui(app, ctx, top)
		case .Audio_Inspector:
			dev.audio_inspector_ui(app, ctx)
		case .Consent:
			engine.consent_dialog(app, ctx)
		case .Open_To_LAN:
			lan_dialog_ui(app, ctx)
		case .Crash_Report:
			engine.crash_dialog(app, ctx)
		case .Death:
			death_ui(app, ctx)
		case .Devchat:
			devchat_ui(app, ctx, top)
		case .Market:
			screen.market_ui(app, ctx, top)
		}
	}
	devchat_notice(app)
}
