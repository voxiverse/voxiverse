package client


import "client:ui"
import "server:."

game_menu :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game menu")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	port := server.stats(&s.server).port if session_hosting(s) else 0
	rows: f32 = 4 if port == 0 else 5
	column := ui.rect_center(ctx.screen, 400, rows * t.row_height + (rows - 1) * t.spacing + 80)
	heading := ui.cut_top(&column, 80)
	if s.frozen {
		ui.label(
			ctx,
			tr(.Game_Menu_Game_Paused),
			ui.cut_bottom(&heading, t.row_height),
			.Center,
			t.text_muted,
		)
	}
	ui.title(ctx, tr(.Game_Menu_Game_Menu), heading)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.default_focus(ctx)
	if ui.button(
		ctx,
		tr(.Game_Menu_Back_To_Game),
		ui.next(ctx),
	) {overlay_close(&app.overlays, .Game_Menu)}
	if ui.button(ctx, tr(.Options), ui.next(ctx)) {overlay_open(&app.overlays, .Options)}
	if session_hosting(s) {
		label := tr(.Game_Menu_Open_To_LAN_Port, port) if port != 0 else tr(.Game_Menu_Open_To_LAN)
		if ui.button(ctx, label, ui.next(ctx)) {lan_dialog_open(app)}
		if port != 0 && ui.button(ctx, tr(.Game_Menu_Close_LAN), ui.next(ctx)) {close_lan(app)}
	}
	// Ours: saved on the way out (a scratch world has nothing to save);
	// someone else's server: we only go.
	leave := tr(.Game_Menu_Disconnect)
	if session_hosting(s) {
		leave =
			tr(.Game_Menu_Save_And_Quit) if s.config.save_dir != "" else tr(.Game_Menu_Quit_To_Title)
	}
	if ui.button(ctx, leave, ui.next(ctx)) {leave_world(app)}
}

// net_line: round trip, traffic per second each way, the busiest kind.
