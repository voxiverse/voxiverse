package overlay

import "core:math"

import "client:engine"
import "client:ui"
import "common:protocol"

// The death screen: how it happened, where the player will stand again, what became of
// what it carried, and a Respawn button. It opens when the server says the player is dead
// (Health.dead) and closes when it says they are not; only the button leaves it (Escape
// does not). The words come from the server's death line for the source (game.death_text),
// so the chat and the screen agree; where is the game's word (Player_Died.respawn: its
// respawn_where hook; none, the world's spawn), and whether what it carried was dropped
// where it fell is the server's, by the mode and the world's rules. Until the world's
// respawn_delay is over, the button's place counts it down (the server would refuse it);
// under respawn_auto the server stands the player up itself when it is.

DEATH_SIZE :: ui.Vec2{520, 236} // the screen's panel

// death_sync: the overlay follows the server's word.
death_sync :: proc(app: ^engine.App) {
	s := app.session
	dead := s != nil && s.state == .Playing && s.dead
	open := engine.overlay_is_open(&app.overlays, .Death)
	if dead && !open {engine.overlay_open(&app.overlays, .Death)}
	if !dead && open {engine.overlay_close(&app.overlays, .Death)}
}

// death_respawn: the button.
death_respawn :: proc(app: ^engine.App) {
	if s := app.session; s != nil && s.dead {engine.send_message(s, protocol.Respawn{})}
}

// death_wait: whole seconds until the player may come back (0: now).
death_wait :: proc(s: ^engine.Session) -> int {
	return int(math.ceil(max(s.rules.respawn_delay - s.death_age, 0)))
}

death_ui :: proc(app: ^engine.App, ctx: ^ui.Context) {
	s := app.session
	if s == nil {return}
	ui.push_id(ctx, "death")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, min(DEATH_SIZE.x, ctx.screen.w), DEATH_SIZE.y)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, engine.tr(.Death_Title), ui.cut_top(&inner, t.row_height), .Center)
	ui.label(ctx, string(s.death_line[:s.death_len]), ui.cut_top(&inner, t.row_height), .Center)
	stand := engine.tr(.Death_Respawn_Spawn)
	if s.death_respawn_len > 0 {
		stand = engine.tr(.Death_Respawn_At, string(s.death_respawn[:s.death_respawn_len]))
	}
	small := t.font_size * 0.85
	ui.draw_text(ctx, ui.cut_top(&inner, small + 10), stand, small, t.text, .Center)
	kept := engine.tr(.Death_Dropped if s.death_dropped else .Death_Kept)
	ui.draw_text(ctx, ui.cut_top(&inner, small + 10), kept, small, t.text_muted, .Center)
	buttons := ui.cut_bottom(&inner, t.row_height)
	if wait := death_wait(s); wait > 0 {
		text := engine.tr(.Death_Coming_Back if s.rules.respawn_auto else .Death_Wait, wait)
		ui.label(ctx, text, buttons, .Center, t.text_muted)
		return
	}
	if ui.button(ctx, engine.tr(.Death_Respawn), buttons) {death_respawn(app)}
	ui.default_focus(ctx)
}
