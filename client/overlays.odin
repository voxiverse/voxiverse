package client

import "../ui"

// Overlays: what is open over the screen, on one stack (the newest on top).
// Each declares what it takes: the keyboard (typing goes to it, game keys
// do not), the mouse (freed from looking), the world (paused, alone). The
// top one gets Escape; game controls run only while nothing takes the
// keyboard or the mouse. A new overlay is a row in OVERLAY_INFO, a
// draw_overlay case, and (when Escape does more than close it) a
// close_overlay case.

Overlay :: enum u8 {
	Game_Menu, // Resume, Options, Open to LAN, Leave
	Options, // Options over the game (above the game menu)
	Tuning, // F4: the tuning panel
	Chat,
	Inventory,
	Console,
	Quit_Dialog,
	Dial, // a gate's symbols (dial.odin)
}

Overlay_Take :: enum u8 {
	Keyboard,
	Mouse,
	World,
}
Overlay_Takes :: bit_set[Overlay_Take]

Overlay_Info :: struct {
	takes:   Overlay_Takes,
	in_game: bool, // only over a world (closed when it is left)
}

@(rodata)
OVERLAY_INFO := [Overlay]Overlay_Info {
	.Game_Menu = {takes = {.Keyboard, .Mouse, .World}, in_game = true},
	.Options = {takes = {.Keyboard, .Mouse, .World}, in_game = true},
	.Tuning = {takes = {.Mouse}, in_game = true}, // watching the game respond: it runs on
	.Chat = {takes = {.Keyboard, .Mouse}, in_game = true},
	.Inventory = {takes = {.Keyboard, .Mouse}, in_game = true},
	.Console = {takes = {.Keyboard, .Mouse}},
	.Quit_Dialog = {takes = {.Keyboard, .Mouse}},
	.Dial = {takes = {.Keyboard, .Mouse}, in_game = true},
}

Overlays :: struct {
	stack: [len(Overlay)]Overlay, // bottom first
	count: int,
}

// overlay_open puts o on top (moving it there if it is open).
overlay_open :: proc(o: ^Overlays, which: Overlay) {
	overlay_close(o, which)
	o.stack[o.count] = which
	o.count += 1
}

// overlay_close removes o (wherever it is in the stack).
overlay_close :: proc(o: ^Overlays, which: Overlay) {
	for i in 0 ..< o.count {
		if o.stack[i] != which {continue}
		copy(o.stack[i:o.count - 1], o.stack[i + 1:o.count])
		o.count -= 1
		return
	}
}

overlay_toggle :: proc(o: ^Overlays, which: Overlay) {
	if overlay_is_open(o, which) {overlay_close(o, which)} else {overlay_open(o, which)}
}

overlay_is_open :: proc(o: ^Overlays, which: Overlay) -> bool {
	for i in 0 ..< o.count {if o.stack[i] == which {return true}}
	return false
}

overlay_top :: proc(o: ^Overlays) -> (Overlay, bool) {
	if o.count == 0 {return {}, false}
	return o.stack[o.count - 1], true
}

// overlays_take: some open overlay takes this.
overlays_take :: proc(o: ^Overlays, what: Overlay_Take) -> bool {
	for i in 0 ..< o.count {if what in OVERLAY_INFO[o.stack[i]].takes {return true}}
	return false
}

// overlays_leave_game closes the overlays that belong to a world.
overlays_leave_game :: proc(o: ^Overlays) {
	for i := o.count - 1; i >= 0; i -= 1 {
		if OVERLAY_INFO[o.stack[i]].in_game {overlay_close(o, o.stack[i])}
	}
}

// world_paused: an overlay pauses the world (the game menu or Options).
world_paused :: proc(app: ^App) -> bool {
	return overlays_take(&app.overlays, .World)
}

// game_controls: the player moves, looks and uses items (nothing over the
// world takes the keyboard or mouse).
game_controls :: proc(app: ^App) -> bool {
	return(
		app.screen == .Game &&
		(app.session == nil || app.session.loading == nil) &&
		!overlays_take(&app.overlays, .Keyboard) &&
		!overlays_take(&app.overlays, .Mouse) \
	)
}

// escape: the top overlay backs out (closing, or a step within it); with
// none, the screen does (in a world: pause; on the title: ask to quit).
escape :: proc(app: ^App) {
	if options_cancel_listening(app) {return}
	if top, ok := overlay_top(&app.overlays); ok {
		close_overlay(app, top)
		return
	}
	switch app.screen {
	case .Worlds:
		// A save's screen (create, edit, delete) back to the list first.
		if app.worlds.mode != .List {app.worlds.mode = .List} else {app.screen = .Title}
	case .Options:
		if app.settings_dirty {settings_save(app)}
		app.screen = .Title
	case .Multiplayer:
		multiplayer_back(app)
	case .Game:
		// (Loading: nothing to pause; Cancel is on the screen.)
		if app.session == nil || app.session.loading == nil {
			overlay_open(&app.overlays, .Game_Menu)
		}
	case .Failed:
		failed_back(app)
	case .Title:
		overlay_open(&app.overlays, .Quit_Dialog)
	}
}

// close_overlay: Escape on it (some take a step back first).
@(private = "file")
close_overlay :: proc(app: ^App, which: Overlay) {
	#partial switch which {
	case .Console:
		if line_search_cancel(&app.console.line) {return}
	case .Chat:
		chat_close(app)
		return
	case .Inventory:
		inventory_close(app)
		return
	case .Options:
		if app.settings_dirty {settings_save(app)}
	}
	overlay_close(&app.overlays, which) // (Options: back to the game menu below)
}

// draw_overlays draws the open overlays bottom to top (the top one drawn
// last: it takes the focus).
draw_overlays :: proc(app: ^App, ctx: ^ui.Context) {
	open := app.overlays // (drawing may close some)
	for i in 0 ..< open.count {
		top := i == open.count - 1
		switch open.stack[i] {
		case .Game_Menu:
			if !overlay_is_open(&app.overlays, .Options) {game_menu(app, ctx)}
		case .Options:
			if options_panel(app, ctx, true) {overlay_close(&app.overlays, .Options)}
		case .Tuning:
			tuning_panel(app, ctx)
		case .Chat:
			chat_ui(app, ctx, top)
		case .Inventory:
			inventory_ui(app, ctx, top)
		case .Console:
			console_ui(app, ctx, top)
		case .Quit_Dialog:
			quit_dialog(app, ctx)
		case .Dial:
			dial_ui(app, ctx, top)
		}
	}
}
