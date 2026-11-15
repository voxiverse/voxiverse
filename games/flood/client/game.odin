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

// banner: a line of big text across the screen, centred on y, with a shadow.
banner :: proc(ctx: ^ui.Context, y: f32, text: string, size: f32, color: ui.Color) {
	r := ui.Rect{ctx.screen.x, y - size, ctx.screen.w, size * 2}
	ui.draw_text(ctx, {r.x + 3, r.y + 3, r.w, r.h}, text, size, ctx.theme.text_shadow, .Center)
	ui.draw_text(ctx, r, text, size, color, .Center)
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	f := view(s).round
	if f.round == 0 {return}
	t := &ctx.theme
	screen := ctx.screen
	top := ui.cut_top(&screen, t.row_height + t.padding)
	ui.fill_rect(ctx, top, t.hud_fill)
	ui.draw_text(ctx, top, status(f, int(s.camera.position.y)), t.font_size, t.text, .Center)

	// The banners are laid out for a 720-high screen and shrink with a smaller one (the
	// engine gives the HUD only the screen below F3 while it is open).
	k := min(1, ctx.screen.h / 720)
	mid := ctx.screen.y + ctx.screen.h / 2
	big := t.title_size * 1.5 * k
	size := t.title_size * k
	switch f.phase {
	case .Waiting:
	case .Countdown:
		banner(ctx, mid - 140 * k, fmt.tprintf("ROUND %d", f.round), big, t.focus_ring)
		banner(ctx, mid - 60 * k, fmt.tprintf("%d", f.countdown), big, t.text)
		banner(
			ctx,
			mid + 40 * k,
			"Reach the glowing platform. Something is different.",
			size * 0.6,
			t.text,
		)
	case .Playing:
		switch {
		case f.out:
			banner(ctx, mid - 140 * k, "WATCHING: out of this round (fly)", size, t.log_error)
		case f.under > 0:
			banner(
				ctx,
				mid - 140 * k,
				fmt.tprintf("DROWNING %.1f", f32(f.under) / 10),
				size,
				t.log_error,
			)
		case f.seconds < u16(flood.GRACE):
			banner(
				ctx,
				mid - 140 * k,
				fmt.tprintf("Water in %d", int(flood.GRACE) - int(f.seconds)),
				size,
				t.focus_ring,
			)
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
		banner(ctx, mid - 180 * k, head, big, color)
		banner(
			ctx,
			mid - 90 * k,
			fmt.tprintf("%d of %d made it", f.made_it, f.players),
			size * 0.8,
			t.text,
		)
		banner(ctx, mid - 10 * k, "The rule was", size * 0.6, t.text_muted)
		title := strings.to_upper(flood.RULE_TITLES[f.rule], context.temp_allocator)
		banner(ctx, mid + 60 * k, title, size, t.log_warn)
		banner(
			ctx,
			mid + 140 * k,
			fmt.tprintf("next round in %d", f.countdown),
			size * 0.6,
			t.text_muted,
		)
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
