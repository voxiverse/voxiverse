package menu


import "client:engine"
import "client:ui"
import "server:core"

// Game_Menu_Entry: a button of the game menu.
Game_Menu_Entry :: enum u8 {
	Back_To_Game,
	Options,
	Open_To_LAN, // (its label says the port once open)
	Close_LAN,
	Save_And_Quit,
	Quit_To_Title, // our own world, not saved (a scratch world)
	Disconnect, // someone else's server
}

// game_menu_entries: the game menu's buttons, top to bottom: hosting (our own world),
// lan_open (and open to the LAN), saved (and kept on disk). The menu is strict, the
// owner's rule: these and nothing else (a place's code is the `share` command's, the
// developer chat F9's). test_game_menu_entries holds the list, so a button added here
// fails the build until the test, and that rule, say otherwise.
game_menu_entries :: proc(
	hosting, lan_open, saved: bool,
	allocator := context.temp_allocator,
) -> []Game_Menu_Entry {
	entries := make([dynamic]Game_Menu_Entry, 0, 5, allocator)
	append(&entries, Game_Menu_Entry.Back_To_Game, Game_Menu_Entry.Options)
	if !hosting {
		append(&entries, Game_Menu_Entry.Disconnect)
		return entries[:]
	}
	append(&entries, Game_Menu_Entry.Open_To_LAN)
	if lan_open {append(&entries, Game_Menu_Entry.Close_LAN)}
	append(&entries, Game_Menu_Entry.Save_And_Quit if saved else Game_Menu_Entry.Quit_To_Title)
	return entries[:]
}

// game_menu: over the world, under the name of the game it plays: game_menu_entries.
game_menu :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game menu")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	hosting := engine.session_hosting(s)
	port := core.stats(&s.server).port if hosting else 0
	entries := game_menu_entries(hosting, port != 0, s.config.save_dir != "")
	rows := f32(len(entries))
	column := ui.rect_center(ctx.screen, 400, rows * t.row_height + (rows - 1) * t.spacing + 80)
	heading := ui.cut_top(&column, 80)
	if s.frozen {
		ui.label(
			ctx,
			engine.tr(.Game_Menu_Game_Paused),
			ui.cut_bottom(&heading, t.row_height),
			.Center,
			t.text_muted,
		)
	}
	// The game's name (a session that has not been told its game yet: the menu's).
	ui.title(ctx, s.game.name if s.game.name != "" else engine.tr(.Game_Menu_Game_Menu), heading)
	ui.begin_column(ctx, column)
	defer ui.end_column(ctx)
	ui.default_focus(ctx)
	for entry in entries {
		switch entry {
		case .Back_To_Game:
			if ui.button(
				ctx,
				engine.tr(.Game_Menu_Back_To_Game),
				ui.next(ctx),
			) {engine.overlay_close(&app.overlays, .Game_Menu)}
		case .Options:
			if ui.button(
				ctx,
				engine.tr(.Options),
				ui.next(ctx),
			) {engine.overlay_open(&app.overlays, .Options)}
		case .Open_To_LAN:
			label :=
				engine.tr(.Game_Menu_Open_To_LAN_Port, port) if port != 0 else engine.tr(.Game_Menu_Open_To_LAN)
			if ui.button(ctx, label, ui.next(ctx)) {engine.lan_dialog_open(app)}
		case .Close_LAN:
			if ui.button(
				ctx,
				engine.tr(.Game_Menu_Close_LAN),
				ui.next(ctx),
			) {engine.close_lan(app)}
		case .Save_And_Quit, .Quit_To_Title, .Disconnect:
			// Ours: saved on the way out (a scratch world has nothing to save);
			// someone else's server: we only go.
			leave := engine.Text.Game_Menu_Disconnect
			if entry == .Save_And_Quit {leave = .Game_Menu_Save_And_Quit}
			if entry == .Quit_To_Title {leave = .Game_Menu_Quit_To_Title}
			if ui.button(ctx, engine.tr(leave), ui.next(ctx)) {engine.leave_world(app)}
		}
	}
}

// net_line: round trip, traffic per second each way, the busiest kind.
