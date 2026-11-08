package menu


import "client:engine"
import "client:ui"
import "server:core"

game_menu :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game menu")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	port := core.stats(&s.server).port if engine.session_hosting(s) else 0
	rows: f32 = 4 if port == 0 else 5
	if app.devchat.running {rows += 1}
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
	ui.title(ctx, engine.tr(.Game_Menu_Game_Menu), heading)
	ui.begin_column(ctx, column)
	defer ui.end_column(ctx)
	ui.default_focus(ctx)
	if ui.button(
		ctx,
		engine.tr(.Game_Menu_Back_To_Game),
		ui.next(ctx),
	) {engine.overlay_close(&app.overlays, .Game_Menu)}
	if ui.button(
		ctx,
		engine.tr(.Options),
		ui.next(ctx),
	) {engine.overlay_open(&app.overlays, .Options)}
	if app.devchat.running &&
	   ui.button(ctx, engine.tr(.Devchat_Title), ui.next(ctx)) {engine.devchat_open(app)}
	if engine.session_hosting(s) {
		label :=
			engine.tr(.Game_Menu_Open_To_LAN_Port, port) if port != 0 else engine.tr(.Game_Menu_Open_To_LAN)
		if ui.button(ctx, label, ui.next(ctx)) {engine.lan_dialog_open(app)}
		if port != 0 &&
		   ui.button(ctx, engine.tr(.Game_Menu_Close_LAN), ui.next(ctx)) {engine.close_lan(app)}
	}
	// Ours: saved on the way out (a scratch world has nothing to save);
	// someone else's server: we only go.
	leave := engine.tr(.Game_Menu_Disconnect)
	if engine.session_hosting(s) {
		leave =
			engine.tr(.Game_Menu_Save_And_Quit) if s.config.save_dir != "" else engine.tr(.Game_Menu_Quit_To_Title)
	}
	if ui.button(ctx, leave, ui.next(ctx)) {engine.leave_world(app)}
}

// net_line: round trip, traffic per second each way, the busiest kind.
