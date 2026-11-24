package hud

import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"

// The quest tracker: at the top right of the screen, the quest the player follows
// (engine.quest_tracked: the one picked in the journal, else the first under way), its
// title and the step it is on, with how far along a step that counts is; the step's text
// wraps to the box. When a step is done (engine.Hud_State.quest_news) the new one eases in
// from the right (at once under Reduce motion). Where the compass reaches the right edge (a
// small window) it sits under the compass instead. Options > Accessibility > Quest tracker
// hides it, and it is not shown to a player whose quests do not count (creative, a watcher).

TRACKER_WIDTH :: 260
TRACKER_MARGIN :: 6 // from the screen's edges (or F3's bottom)
TRACKER_LINES :: 3 // the step's text is cut after this many lines
TRACKER_EASE :: 0.35 // seconds the new step takes to ease in
TRACKER_SLIDE :: 24 // UI units it comes in from

// tracker: the box, under top (F3's bottom; 0: the screen's), clear of the compass
// (compass_rect).
tracker :: proc(app: ^engine.App, ctx: ^ui.Context, top: f32) {
	s := app.session
	q := engine.quest_tracked(s)
	if q < 0 || !app.settings.quest_tracker {return}
	t := &ctx.theme
	def := &s.reg.quests[q]
	progress := s.quests.log.quests[q]
	step := &def.steps[progress.step]
	w := min(f32(TRACKER_WIDTH), ctx.screen.w * 0.4)
	x := ctx.screen.x + ctx.screen.w - w - TRACKER_MARGIN
	y := max(top, ctx.screen.y) + TRACKER_MARGIN
	if c := compass_rect(ctx, top); x < c.x + c.w + t.spacing {y = c.y + c.h + t.spacing}

	small := t.font_size * 0.8
	inner_w := w - 2 * t.padding
	lines := ui.wrap_words(ctx, step.text, t.font_size, inner_w)
	if len(lines) > TRACKER_LINES {
		rest := strings.join(lines[TRACKER_LINES - 1:], " ", context.temp_allocator)
		lines = lines[:TRACKER_LINES]
		lines[TRACKER_LINES - 1] = ui.text_elide(ctx, rest, inner_w, t.font_size)
	}
	line_h := t.font_size + 4
	head_h := small + 6
	r := ui.Rect{x, y, w, t.padding + head_h + f32(len(lines)) * line_h}

	k := engine.tween_value(&s.hud.quest_news, s, TRACKER_EASE)
	faded := ctx.theme
	faded.opacity *= 0.35 + 0.65 * k
	ui.theme_scope(ctx, faded)
	ui.fill_rect(ctx, r, t.hud_fill)
	ui.stroke_rect(ctx, r, 1, t.faint_border)
	ui.fill_rect(ctx, {r.x, r.y, 2, r.h}, engine.MADE_COLOR) // (the quest's gold, as its notices read)

	inner := ui.rect_shrink(r, t.padding / 2)
	inner.x += t.padding / 2
	inner.w -= t.padding / 2
	head := ui.cut_top(&inner, head_h)
	count := ""
	if o := step.objective; o.count > 1 && quest_counted(o.goal) {
		count = engine.tr(.Quest_Count, progress.count, o.count)
	} else if o.goal == .Have && o.count > 1 {
		count = engine.tr(
			.Quest_Count,
			min(game.quest_carried(s.reg, &o, &s.inventory), o.count),
			o.count,
		)
	}
	title_w := inner.w - (ui.measure_text(ctx, count, small) + t.spacing if count != "" else 0)
	ui.draw_text(
		ctx,
		head,
		ui.text_elide(ctx, def.title, title_w, small),
		small,
		engine.MADE_COLOR,
	)
	if count != "" {ui.draw_text(ctx, head, count, small, t.text_muted, .Right)}
	slide := (1 - k) * TRACKER_SLIDE
	ui.push_clip_rect(ctx, r)
	defer ui.pop_clip_rect(ctx)
	for line in lines {
		at := ui.cut_top(&inner, line_h)
		at.x += slide
		ui.draw_text(ctx, {at.x + 1, at.y + 1, at.w, at.h}, line, t.font_size, t.text_shadow)
		ui.draw_text(ctx, at, line, t.font_size, t.text)
	}
}

// quest_counted: a goal whose step counts up (its progress is the log's count).
quest_counted :: proc(g: game.Goal) -> bool {
	#partial switch g {
	case .Make, .Place, .Break, .Kill, .Use:
		return true
	}
	return false
}
