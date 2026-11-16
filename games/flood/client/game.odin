package flood_client

import "core:fmt"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
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

received :: proc(s: ^engine.Session, r: game.Received) {
	if round, ok := engine.game_value(s, r, flood.Round); ok && round != nil {
		view(s).round = round^
	}
}

// status: the line at the top of the screen; you_y is where the player is.
status :: proc(f: flood.Round, you_y: int) -> string {
	switch f.phase {
	case .Waiting:
		return "FLOOD  waiting for players"
	case .Countdown:
		return fmt.tprintf("FLOOD  round %d  starting", f.round)
	case .Playing:
		return fmt.tprintf(
			"FLOOD  round %d   %d:%02d   water y=%d   you y=%d   goal y=%d   alive %d/%d   on goal %d",
			f.round,
			f.seconds / 60,
			f.seconds % 60,
			f.level,
			you_y,
			flood.GOAL_Y + 1,
			f.alive,
			f.players,
			f.on_goal,
		)
	case .Reveal:
		return fmt.tprintf("FLOOD  round %d over", f.round)
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
		engine.banner(ctx, -140, fmt.tprintf("ROUND %d", f.round), 1.5, t.focus_ring)
		engine.banner(ctx, -60, fmt.tprintf("%d", f.countdown), 1.5, t.text)
		engine.banner(ctx, 40, "Reach the glowing platform. Something is different.", 0.6, t.text)
	case .Playing:
		switch {
		case f.out:
			engine.banner(ctx, -140, "WATCHING: out of this round (fly)", 1, t.log_error)
		case f.under > 0:
			engine.banner(
				ctx,
				-140,
				fmt.tprintf("DROWNING %.1f", f32(f.under) / 10),
				1,
				t.log_error,
			)
		case f.seconds < u16(flood.GRACE):
			left := int(flood.GRACE) - int(f.seconds)
			engine.banner(ctx, -140, fmt.tprintf("Water in %d", left), 1, t.focus_ring)
		}
	case .Reveal:
		head, color := "ROUND OVER", t.text
		switch f.result {
		case .Won:
			head, color = "ROUND WON", t.success
		case .Lost:
			head, color = "EVERYONE DROWNED", t.log_error
		case .Time_Up:
			head, color = "TIME UP", t.log_warn
		case .None:
		}
		engine.banner(ctx, -180, head, 1.5, color)
		engine.banner(ctx, -90, fmt.tprintf("%d of %d made it", f.made_it, f.players), 0.8, t.text)
		engine.banner(ctx, -10, "The rule was", 0.6, t.text_muted)
		title := strings.to_upper(flood.RULE_TITLES[f.rule], context.temp_allocator)
		engine.banner(ctx, 60, title, 1, t.log_warn)
		engine.banner(ctx, 140, fmt.tprintf("next round in %d", f.countdown), 0.6, t.text_muted)
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
