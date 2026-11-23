package hud

import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"

// The target frame: the creature under the crosshair (within engine.TARGET_RANGE, in
// sight: Hud_State.aimed), its name and its health as a bar with the number, under the
// compass; it stays TARGET_HOLD seconds after the crosshair leaves it, fading.

TARGET_WIDTH :: 280
TARGET_HOLD :: 1.0
TARGET_FADE :: 0.4
TARGET_GAP :: 64 // under the compass, clear of a game's line across the top

// creature_title: a creature's name as players read it ("shambler").
creature_title :: proc(reg: ^game.Registry, kind: game.Kind_Id) -> string {
	info := game.kind_info(reg, kind)
	if info == nil {return ""}
	name, _ := strings.replace_all(game.kind_name(info), "_", " ", context.temp_allocator)
	return name
}

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
	ui.draw_text(
		ctx,
		ui.cut_top(&inner, t.row_height - 16),
		creature_title(s.reg, e.kind),
		t.font_size,
		t.text,
		.Center,
	)
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
