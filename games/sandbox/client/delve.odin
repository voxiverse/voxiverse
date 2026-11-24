package sandbox_client

import "client:engine"
import "client:ui"
import "games:sandbox"

// The custodian's fight under a delve (games/sandbox/server/delve_boss.odin), as a player in
// its chamber is told it: a line across the top naming it, its phase, its health and whether
// its casing stands open, the line's foot a bar of its health in the target frame's colours
// (so it keeps within the game's line, clear of the target frame under the compass). Nothing
// shows while the player fights none.

DELVE_BAR_HEIGHT :: 6

// delve_received: the fight the server last put.
delve_received :: proc(s: ^engine.Session, v: ^sandbox.Delve_Fight) {view(s).delve = v^}

// delve_hud: the fight's line and the custodian's bar, while the player fights it.
delve_hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	f := view(s).delve
	if f.phase == 0 {return}
	t := &ctx.theme
	rest := ctx.screen
	key := sandbox.Text.Delve_Boss_Open if f.open else sandbox.Text.Delve_Boss
	engine.top_bar(ctx, &rest, sandbox.tr(key, f.phase, f.phases, f.health, f.most))
	bar := ui.Rect{rest.x, rest.y - DELVE_BAR_HEIGHT, rest.w, DELVE_BAR_HEIGHT}
	fraction := f32(f.health) / f32(max(f.most, 1))
	ui.fill_rect(ctx, bar, t.health_empty)
	ui.fill_rect(ctx, {bar.x, bar.y, bar.w * clamp(fraction, 0, 1), bar.h}, t.health_full)
}
