package hud

import "core:fmt"
import "core:math"

import "client:engine"
import "client:menu"
import "client:ui"
import "common:game"

// HOTBAR_OPACITY: how opaque the hotbar is (1: as the rest; tuned by eye).
HOTBAR_OPACITY :: 1

hotbar :: proc(ctx: ^ui.Context, s: ^engine.Session, icons: ^engine.Item_Icons) {
	faded := ctx.theme
	faded.opacity *= HOTBAR_OPACITY
	ui.theme_scope(ctx, faded)
	t := &ctx.theme
	row := hotbar_row(ctx)
	// The offhand slot, left of the hotbar (F swaps it with the hand).
	off := ui.Rect {
		row.x - 2 * t.spacing - engine.SLOT_SIZE.x,
		row.y,
		engine.SLOT_SIZE.x,
		engine.SLOT_SIZE.y,
	}
	menu.stack_slot(ctx, s.reg, icons, off, s.inventory.equipment[.Offhand], false)
	for i in 0 ..< game.HOTBAR_SLOTS {
		slot := ui.cut_left(&row, engine.SLOT_SIZE.x)
		ui.cut_left(&row, t.spacing)
		menu.stack_slot(
			ctx,
			s.reg,
			icons,
			slot,
			s.inventory.slots[i],
			i == s.inventory.selected,
			i + 1,
		)
	}
}

HEALTH_BAR_HEIGHT :: 16
TRAIL_HOLD :: 0.4 // seconds the health bar's trail stands after a hit ...
TRAIL_FALL :: 0.5 // ... and falls to the health over
HARM_PULSE_ALPHA :: 90 // the screen's edge in the health colour when hurt (engine.pulse)

// hotbar_row: where the hotbar is (its slots from its left, a slot and a gap each).
hotbar_row :: proc(ctx: ^ui.Context) -> ui.Rect {
	t := &ctx.theme
	r := ctx.screen
	row := ui.cut_bottom(&r, engine.SLOT_SIZE.y + 24)
	return ui.rect_center(
		row,
		game.HOTBAR_SLOTS * (engine.SLOT_SIZE.x + t.spacing) - t.spacing,
		engine.SLOT_SIZE.y,
	)
}

// health_bar: a bar as wide as the hotbar over it, full to the health, with the number in
// it ("18 / 20"); a hit leaves a pale trail of what was lost that falls to the health after
// a moment, and the screen's edge glows red (with the arc toward what hurt us: weapon_hud).
health_bar :: proc(ctx: ^ui.Context, s: ^engine.Session) {
	h := &s.hud
	defer h.trail_health = s.health
	if s.max_health <= 0 || !engine.session_ability(s, .Health) {return}
	t := &ctx.theme
	if s.health < h.trail_health && !s.dead {
		falling :=
			engine.feel_age(s, h.trail_born) < TRAIL_HOLD + TRAIL_FALL && h.trail > h.trail_health
		h.trail = max(h.trail, h.trail_health) if falling else h.trail_health // (hits in a row: from the first)
		h.trail_born = engine.feel_now(s)
		engine.pulse(s, ui.with_alpha(t.health_full, HARM_PULSE_ALPHA))
	}
	row := hotbar_row(ctx)
	bar := ui.Rect{row.x, row.y - 8 - HEALTH_BAR_HEIGHT, row.w, HEALTH_BAR_HEIGHT}
	most := s.max_health
	health := clamp(s.health, 0, most)
	trail := health
	if age := engine.feel_age(s, h.trail_born); h.trail > health && age < TRAIL_HOLD + TRAIL_FALL {
		fall := clamp((age - TRAIL_HOLD) / TRAIL_FALL, 0, 1)
		trail = h.trail + (health - h.trail) * ui.ease(.In_Out, fall)
	}
	ui.fill_rect(ctx, ui.rect_expand(bar, 1), t.meter_back)
	ui.fill_rect(ctx, bar, t.health_empty)
	ui.fill_rect(ctx, {bar.x, bar.y, bar.w * trail / most, bar.h}, ui.with_alpha(t.text, 150))
	ui.fill_rect(ctx, {bar.x, bar.y, bar.w * health / most, bar.h}, t.health_full)
	text := engine.tr(.Hud_Health, int(math.ceil(health)), int(most))
	small := t.font_size * 0.8
	ui.draw_text(ctx, {bar.x + 1, bar.y + 1, bar.w, bar.h}, text, small, t.text_shadow, .Center)
	ui.draw_text(ctx, bar, text, small, t.text, .Center)
}

EFFECT_SIZE :: 30

// effects_row: what is on the character now, over the health bar's left end: first a
// consumable's effect still running (its icon and its seconds left, as the server says),
// then an icon for each piece of equipment that changes them (its modifiers: the feather
// charm's air jump, the boots' speed), with its first change beside it. Nothing when
// nothing does.
effects_row :: proc(ctx: ^ui.Context, s: ^engine.Session, icons: ^engine.Item_Icons) {
	row := hotbar_row(ctx)
	x := row.x
	y := row.y - 8 - HEALTH_BAR_HEIGHT - 6 - EFFECT_SIZE
	if s.effect != game.NO_ITEM && s.effect_left > 0 {
		running := game.Stack{s.effect, 1, 0, 0}
		effect_cell(ctx, s, icons, &x, y, running, engine.tr(.Hud_Effect_Seconds, s.effect_left))
	}
	for st in s.inventory.equipment {
		if game.stack_empty(st) {continue}
		stats := menu.item_stats(s.reg, st.item)
		effect := ""
		for k in menu.Stat {
			if k in stats.has && k in menu.STAT_SIGNED {
				effect = menu.number_text(stats.value[k], true)
				if k in menu.STAT_PERCENT {effect = fmt.tprintf("%s%%", effect)}
				break
			}
		}
		if effect == "" {continue}
		effect_cell(ctx, s, icons, &x, y, st, effect)
	}
}

// effect_cell: one of the effects row's: the stack's icon framed in its rarity's colour at
// x, and the text beside it; x moves on past them.
@(private = "file")
effect_cell :: proc(
	ctx: ^ui.Context,
	s: ^engine.Session,
	icons: ^engine.Item_Icons,
	x: ^f32,
	y: f32,
	st: game.Stack,
	effect: string,
) {
	t := &ctx.theme
	small := t.font_size * 0.7
	cell := ui.Rect{x^, y, EFFECT_SIZE, EFFECT_SIZE}
	ui.fill_rect(ctx, cell, t.hud_fill)
	frame := menu.rarity_color(t, menu.item_rarity(s.reg, st.item))
	ui.stroke_rect(ctx, cell, 1, ui.with_alpha(frame, 200))
	if icon, ok := icons[st.item]; ok {ui.draw_icon(ctx, ui.rect_shrink(cell, 3), icon)}
	w := ui.measure_text(ctx, effect, small)
	label := ui.Rect{x^ + EFFECT_SIZE + 3, y, w, EFFECT_SIZE}
	ui.draw_text(ctx, {label.x + 1, label.y + 1, label.w, label.h}, effect, small, t.text_shadow)
	ui.draw_text(ctx, label, effect, small, t.text)
	x^ += EFFECT_SIZE + 3 + w + t.spacing
}
