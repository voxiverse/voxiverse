package overview

import "core:math"

import "client:engine"
import "client:ui"
import "common:game"

// Commanding from above: what a strategy game's client part (or a city builder's, a tower
// defence's) needs to pick many of its side's entities with the free pointer and keep them
// picked, all on the client (the server is told only the orders, as the game's requests):
//
//  - a click picks the entity of its side under the pointer (Shift: adds or takes it
//    away), a click on nothing clears; a double click picks every one of that kind on the
//    screen;
//  - a drag draws a box on the screen and picks every entity of its side inside it;
//  - control groups: the picked set kept under a number and picked again by it;
//  - rings: a mark on the ground under each one picked, a few lines each, so a hundred
//    cost a few hundred lines a frame.
//
// A Selection lives in the game's client state (the session's arena); entities the
// session no longer knows (dead, or out of sight) fall out of it each frame.

MAX_SELECTED :: 256 // entities picked at once
MAX_GROUPS :: 10 // control groups (0 to 9)
DOUBLE_CLICK :: 0.4 // seconds between the clicks of a double click

// Selection: the entities of its side a player has picked, its control groups, and the
// click or drag in progress.
Selection :: struct {
	ids:        [MAX_SELECTED]u32,
	count:      int,
	groups:     [MAX_GROUPS]Group,
	dragging:   bool, // a box is being drawn
	from:       [2]f32, // where it began, UI units
	last_click: f64, // when the last click picked one (session seconds)
	last_kind:  game.Kind_Id, // ... and its kind
}

Group :: struct {
	ids:   [MAX_SELECTED]u32,
	count: int,
}

// selected: the ids picked, in the order they were.
selected :: proc(sel: ^Selection) -> []u32 {return sel.ids[:sel.count]}

// is_selected: whether id is picked.
is_selected :: proc(sel: ^Selection, id: u32) -> bool {
	for x in sel.ids[:sel.count] {if x == id {return true}}
	return false
}

// selection_clear: nothing picked (the groups are kept).
selection_clear :: proc(sel: ^Selection) {sel.count = 0}

// selection_add: id picked (nothing when it is already, or the set is full).
selection_add :: proc(sel: ^Selection, id: u32) {
	if is_selected(sel, id) || sel.count >= MAX_SELECTED {return}
	sel.ids[sel.count] = id
	sel.count += 1
}

// selection_remove: id no longer picked.
selection_remove :: proc(sel: ^Selection, id: u32) {
	for i in 0 ..< sel.count {
		if sel.ids[i] != id {continue}
		copy(sel.ids[i:sel.count - 1], sel.ids[i + 1:sel.count])
		sel.count -= 1
		return
	}
}

// selection_prune: the entities the session no longer knows, or no longer of the side,
// fall out of the set and of every group.
selection_prune :: proc(sel: ^Selection, s: ^engine.Session, team: u8) {
	keep :: proc(s: ^engine.Session, ids: []u32, team: u8) -> int {
		n := 0
		for id in ids {
			if e, known := s.entities[id]; known && e.team == team {ids[n] = id; n += 1}
		}
		return n
	}
	sel.count = keep(s, sel.ids[:sel.count], team)
	for &g in sel.groups {g.count = keep(s, g.ids[:g.count], team)}
}

// group_keep: the picked set kept as group n.
group_keep :: proc(sel: ^Selection, n: int) {
	if n < 0 || n >= MAX_GROUPS {return}
	g := &sel.groups[n]
	g.count = copy(g.ids[:], sel.ids[:sel.count])
}

// group_pick: group n picked again (false: it is empty).
group_pick :: proc(sel: ^Selection, n: int) -> bool {
	if n < 0 || n >= MAX_GROUPS || sel.groups[n].count == 0 {return false}
	g := &sel.groups[n]
	sel.count = copy(sel.ids[:], g.ids[:g.count])
	return true
}

// on_screen: where an entity the session shows is on the screen (UI units), false when it
// is not shown or off the screen.
on_screen :: proc(s: ^engine.Session, ctx: ^ui.Context, id: u32) -> (at: [2]f32, ok: bool) {
	p := engine.entity_place(s, id) or_return
	at = engine.world_point(s, ctx, p + {0, 0.5, 0}) or_return
	r := ctx.screen
	return at, at.x >= r.x && at.y >= r.y && at.x < r.x + r.w && at.y < r.y + r.h
}

// selection_box: the rectangle being dragged (UI units), while one is.
selection_box :: proc(sel: ^Selection, ctx: ^ui.Context) -> (ui.Rect, bool) {
	if !sel.dragging {return {}, false}
	a, b := sel.from, ctx.input.mouse
	return {min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y)}, true
}

// selection_update: the free pointer's primary button picks this frame (the game's HUD
// calls it each frame, after drawing what takes clicks first: its panels): a click, a
// double click, a box. team: the player's side, whose entities alone are picked. True
// when the set changed.
selection_update :: proc(sel: ^Selection, s: ^engine.Session, ctx: ^ui.Context, team: u8) -> bool {
	selection_prune(sel, s, team)
	b := engine.pointer_tool(s).buttons[.Primary]
	shift := .Shift in ctx.input.modifiers
	if b.pressed {
		sel.dragging, sel.from = true, b.at / ctx.scale
	}
	if !b.released {
		if !b.down {sel.dragging = false}
		return false
	}
	box, boxed := selection_box(sel, ctx)
	sel.dragging = false
	if b.clicked || !boxed || box.w < 4 && box.h < 4 {
		e, known := s.entities[b.entity]
		mine := b.entity != 0 && known && e.team == team
		now := s.frame_seconds
		switch {
		case mine && now - sel.last_click < DOUBLE_CLICK && sel.last_kind == e.kind:
			// A double click: every one of its kind on the screen.
			if !shift {selection_clear(sel)}
			for id, other in s.entities {
				if other.team != team || other.kind != e.kind {continue}
				if _, shown := on_screen(s, ctx, id); shown {selection_add(sel, id)}
			}
		case mine && shift && is_selected(sel, b.entity):
			selection_remove(sel, b.entity)
		case mine:
			if !shift {selection_clear(sel)}
			selection_add(sel, b.entity)
		case !shift:
			selection_clear(sel)
		}
		if mine {sel.last_click, sel.last_kind = now, e.kind}
		return true
	}
	if !shift {selection_clear(sel)}
	for id, e in s.entities {
		if e.team != team {continue}
		at := on_screen(s, ctx, id) or_continue
		if at.x >= box.x && at.y >= box.y && at.x <= box.x + box.w && at.y <= box.y + box.h {
			selection_add(sel, id)
		}
	}
	return true
}

// selection_draw: the box being dragged, outlined on the HUD.
selection_draw :: proc(sel: ^Selection, ctx: ^ui.Context) {
	box, dragging := selection_box(sel, ctx)
	if !dragging {return}
	ui.stroke_rect(ctx, box, 1, ctx.theme.focus_ring)
}

RING_SIDES :: 8 // lines a ring is drawn with

// rings_draw: a ring on the ground under each picked entity (radius: blocks), coloured.
rings_draw :: proc(sel: ^Selection, s: ^engine.Session, radius: f64, color: [4]u8) {
	for id in sel.ids[:sel.count] {ring_draw(s, id, radius, color)}
}

// ring_draw: one entity's ring.
ring_draw :: proc(s: ^engine.Session, id: u32, radius: f64, color: [4]u8) {
	p, shown := engine.entity_place(s, id)
	if !shown {return}
	y := p.y + 0.06
	for i in 0 ..< RING_SIDES {
		a := f64(i) / RING_SIDES * math.TAU
		b := f64(i + 1) / RING_SIDES * math.TAU
		engine.world_line(
			s,
			{p.x + math.cos(a) * radius, y, p.z + math.sin(a) * radius},
			{p.x + math.cos(b) * radius, y, p.z + math.sin(b) * radius},
			color,
		)
	}
}

// SMALL_MARK: the side of the square marking a unit drawn too small to read, in UI units.
SMALL_MARK :: 7

// small_marks: a square of its team's colour (colors, by team) over every entity the
// session knows whose body is drawn shorter than min_pixels on the screen (a soldier
// at the overview's height), so the far ones read as units, not specks. Entities of a
// team past colors, and those with no health (a dropped stack, a node), are left alone.
small_marks :: proc(s: ^engine.Session, ctx: ^ui.Context, min_pixels: f32, colors: [][4]u8) {
	for id, &e in s.entities {
		if e.max_health == 0 || int(e.team) >= len(colors) || e.team == 0 {continue}
		feet := engine.entity_place(s, id) or_continue
		top := engine.entity_top(s, id) or_continue
		a := engine.world_point(s, ctx, feet) or_continue
		b := engine.world_point(s, ctx, top) or_continue
		if abs(a.y - b.y) >= min_pixels {continue}
		r := ui.Rect{b.x - SMALL_MARK / 2, b.y - SMALL_MARK / 2, SMALL_MARK, SMALL_MARK}
		ui.fill_rect(ctx, ui.rect_expand(r, 1), ctx.theme.meter_back)
		ui.fill_rect(ctx, r, ui.Color(colors[e.team]))
	}
}
