package hud

import "core:fmt"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"

// proto/flood: the round on screen: a status line at the top, the countdown,
// a drowning warning, and at the end the result and the rule, big.
flood_hud :: proc(app: ^engine.App, ctx: ^ui.Context) {
	s := app.session
	f := s.flood
	if f.round == 0 {return}
	t := &ctx.theme
	r := ctx.screen
	top := ui.cut_top(&r, 34)
	ui.fill_rect(ctx, top, t.hud_fill)
	you_y := int(s.camera.position.y)
	line: string
	switch f.phase {
	case .Waiting:
		line = "FLOOD  waiting for players"
	case .Countdown:
		line = fmt.tprintf("FLOOD  round %d  starting", f.round)
	case .Playing:
		line = fmt.tprintf(
			"FLOOD  round %d   %d:%02d   water y=%d   you y=%d   goal y=%d   alive %d/%d   on goal %d",
			f.round,
			f.seconds / 60,
			f.seconds % 60,
			f.level,
			you_y,
			f.goal_y + 1,
			f.alive,
			f.players,
			f.on_goal,
		)
	case .Reveal:
		line = fmt.tprintf("FLOOD  round %d over", f.round)
	}
	ui.draw_text(ctx, top, line, t.font_size, t.text, .Center)

	mid := ui.rect_center(ctx.screen, 0, 0)
	big := t.title_size * 1.5
	banner :: proc(ctx: ^ui.Context, y: f32, text: string, size: f32, color: ui.Color) {
		r := ui.Rect{0, y - size, ctx.screen.w, size * 2}
		ui.draw_text(ctx, {r.x + 3, r.y + 3, r.w, r.h}, text, size, ctx.theme.text_shadow, .Center)
		ui.draw_text(ctx, r, text, size, color, .Center)
	}
	switch f.phase {
	case .Waiting:
	case .Countdown:
		banner(ctx, mid.y - 140, fmt.tprintf("ROUND %d", f.round), big, t.focus_ring)
		banner(ctx, mid.y - 60, fmt.tprintf("%d", f.countdown), big, t.text)
		banner(
			ctx,
			mid.y + 40,
			"Reach the glowing platform. Something is different.",
			t.title_size * 0.6,
			t.text,
		)
	case .Playing:
		if f.out {
			banner(ctx, mid.y - 140, "YOU ARE OUT: spectating (fly)", t.title_size, t.log_error)
		} else if f.under > 0 {
			banner(
				ctx,
				mid.y - 140,
				fmt.tprintf("DROWNING %.1f", f32(f.under) / 10),
				t.title_size,
				t.log_error,
			)
		} else if f.seconds < 8 {
			banner(
				ctx,
				mid.y - 140,
				fmt.tprintf("Water in %d", 8 - int(f.seconds)),
				t.title_size,
				t.focus_ring,
			)
		}
	case .Reveal:
		head: string
		color := t.text
		switch f.result {
		case .Won:
			head, color = "ROUND WON", t.success
		case .Lost:
			head, color = "EVERYONE DROWNED", t.log_error
		case .Time_Up:
			head, color = "TIME UP", t.log_warn
		case .None:
			head = "ROUND OVER"
		}
		banner(ctx, mid.y - 180, head, big, color)
		banner(
			ctx,
			mid.y - 90,
			fmt.tprintf("%d of %d made it", f.made_it, f.players),
			t.title_size * 0.8,
			t.text,
		)
		banner(ctx, mid.y - 10, "The rule was", t.title_size * 0.6, t.text_muted)
		banner(
			ctx,
			mid.y + 60,
			strings.to_upper(game.FLOOD_RULE_TITLES[f.rule], context.temp_allocator),
			t.title_size,
			t.log_warn,
		)
		banner(
			ctx,
			mid.y + 140,
			fmt.tprintf("next round in %d", f.countdown),
			t.title_size * 0.6,
			t.text_muted,
		)
	}
}
