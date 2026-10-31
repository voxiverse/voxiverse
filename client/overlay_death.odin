package client

import "client:ui"
import "common:game"

// The death screen: how it happened and a Respawn button. It opens when the
// server says the player is dead (Health.dead) and closes when it says they
// are not; only the button leaves it (Escape does not). The words come from
// the server's death line for the source (game.death_text), so the chat and
// the screen agree.

// death_sync: the overlay follows the server's word.
death_sync :: proc(app: ^App) {
	s := app.session
	dead := s != nil && s.state == .Playing && s.dead
	open := overlay_is_open(&app.overlays, .Death)
	if dead && !open {overlay_open(&app.overlays, .Death)}
	if !dead && open {overlay_close(&app.overlays, .Death)}
}

// death_respawn: the button.
death_respawn :: proc(app: ^App) {
	if s := app.session; s != nil && s.dead {send_message(s, game.Respawn{})}
}

death_ui :: proc(app: ^App, ctx: ^ui.Context) {
	s := app.session
	if s == nil {return}
	ui.push_id(ctx, "death")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 420, 170)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, tr(.Death_Title), ui.cut_top(&inner, t.row_height), .Center)
	ui.label(ctx, string(s.death_line[:s.death_len]), ui.cut_top(&inner, t.row_height), .Center)
	buttons := ui.cut_bottom(&inner, t.row_height)
	if ui.button(ctx, tr(.Death_Respawn), buttons) {death_respawn(app)}
	ui.default_focus(ctx)
}
