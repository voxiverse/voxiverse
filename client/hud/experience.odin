package hud

import "client:engine"
import "client:ui"
import "common:game"

// The experience bar: where the game has levels (game.progression_on), a thin bar in the
// gap between the hotbar and the health bar, full to how far the player is from its level
// to the next (the `progress` record, the registry's curve); the level in a badge left of
// the health bar, which pops when a level comes (Hud_State.level_news, at once under
// Reduce motion); and, while skill points wait to be spent, how many and the key of the
// Character section, right of the health bar in gold. Options > Accessibility > Experience
// bar hides it.

XP_BAR_HEIGHT :: 4
LEVEL_BADGE :: [2]f32{46, HEALTH_BAR_HEIGHT + 6}
XP_FILL :: engine.MADE_COLOR // the bar's colour: the gold of things gained

// experience_bar: the bar, the badge and the points.
experience_bar :: proc(app: ^engine.App, ctx: ^ui.Context) {
	s := app.session
	if !app.settings.experience_bar || !game.progression_on(s.reg) {return}
	t := &ctx.theme
	xp := u64(s.progress.xp)
	row := hotbar_row(ctx)
	health := ui.Rect{row.x, row.y - 8 - HEALTH_BAR_HEIGHT, row.w, HEALTH_BAR_HEIGHT}
	bar := ui.Rect{row.x, row.y - 2 - XP_BAR_HEIGHT, row.w, XP_BAR_HEIGHT}
	ui.fill_rect(ctx, bar, t.meter_back)
	ui.fill_rect(ctx, {bar.x, bar.y, bar.w * game.level_progress(s.reg, xp), bar.h}, XP_FILL)

	level := game.level_of(s.reg, xp)
	pop := engine.tween_value(&s.hud.level_news, s, 0.35, .Out_Back)
	badge := ui.Rect {
		health.x - 6 - LEVEL_BADGE.x,
		health.y,
		LEVEL_BADGE.x,
		bar.y + bar.h - health.y,
	}
	ui.fill_rect(ctx, badge, t.hud_fill)
	ui.stroke_rect(ctx, badge, 1, ui.with_alpha(XP_FILL, 200))
	text := engine.tr(.Hud_Level, level)
	size := t.font_size * 0.8 * (0.75 + 0.25 * pop)
	ui.draw_text(
		ctx,
		{badge.x + 1, badge.y + 1, badge.w, badge.h},
		text,
		size,
		t.text_shadow,
		.Center,
	)
	ui.draw_text(ctx, badge, text, size, XP_FILL, .Center)

	given, spent := game.skill_points(s.reg, xp, &s.progress.skills)
	if given <= spent || len(s.reg.skills) == 0 {return}
	hint := engine.tr(.Hud_Points, given - spent, engine.action_label(app, .Character))
	small := t.font_size * 0.7
	w := ui.measure_text(ctx, hint, small)
	at := ui.Rect{health.x + health.w + 8, health.y, w, health.h}
	ui.draw_text(ctx, {at.x + 1, at.y + 1, at.w, at.h}, hint, small, t.text_shadow)
	ui.draw_text(ctx, at, hint, small, XP_FILL)
}
