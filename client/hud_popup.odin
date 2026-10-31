package client

import "client:ui"
import "common:game"

// The item-name popup: the held item's name above the
// hotbar when the selected slot changes, the first frame in a world
// included; it holds POPUP_HOLD seconds and fades over POPUP_FADE; an empty
// slot shows nothing. With Reduce motion it does not fade: it shows for the
// hold and is gone.

POPUP_HOLD :: 1.5
POPUP_FADE :: 0.5

Item_Popup :: struct {
	seen:   bool, // a slot has been seen (not yet: the first frame in a world shows)
	slot:   int, // the slot last seen selected
	age:    f32, // seconds since it began
	item:   game.Item,
	active: bool,
}

// popup_reset: out of a world (the next one starts afresh).
popup_reset :: proc(p: ^Item_Popup) {
	p^ = {}
}

// popup_update: one frame with the selected slot and its stack.
popup_update :: proc(p: ^Item_Popup, selected: int, held: game.Stack, dt: f32) {
	if !p.seen || selected != p.slot {
		p.seen, p.slot, p.age = true, selected, 0
		p.active = !game.stack_empty(held)
		p.item = held.item
		return
	}
	p.age += dt
	if p.age >= POPUP_HOLD + POPUP_FADE {p.active = false}
}

// popup_alpha: how opaque the popup is now (0: not shown).
popup_alpha :: proc(p: ^Item_Popup, reduce_motion: bool) -> f32 {
	if !p.active {return 0}
	if reduce_motion {return 1 if p.age < POPUP_HOLD else 0}
	if p.age < POPUP_HOLD {return 1}
	return clamp(1 - (p.age - POPUP_HOLD) / POPUP_FADE, 0, 1)
}

// hud_popup: the name above the hotbar (and the hearts).
hud_popup :: proc(app: ^App, ctx: ^ui.Context) {
	s := app.session
	p := &app.popup
	selected := s.inventory.selected
	popup_update(p, selected, s.inventory.slots[selected], app.last_frame_ms / 1000)
	alpha := popup_alpha(p, app.settings.reduce_motion)
	if alpha <= 0 {return}
	faded := ctx.theme
	faded.opacity *= alpha
	ui.theme_scope(ctx, faded)
	t := &ctx.theme
	r := ctx.screen
	row := ui.cut_bottom(&r, SLOT_SIZE.y + 24 + 50) // (above the hearts)
	row = ui.cut_top(&row, t.row_height)
	ui.draw_text(ctx, row, item_title(s.reg, p.item), t.font_size, t.text, .Center)
}
