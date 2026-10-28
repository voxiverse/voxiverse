package client

import "core:math"

import "../common/game"
import "ui"

// HOTBAR_OPACITY: how opaque the hotbar is (1: as the rest; tuned by eye).
HOTBAR_OPACITY :: 1

hotbar :: proc(ctx: ^ui.Context, s: ^Session, icons: ^Item_Icons) {
	faded := ctx.theme
	faded.opacity *= HOTBAR_OPACITY
	ui.theme_scope(ctx, faded)
	t := &ctx.theme
	r := ctx.screen
	row := ui.cut_bottom(&r, SLOT_SIZE.y + 24)
	row = ui.rect_center(row, game.HOTBAR_SLOTS * (SLOT_SIZE.x + t.spacing), SLOT_SIZE.y)
	// The offhand slot, left of the hotbar (F swaps it with the hand).
	off := ui.Rect{row.x - 2 * t.spacing - SLOT_SIZE.x, row.y, SLOT_SIZE.x, SLOT_SIZE.y}
	stack_slot(ctx, s.reg, icons, off, s.inventory.equipment[.Offhand], false)
	for i in 0 ..< game.HOTBAR_SLOTS {
		slot := ui.cut_left(&row, SLOT_SIZE.x)
		ui.cut_left(&row, t.spacing)
		stack_slot(ctx, s.reg, icons, slot, s.inventory.slots[i], i == s.inventory.selected, i + 1)
	}
}

@(private = "file", rodata)
HEART := [6]string{".XX.XX.", "XXXXXXX", "XXXXXXX", ".XXXXX.", "..XXX..", "...X..."}

// health_bar: a heart for every two health points, over the hotbar's left
// end: full, half or empty.
health_bar :: proc(ctx: ^ui.Context, s: ^Session) {
	if s.max_health <= 0 || !s.rules.damage {return}
	t := &ctx.theme
	r := ctx.screen
	row := ui.cut_bottom(&r, SLOT_SIZE.y + 24)
	row = ui.rect_center(row, game.HOTBAR_SLOTS * (SLOT_SIZE.x + t.spacing), SLOT_SIZE.y)
	PIXEL :: f32(2)
	hearts := int(math.ceil(s.max_health / 2))
	for i in 0 ..< hearts {
		x := row.x + f32(i) * (7 * PIXEL + 2)
		y := row.y - 6 * PIXEL - 6
		full := s.health >= f32(2 * i + 2)
		half := !full && s.health > f32(2 * i)
		for line, ry in HEART {
			for ch, rx in line {
				if ch != 'X' {continue}
				c := t.health_empty
				if full || (half && rx < 4) {c = t.health_full}
				ui.fill_rect(ctx, {x + f32(rx) * PIXEL, y + f32(ry) * PIXEL, PIXEL, PIXEL}, c)
			}
		}
	}
}
