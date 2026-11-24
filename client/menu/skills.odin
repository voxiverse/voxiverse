package menu

import "core:fmt"
import "core:math"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"

// The Character section (C, where the registry has a skill sheet): the player's level, its
// experience into the level and what the next takes, and its skill points left (the
// `progress` record, the registry's curve); under them a pane for each branch of the sheet
// with its skills (each its rank, muted while its branch has not had what it `needs`
// spent), and under them the skill picked: what it does, what its ranks do now and what
// one more would, what a rank costs or what opens it, Learn, and Unlearn all, which the
// server allows within the curve's reach of its respec block (game.respec_near, as the
// session holds the blocks; the button says where). Learning and unlearning are the
// server's commands (`skill <id>`, `skill reset`): the record it sends back shows them.

SKILL_ROW :: 30
SKILL_DETAIL :: 0.36 // of the skill picked's pane: its buttons
XP_METER :: 8

@(rodata)
EFFECT_TEXT := [game.Skill_Effect]engine.Text {
	.Break_Speed      = .Effect_Break_Speed,
	.Yield_Chance     = .Effect_Yield_Chance,
	.Drop_Chance      = .Effect_Drop_Chance,
	.Max_Health       = .Effect_Max_Health,
	.Defence          = .Effect_Defence,
	.Fall_Guard       = .Effect_Fall_Guard,
	.Regen            = .Effect_Regen,
	.Consume_Strength = .Effect_Consume_Strength,
	.Melee_Damage     = .Effect_Melee_Damage,
	.Reload_Time      = .Effect_Reload_Time,
	.Spread           = .Effect_Spread,
	.Craft_Time       = .Effect_Craft_Time,
	.Craft_Yield      = .Effect_Craft_Yield,
}

// skill_effect_text: what rank ranks of a skill do, "+20% break speed" (most health in
// points, the rest in hundredths).
skill_effect_text :: proc(def: ^game.Skill_Def, ranks: int) -> string {
	amount := def.amount * f32(ranks)
	if def.effect == .Max_Health {
		return engine.tr(EFFECT_TEXT[def.effect], fmt.tprintf("%+d", int(math.round(amount))))
	}
	return engine.tr(EFFECT_TEXT[def.effect], fmt.tprintf("%+d%%", int(math.round(amount * 100))))
}

// character_ui: the section.
character_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	content, shown := section_frame(app, ctx)
	if !shown || len(s.reg.skills) == 0 {return}
	reg := s.reg
	xp := u64(s.progress.xp)
	ranks := &s.progress.skills
	level := game.level_of(reg, xp)
	given, spent := game.skill_points(reg, xp, ranks)

	// The level, the experience and the points; the bar.
	head := ui.cut_top(&content, t.row_height)
	ui.draw_text(ctx, head, engine.tr(.Skills_Level, level), t.font_size * 1.2, engine.MADE_COLOR)
	into := engine.tr(.Skills_Xp_Top, xp)
	if level < game.level_max(reg) {
		floor := game.level_floor(reg, level)
		into = engine.tr(.Skills_Xp, xp - floor, game.level_floor(reg, level + 1) - floor)
	}
	ui.draw_text(ctx, head, into, t.font_size, t.text, .Center)
	ui.draw_text(
		ctx,
		head,
		engine.tr(.Skills_Points, given - spent),
		t.font_size,
		engine.MADE_COLOR if given > spent else t.text_muted,
		.Right,
	)
	meter := ui.cut_top(&content, XP_METER)
	ui.fill_rect(ctx, meter, t.meter_back)
	ui.fill_rect(
		ctx,
		{meter.x, meter.y, meter.w * game.level_progress(reg, xp), meter.h},
		engine.MADE_COLOR,
	)
	ui.cut_top(&content, 2 * t.spacing)

	// The branches, side by side.
	m := &app.player_menu
	m.skill_pick = clamp(m.skill_pick, 0, len(reg.skills) - 1)
	branches := reg.progression.branches
	most := 0 // the most skills a branch has
	for _, b in branches {
		n := 0
		for &def in reg.skills {if def.branch == b {n += 1}}
		most = max(most, n)
	}
	tall := PANE_HEADING + t.padding + f32(most) * (SKILL_ROW + t.spacing / 2)
	area := ui.cut_top(&content, min(tall, content.h * 0.6))
	ui.cut_top(&content, t.spacing)
	n := f32(max(len(branches), 1))
	column_w := (area.w - (n - 1) * t.spacing) / n
	for name, b in branches {
		column := ui.cut_left(&area, column_w)
		ui.cut_left(&area, t.spacing)
		inner := pane(ctx, column, name)
		heading := ui.Rect{column.x, column.y + t.padding / 2, column.w - t.padding, PANE_HEADING}
		spent := engine.tr(.Skills_Spent, game.skill_spent_in(reg, ranks, b))
		ui.draw_text(ctx, heading, spent, t.font_size * 0.8, t.text_muted, .Right)
		for &def, i in reg.skills {
			if def.branch != b || inner.h < SKILL_ROW {continue}
			row := ui.cut_top(&inner, SKILL_ROW)
			ui.cut_top(&inner, t.spacing / 2)
			skill_row(ctx, s, row, i, i == m.skill_pick, &m.skill_pick)
		}
	}
	skill_detail(app, ctx, pane(ctx, content, reg.skills[m.skill_pick].title), m.skill_pick)
}

// skill_row: skill i as a row of its branch: its title and its rank, lit when picked,
// muted while shut; picked by a click (or the pad's A).
@(private = "file")
skill_row :: proc(
	ctx: ^ui.Context,
	s: ^engine.Session,
	r: ui.Rect,
	i: int,
	picked: bool,
	pick: ^int,
) {
	t := &ctx.theme
	def := &s.reg.skills[i]
	rank := int(s.progress.skills.ranks[i])
	it := ui.interact(ctx, ui.get_id(ctx, def.id), r, label = def.title)
	if it.clicked {pick^ = i}
	if picked {
		ui.fill_rect(ctx, r, t.row_selected)
		ui.fill_rect(ctx, {r.x + 1, r.y + 3, 2, r.h - 6}, engine.MADE_COLOR)
	} else if it.hovered {
		ui.fill_rect(ctx, r, t.row_hover)
	}
	shut := game.skill_spent_in(s.reg, &s.progress.skills, def.branch) < def.needs
	ink := t.text_muted if shut else t.text
	if rank == def.ranks {ink = engine.MADE_COLOR}
	line := ui.rect_shrink(r, 2)
	line.x += t.padding / 2
	line.w -= t.padding
	count := engine.tr(.Skills_Rank, rank, def.ranks)
	count_w := ui.measure_text(ctx, count, t.font_size * 0.8) + t.spacing
	ui.draw_text(
		ctx,
		line,
		ui.text_elide(ctx, def.title, line.w - count_w, t.font_size),
		t.font_size,
		ink,
	)
	ui.draw_text(ctx, line, count, t.font_size * 0.8, ink, .Right)
	if it.focused && ctx.focus_visible {ui.stroke_rect(ctx, r, 2, t.border)}
}

// skill_detail: skill i in r: its text, what it does now and with one more rank, its cost
// or what opens it, Learn; at the bottom Unlearn all and where it may be done.
@(private = "file")
skill_detail :: proc(app: ^engine.App, ctx: ^ui.Context, r: ui.Rect, i: int) {
	s := app.session
	t := &ctx.theme
	reg := s.reg
	def := &reg.skills[i]
	ranks := &s.progress.skills
	rank := int(ranks.ranks[i])
	area := r
	area.x += t.padding / 2
	area.w -= t.padding
	small := t.font_size * 0.85
	side := ui.cut_right(&area, area.w * SKILL_DETAIL)
	ui.cut_right(&area, 2 * t.spacing)
	lines :: proc(ctx: ^ui.Context, area: ^ui.Rect, text: string, size: f32, ink: ui.Color) {
		for line in ui.wrap_words(ctx, text, size, area.w) {
			ui.draw_text(ctx, ui.cut_top(area, size + 6), line, size, ink)
		}
	}
	lines(ctx, &area, def.text, small, t.text_muted)
	ui.cut_top(&area, t.spacing)
	now := engine.tr(.Skills_Nothing) if rank == 0 else skill_effect_text(def, rank)
	lines(ctx, &area, engine.tr(.Skills_Now, now), t.font_size, t.text)
	if rank < def.ranks {
		lines(
			ctx,
			&area,
			engine.tr(.Skills_Next, skill_effect_text(def, rank + 1)),
			t.font_size,
			engine.MADE_COLOR,
		)
		lines(ctx, &area, engine.tr(.Skills_Cost, def.cost), small, t.text_muted)
	}
	why := game.skill_can_learn(reg, ranks, u64(s.progress.xp), i)
	if why == .Shut {
		lines(
			ctx,
			&area,
			engine.tr(.Skills_Needs, def.needs, reg.progression.branches[def.branch]),
			small,
			t.warning,
		)
	}
	learn := ui.cut_top(&side, t.row_height)
	unlearn := ui.cut_bottom(&side, t.row_height)
	label := engine.tr(.Skills_All_Learnt if why == .Full else .Skills_Learn)
	if ui.button(ctx, label, learn, disabled = why != .None, id = "learn") {
		engine.send_message(s, protocol.Command{fmt.tprintf("skill %s", def.id)})
	}
	query := game.Block_Query{&s.world, engine.world_block, &reg.blocks, {}}
	here := game.respec_near(reg, query, s.feet)
	free_at := engine.tr(.Skills_Unlearn_Free)
	if !here {
		_, _, name := strings.partition(reg.progression.respec_name, ":")
		block, _ := strings.replace_all(name, "_", " ", context.temp_allocator)
		article := "an" if len(block) > 0 && strings.index_byte("aeiou", block[0]) >= 0 else "a"
		free_at = engine.tr(
			.Skills_Unlearn_Where,
			reg.progression.respec_reach,
			fmt.tprintf("%s %s", article, block),
		)
	}
	wrapped := ui.wrap_words(ctx, free_at, small, side.w)
	for line, k in wrapped {
		at := ui.Rect {
			side.x,
			unlearn.y - t.spacing - f32(len(wrapped) - k) * (small + 6),
			side.w,
			small + 6,
		}
		ui.draw_text(ctx, at, line, small, t.text_muted, .Center)
	}
	learnt := ranks^ != {}
	if ui.button(
		ctx,
		engine.tr(.Skills_Unlearn),
		unlearn,
		disabled = !here || !learnt,
		id = "unlearn",
	) {
		engine.send_message(s, protocol.Command{"skill reset"})
	}
}
