package hud


import "client:engine"
import "client:menu"
import "client:ui"
import "common:game"

// The target frame: the creature under the crosshair (within engine.TARGET_RANGE, in
// sight: Hud_State.aimed), its name with its threat at the right (game.kind_threat, the
// colour of its danger: threat_color) and its health as a bar with the number, under the
// compass; it stays TARGET_HOLD seconds after the crosshair leaves it, fading.

// threat_color: how a threat reads: muted for the harmless (2 and under), the text's to
// 5, orange to 10, red past it.
threat_color :: proc(t: ^ui.Theme, threat: int) -> ui.Color {
	switch {
	case threat <= 2:
		return t.text_muted
	case threat <= 5:
		return t.text
	case threat <= 10:
		return t.warning
	}
	return t.health_full
}

TARGET_WIDTH :: 280
TARGET_HOLD :: 1.0
TARGET_FADE :: 0.4
TARGET_GAP :: 64 // under the compass, clear of a game's line across the top

// target_frame: the frame, under top (the compass's bottom).
target_frame :: proc(ctx: ^ui.Context, s: ^engine.Session, top: f32) {
	h := &s.hud
	if id, ok := h.aimed.?; ok {
		h.target, h.target_seen = id, engine.feel_now(s)
	}
	id, ok := h.target.?
	if !ok {return}
	age := engine.feel_age(s, h.target_seen)
	e, known := &s.entities[id]
	if !known || age >= TARGET_HOLD {
		h.target = nil
		return
	}
	t := &ctx.theme
	faded := ctx.theme
	faded.opacity *= clamp((TARGET_HOLD - age) / TARGET_FADE, 0, 1)
	ui.theme_scope(ctx, faded)
	hurt := e.max_health > 0
	height := t.row_height - 8 + (18 if hurt else 0)
	r := ui.Rect {
		ctx.screen.x + (ctx.screen.w - TARGET_WIDTH) / 2,
		top + TARGET_GAP,
		TARGET_WIDTH,
		height,
	}
	ui.fill_rect(ctx, r, t.hud_fill)
	ui.stroke_rect(ctx, r, 1, t.faint_border)
	inner := ui.rect_shrink(r, 4)
	name_row := ui.cut_top(&inner, t.row_height - 16)
	ui.draw_text(ctx, name_row, menu.creature_name(s.reg, e.kind), t.font_size, t.text, .Center)
	if threat := game.kind_threat(game.kind_info(s.reg, e.kind)); threat > 0 {
		ui.draw_text(
			ctx,
			name_row,
			engine.tr(.Target_Threat, threat),
			t.font_size * 0.7,
			threat_color(t, threat),
			.Right,
		)
	}
	if !hurt {return}
	bar := ui.rect_shrink(ui.cut_top(&inner, 16), 2)
	fraction := f32(e.health) / f32(e.max_health)
	ui.fill_rect(ctx, bar, t.health_empty)
	ui.fill_rect(ctx, {bar.x, bar.y, bar.w * clamp(fraction, 0, 1), bar.h}, t.health_full)
	ui.draw_text(
		ctx,
		bar,
		engine.tr(.Hud_Health, int(e.health), int(e.max_health)),
		t.font_size * 0.7,
		t.text,
		.Center,
	)
}
