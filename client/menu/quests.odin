package menu

import "client:engine"
import "client:ui"
import "common:game"

// The journal's Quests page: the quests of the registry the player has under way, then
// those done (game.Quest_Log, as the server last said: Session.quests), in a list; beside
// it the quest picked: why (its text), its steps (those done, and the one it is on with how
// far along; the ones after stay unseen), its reward, and Track, which has the HUD's tracker
// and the compass follow it (Session.quest_pick). Quests not yet open are not listed.

QUEST_ROW :: 30
QUEST_LIST :: 0.42 // of the width: the list
QUEST_STEP_ROW :: 24
QUEST_BOX :: 10 // a step's box: filled when done

// quests_listed: the quests to list, those under way first, then those done, each in the
// registry's order.
quests_listed :: proc(s: ^engine.Session) -> []int {
	log := &s.quests.log
	open := make([dynamic]int, context.temp_allocator)
	done := make([dynamic]int, context.temp_allocator)
	for q in 0 ..< min(len(s.reg.quests), game.MAX_QUESTS) {
		if game.quest_open(s.reg, log, q) {append(&open, q)}
		if game.quest_done(s.reg, log, q) {append(&done, q)}
	}
	append(&open, ..done[:])
	return open[:]
}

// quests_page: the page in content.
quests_page :: proc(app: ^engine.App, ctx: ^ui.Context, content: ui.Rect) {
	s := app.session
	t := &ctx.theme
	m := &app.player_menu
	log := &s.quests.log
	area := content
	listed := quests_listed(s)
	left := pane(
		ctx,
		ui.cut_left(&area, (area.w - t.spacing) * QUEST_LIST),
		engine.tr(.Journal_Quests_Page),
	)
	ui.cut_left(&area, t.spacing)
	if len(listed) == 0 {
		ui.draw_text(
			ctx,
			ui.cut_top(&left, JOURNAL_ROW),
			engine.tr(.Quests_None),
			t.font_size,
			t.text_muted,
		)
		return
	}
	// A row past the list (it changed) picks the tracked quest.
	if m.quest_list.selected < 0 || m.quest_list.selected >= len(listed) {
		m.quest_list.selected = 0
		for q, i in listed {if q == engine.quest_tracked(s) {m.quest_list.selected = i}}
	}
	view := ui.list_begin(ctx, "quests", left, len(listed), QUEST_ROW, &m.quest_list)
	for i in view.first ..< view.last {
		q := listed[i]
		def := &s.reg.quests[q]
		row, _ := ui.list_row(ctx, &view, i, def.title)
		line := ui.rect_shrink(row, 2)
		line.x += t.padding / 2
		line.w -= t.padding
		done := game.quest_done(s.reg, log, q)
		state := engine.tr(.Quest_Finished)
		if !done {state = engine.tr(.Quest_Count, log.quests[q].step, len(def.steps))}
		state_w := ui.measure_text(ctx, state, t.font_size * 0.8) + t.spacing
		title := ui.text_elide(ctx, def.title, line.w - state_w, t.font_size)
		if q == engine.quest_tracked(s) {
			ui.fill_rect(ctx, {row.x + 1, row.y + 3, 2, row.h - 6}, engine.MADE_COLOR)
		}
		ui.draw_text(ctx, line, title, t.font_size, t.text_muted if done else t.text)
		ui.draw_text(ctx, line, state, t.font_size * 0.8, t.text_muted, .Right)
	}
	ui.list_end(ctx, &view)
	q := listed[clamp(m.quest_list.selected, 0, len(listed) - 1)]
	quest_detail(app, ctx, pane(ctx, area, s.reg.quests[q].title), q)
}

// quest_detail: quest q in r: its text, its steps, its reward and Track.
@(private = "file")
quest_detail :: proc(app: ^engine.App, ctx: ^ui.Context, r: ui.Rect, q: int) {
	s := app.session
	t := &ctx.theme
	def := &s.reg.quests[q]
	log := &s.quests.log
	area := r
	area.x += t.padding / 2
	area.w -= t.padding
	small := t.font_size * 0.8
	open := game.quest_open(s.reg, log, q)
	track: ui.Rect
	if open {track = ui.cut_bottom(&area, t.row_height)}
	for line in ui.wrap_words(ctx, def.text, small, area.w) {
		ui.draw_text(ctx, ui.cut_top(&area, small + 6), line, small, t.text_muted)
	}
	ui.cut_top(&area, t.spacing)
	ui.draw_text(ctx, ui.cut_top(&area, JOURNAL_ROW), engine.tr(.Quest_Steps), small, t.text_muted)
	on := int(log.quests[q].step)
	for &step, i in def.steps[:min(on + 1, len(def.steps))] {
		lines := ui.wrap_words(
			ctx,
			step.text,
			t.font_size,
			area.w - QUEST_BOX - 2 * t.spacing - 48,
		)
		row := ui.cut_top(&area, QUEST_STEP_ROW + f32(max(len(lines) - 1, 0)) * (t.font_size + 4))
		box := ui.Rect{row.x, row.y + (QUEST_STEP_ROW - QUEST_BOX) / 2, QUEST_BOX, QUEST_BOX}
		text := row
		text.x += QUEST_BOX + t.spacing
		text.w -= QUEST_BOX + t.spacing
		if i < on {
			ui.fill_rect(ctx, box, engine.MADE_COLOR)
		} else {
			ui.stroke_rect(ctx, box, 1, t.text)
			o := &step.objective
			count := ""
			switch {
			case o.goal == .Have && o.count > 1:
				count = engine.tr(
					.Quest_Count,
					min(game.inventory_count(&s.inventory, o.item), o.count),
					o.count,
				)
			case o.count > 1:
				count = engine.tr(.Quest_Count, log.quests[q].count, o.count)
			}
			ui.draw_text(
				ctx,
				{text.x, text.y, text.w, QUEST_STEP_ROW},
				count,
				small,
				t.text_muted,
				.Right,
			)
		}
		for line, k in lines {
			at := ui.Rect{text.x, text.y + f32(k) * (t.font_size + 4), text.w, QUEST_STEP_ROW}
			ui.draw_text(ctx, at, line, t.font_size, t.text_muted if i < on else t.text)
		}
	}
	ui.cut_top(&area, t.spacing)
	ui.draw_text(
		ctx,
		ui.cut_top(&area, JOURNAL_ROW),
		engine.tr(.Quest_Reward),
		small,
		t.text_muted,
	)
	if len(def.reward) == 0 {
		ui.draw_text(
			ctx,
			ui.cut_top(&area, JOURNAL_ROW),
			engine.tr(.Quest_No_Reward),
			t.font_size,
			t.text_muted,
		)
	}
	icons := &app.item_icons
	hover: game.Stack
	hover_at: Maybe(ui.Rect)
	for st in def.reward {
		if area.h < INVENTORY_SLOT.y {break}
		row := ui.cut_top(&area, INVENTORY_SLOT.y + 4)
		slot := ui.cut_left(&row, INVENTORY_SLOT.x)
		ui.cut_left(&row, t.spacing)
		cell := ui.cut_top(&slot, INVENTORY_SLOT.y)
		stack_slot(ctx, s.reg, icons, cell, st, false)
		if ui.rect_contains(cell, ctx.input.mouse) {hover, hover_at = st, cell}
		ui.draw_text(
			ctx,
			{row.x, row.y, row.w, INVENTORY_SLOT.y},
			engine.tr(.Hud_Pickup, st.count, item_title(s.reg, st.item)),
			t.font_size,
			rarity_color(t, item_rarity(s.reg, st.item)),
		)
	}
	if open {
		tracked := engine.quest_tracked(s) == q
		label := engine.tr(.Quest_Tracked if tracked else .Quest_Track)
		if ui.button(ctx, label, track, disabled = tracked) {s.quest_pick = q + 1}
	}
	item_tooltip(ctx, s.reg, hover, beside = hover_at)
}
