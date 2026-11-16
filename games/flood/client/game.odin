package flood_client

import "core:fmt"

import "client:engine"
import "client:ui"
import "common:protocol"
import "games:flood"

// Flood's client part (the game: games/flood): it keeps the round as the server last told
// it, and shows it: a status line at the top of the HUD, the countdown, the drowning
// warning, and at the end the result and the rule, big; and in F3, the rule too.

GAME :: engine.Game {
	info     = flood.INFO,
	kinds    = flood.KINDS,
	state    = View,
	received = received,
	hud      = hud,
	debug    = debug,
}

// View: what the session knows of the round.
View :: struct {
	round: flood.Round, // the server's last word (round 0: none yet)
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	if round, ok := engine.game_value(s, r, flood.Round); ok && round != nil {
		view(s).round = round^
	}
}

// status: the line at the top of the screen; you_y is where the player is.
status :: proc(f: flood.Round, you_y: int) -> string {
	switch f.phase {
	case .Waiting:
		return flood.tr(.Status_Waiting)
	case .Countdown:
		return flood.tr(.Status_Starting, f.round)
	case .Playing:
		clock := fmt.tprintf("%d:%02d", f.seconds / 60, f.seconds % 60)
		return flood.tr(
			.Status_Playing,
			f.round,
			clock,
			f.level,
			you_y,
			flood.GOAL_Y + 1,
			f.alive,
			f.players,
			f.on_goal,
		)
	case .Reveal:
		return flood.tr(.Status_Over, f.round)
	}
	return ""
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	f := view(s).round
	if f.round == 0 {return}
	t := &ctx.theme
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(f, int(s.camera.position.y)))
	switch f.phase {
	case .Waiting:
	case .Countdown:
		engine.banner(ctx, -140, flood.tr(.Round_Title, f.round), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", f.countdown), 1.5, t.text)
		engine.banner(ctx, 40, flood.tr(.Round_Goal), 0.6, t.text)
	case .Playing:
		switch {
		case f.out:
			engine.banner(ctx, -140, flood.tr(.Watching), 1, t.log_error)
		case f.under > 0:
			under := fmt.tprintf("%.1f", f32(f.under) / 10)
			engine.banner(ctx, -140, flood.tr(.Drowning, under), 1, t.log_error)
		case f.seconds < u16(flood.GRACE):
			left := int(flood.GRACE) - int(f.seconds)
			engine.banner(ctx, -140, flood.tr(.Water_In, left), 1, t.focus_ring)
		}
	case .Reveal:
		head, color := flood.tr(.Result_Over), t.text
		switch f.result {
		case .Won:
			head, color = flood.tr(.Result_Won), t.success
		case .Lost:
			head, color = flood.tr(.Result_Lost), t.log_error
		case .Time_Up:
			head, color = flood.tr(.Result_Time_Up), t.log_warn
		case .None:
		}
		engine.banner(ctx, -180, head, 1.5, color)
		engine.banner(ctx, -90, flood.tr(.Made_It, f.made_it, f.players), 0.8, t.text)
		engine.banner(ctx, -10, flood.tr(.Rule_Was), 0.6, t.text_muted)
		engine.banner(ctx, 60, flood.rule_title(f.rule), 1, t.log_warn)
		engine.banner(ctx, 140, flood.tr(.Next_Round, f.countdown), 0.6, t.text_muted)
	}
}

// debug: F3's line, the hidden rule with the rest.
debug :: proc(s: ^engine.Session) -> string {
	f := view(s).round
	return fmt.tprintf(
		"round %d %v  rule %s  water y=%d  t=%ds  alive %d/%d  on goal %d  seed %d",
		f.round,
		f.phase,
		flood.RULE_NAMES[f.rule],
		f.level,
		f.seconds,
		f.alive,
		f.players,
		f.on_goal,
		f.seed,
	)
}
