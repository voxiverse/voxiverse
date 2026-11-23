package hud

import "client:engine"
import "client:menu"
import "client:ui"
import "common:game"

// The pickup feed: at the right of the screen, a line for what came into the inventory
// ("+3 iron ore", in its rarity's colour, with its icon), newest on top, each standing
// PICKUP_SECONDS on the feel clock and fading at the end; more of the same item soon after
// adds to its line. What came is what the inventory holds more of than the frame before
// (from the ground, a chest, a trade, a craft, the server's kit); the Creative tab's
// catalog is not news.

PICKUP_SECONDS :: 4.0
PICKUP_FADE :: 0.8
PICKUP_MERGE :: 2.0 // seconds: more of the newest line's item within this joins it
PICKUP_ROW :: 26
PICKUP_WIDTH :: 260

// pickup_tally: the inventory's items with their totals (its slots, the equipment, the
// cursor; not an open chest's).
pickup_tally :: proc(inv: ^game.Inventory) -> (tally: [engine.PICKUP_TALLY]game.Stack, n: int) {
	add :: proc(tally: ^[engine.PICKUP_TALLY]game.Stack, n: ^int, st: game.Stack) {
		if game.stack_empty(st) {return}
		for &x in tally[:n^] {
			if x.item == st.item {
				x.count += st.count
				return
			}
		}
		tally[n^] = {st.item, st.count, 0, 0}
		n^ += 1
	}
	for st in inv.slots {add(&tally, &n, st)}
	for st in inv.equipment {add(&tally, &n, st)}
	add(&tally, &n, inv.cursor)
	return
}

// pickup_note: the inventory as it is now: what it holds more of than when last noted
// goes into the feed (news: false the first time, and while the catalog hands items out).
pickup_note :: proc(s: ^engine.Session, news: bool) {
	h := &s.hud
	tally, n := pickup_tally(&s.inventory)
	if h.tallied && news {
		for now in tally[:n] {
			before := 0
			for x in h.tally[:h.tally_len] {if x.item == now.item {before = x.count}}
			if now.count > before {pickup_add(s, now.item, now.count - before)}
		}
	}
	h.tally, h.tally_len, h.tallied = tally, n, true
}

// pickup_add: a line for count of item, or more on the newest line when it is the same
// item and recent.
pickup_add :: proc(s: ^engine.Session, item: game.Item, count: int) {
	h := &s.hud
	now := engine.feel_now(s)
	if f := &h.feed[0];
	   f.count > 0 && f.item == item && engine.feel_age(s, f.born) < PICKUP_MERGE {
		f.count += count
		f.born = now
		return
	}
	copy(h.feed[1:], h.feed[:engine.PICKUP_LINES - 1])
	h.feed[0] = {item, count, now}
}

// pickup_feed: the feed's lines, after noting what came this frame.
pickup_feed :: proc(app: ^engine.App, ctx: ^ui.Context) {
	s := app.session
	catalog := menu.section_open(app, .Inventory) && app.inventory_view.tab == .Creative
	pickup_note(s, !catalog)
	t := &ctx.theme
	x := ctx.screen.x + ctx.screen.w - PICKUP_WIDTH - 2 * t.spacing
	y := ctx.screen.y + ctx.screen.h * 0.55
	small := t.font_size * 0.9
	for &f in s.hud.feed {
		if f.count == 0 {continue}
		age := engine.feel_age(s, f.born)
		if age >= PICKUP_SECONDS {
			f.count = 0
			continue
		}
		alpha := clamp((PICKUP_SECONDS - age) / PICKUP_FADE, 0, 1)
		faded := ctx.theme
		faded.opacity *= alpha
		ui.theme_scope(ctx, faded)
		text := engine.tr(.Hud_Pickup, f.count, menu.item_title(s.reg, f.item))
		w := ui.measure_text(ctx, text, small) + PICKUP_ROW + 2 * t.padding
		line := ui.Rect{x + PICKUP_WIDTH - w, y, w, PICKUP_ROW - 2}
		ui.fill_rect(ctx, line, t.hud_fill)
		if icon, ok := app.item_icons[f.item]; ok {
			ui.draw_icon(ctx, {line.x + 3, line.y + 2, line.h - 4, line.h - 4}, icon)
		}
		ink := menu.rarity_color(t, menu.item_rarity(s.reg, f.item))
		ui.draw_text(ctx, {line.x + PICKUP_ROW, line.y, w - PICKUP_ROW, line.h}, text, small, ink)
		y += PICKUP_ROW
	}
}
