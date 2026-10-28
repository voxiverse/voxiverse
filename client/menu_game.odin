package client

import "core:fmt"

import "../server"
import "ui"

game_menu :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game menu")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	column := ui.rect_center(ctx.screen, 400, 4 * t.row_height + 3 * t.spacing + 80)
	heading := ui.cut_top(&column, 80)
	if s.frozen {
		ui.label(ctx, "Game Paused", ui.cut_bottom(&heading, t.row_height), .Center, t.text_muted)
	}
	ui.title(ctx, "Game Menu", heading)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.default_focus(ctx)
	if ui.button(ctx, "Back to Game", ui.next(ctx)) {overlay_close(&app.overlays, .Game_Menu)}
	if ui.button(ctx, "Options", ui.next(ctx)) {overlay_open(&app.overlays, .Options)}
	if session_hosting(s) {
		port := server.stats(&s.server).port
		label := fmt.tprintf("Open to LAN: port %d", port) if port != 0 else "Open to LAN"
		if ui.button(ctx, label, ui.next(ctx), disabled = port != 0) {session_open_lan(app)}
	}
	// Ours: saved on the way out (a scratch world has nothing to save);
	// someone else's server: we only go.
	leave := "Disconnect"
	if session_hosting(s) {
		leave = "Save and Quit to Title" if s.config.save_dir != "" else "Quit to Title"
	}
	if ui.button(ctx, leave, ui.next(ctx)) {leave_world(app)}
}

// net_line: round trip, traffic per second each way, the busiest kind.

