package sandbox_client

import "core:fmt"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "games:sandbox"

// The crafting screen (README.md, "Gathering, crafting and outposts"): the game's action
// Craft opens it anywhere and closes it again. Every recipe of the sandbox's, by hand or at
// a fabricator, with what it makes, what it takes against what the player carries and how
// long; those it can make now first. A recipe picked and Make asks the server
// (sandbox.Craft), which judges and makes it in its time. Beside them: whether a
// fabricator is in reach, what is being made, and the world's outposts. Plain text and the
// UI kit's list, so a shared slot or tooltip helper can take its rows' place.

CRAFT_WIDTH :: 1060
CRAFT_TITLE :: 60
CRAFT_ROW :: 52 // a recipe's row: what it makes over what it takes
CRAFT_SIDE :: 0.36 // of the width: the side with the status and the outposts

// Craft_Screen: what the server last showed and what the screen has picked.
Craft_Screen :: struct {
	shown: sandbox.Survival,
	list:  ui.Scroll_List,
	pick:  int, // the recipe picked: its index in the registry's recipes + 1 (0: none)
}

// craft_recipes: the sandbox's recipes, those the player can make where it stands first,
// then the rest, each in the pack's order.
craft_recipes :: proc(s: ^engine.Session, allocator := context.temp_allocator) -> []int {
	shown := &view(s).craft.shown
	ready := make([dynamic]int, allocator)
	rest := make([dynamic]int, allocator)
	for &r, i in s.reg.recipes {
		station, ours := sandbox.recipe_station(&r)
		if !ours {continue}
		reach := station == .Hand || shown.near_fabricator
		if reach &&
		   sandbox.can_make(s.reg, &r, &s.inventory) {append(&ready, i)} else {append(&rest, i)}
	}
	append(&ready, ..rest[:])
	return ready[:]
}

// craft_inputs: what a recipe takes, each "item carried/needed", joined.
craft_inputs :: proc(s: ^engine.Session, r: ^game.Recipe_Def) -> string {
	needs, tags, n := game.recipe_needs(r)
	parts := make([dynamic]string, context.temp_allocator)
	for k in 0 ..< n {
		have := sandbox.carried(s.reg, &s.inventory, needs[k].item, tags[k])
		name :=
			sandbox.item_label(s.reg, needs[k].item) if tags[k] == game.NO_TAG else s.reg.item_tags[tags[k]].id
		append(&parts, sandbox.tr(.Craft_Input, name, have, needs[k].count))
	}
	return strings.join(parts[:], "   ", context.temp_allocator)
}

// craft_hud: the Craft action opens the screen; what is being made, a line under the top
// while the screen is closed.
craft_hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	if engine.game_screen_shown(s) {return}
	if engine.game_action_pressed(s, sandbox.CRAFT_ACTION) {
		craft_open(s)
		return
	}
	shown := &view(s).craft.shown
	if shown.making == 0 || int(shown.making) > len(s.reg.recipes) {return}
	t := &ctx.theme
	r := &s.reg.recipes[shown.making - 1]
	line := ui.Rect {
		ctx.screen.x,
		ctx.screen.y + 3 * t.spacing + t.row_height,
		ctx.screen.w,
		t.row_height,
	}
	made := sandbox.item_label(s.reg, r.output.item)
	ui.label(ctx, sandbox.tr(.Craft_Hud, made, shown.progress), line, .Center, t.text_muted)
}

// craft_open: the crafting screen opened.
craft_open :: proc(s: ^engine.Session) {
	view(s).screen = .Craft
	engine.game_screen_open(s)
}

// craft_screen: the crafting screen (one of the game's screens).
craft_screen :: proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
	v := &view(s).craft
	if top && engine.game_action_pressed(s, sandbox.CRAFT_ACTION) { 	// (the key that opened it)
		engine.game_screen_close(s)
		return
	}
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, min(CRAFT_WIDTH, ctx.screen.w), ctx.screen.h - 4 * t.padding)
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * t.padding)
	ui.title(ctx, sandbox.tr(.Craft_Title), ui.cut_top(&area, CRAFT_TITLE))
	side := ui.cut_right(&area, CRAFT_SIDE * area.w)
	ui.cut_right(&area, 2 * t.spacing)

	// The recipes.
	recipes := craft_recipes(s)
	if v.pick == 0 && len(recipes) > 0 {v.pick = recipes[0] + 1}
	view_ := ui.list_begin(ctx, "recipes", area, len(recipes), CRAFT_ROW, &v.list)
	small := t.font_size * 0.8
	for i in view_.first ..< view_.last {
		at := recipes[i]
		r := &s.reg.recipes[at]
		station, _ := sandbox.recipe_station(r)
		reach := station == .Hand || v.shown.near_fabricator
		makes := reach && sandbox.can_make(s.reg, r, &s.inventory)
		out := sandbox.tr(.Craft_Output, r.output.count, sandbox.item_label(s.reg, r.output.item))
		row, it := ui.list_row(ctx, &view_, i, out)
		if it.clicked {v.pick = at + 1}
		if v.pick == at + 1 {ui.fill_rect(ctx, row, t.slot_fill)}
		inner := ui.rect_shrink(row, 6)
		top_line := ui.cut_top(&inner, t.font_size + 6)
		place := sandbox.tr(.Craft_Hand if station == .Hand else .Craft_Fabricator)
		info := fmt.tprintf("%s   %s", place, sandbox.tr(.Craft_Seconds, r.time))
		ui.draw_text(ctx, top_line, info, small, t.text_muted, .Right)
		ui.draw_text(ctx, top_line, out, t.font_size, t.text if makes else t.text_muted, .Left)
		ui.draw_text(
			ctx,
			inner,
			craft_inputs(s, r),
			small,
			t.text if makes else t.text_muted,
			.Left,
		)
	}
	if ui.list_end(ctx, &view_) && v.list.selected >= 0 && v.list.selected < len(recipes) {
		v.pick = recipes[v.list.selected] + 1
	}

	// The side: where, what is being made, Make, the outposts and Close.
	close := ui.cut_bottom(&side, t.row_height)
	ui.cut_bottom(&side, t.spacing)
	near := sandbox.tr(.Craft_Near if v.shown.near_fabricator else .Craft_Far)
	ui.label(
		ctx,
		near,
		ui.cut_top(&side, t.row_height),
		.Left,
		t.text if v.shown.near_fabricator else t.text_muted,
	)
	busy := v.shown.making != 0 && int(v.shown.making) <= len(s.reg.recipes)
	status := sandbox.tr(.Craft_Idle)
	if busy {
		made := s.reg.recipes[v.shown.making - 1].output.item
		status = sandbox.tr(.Craft_Making, sandbox.item_label(s.reg, made), v.shown.progress)
	}
	ui.label(ctx, status, ui.cut_top(&side, t.row_height), .Left, t.text_muted)
	ui.cut_top(&side, t.spacing)
	can := false
	if v.pick > 0 && v.pick <= len(s.reg.recipes) {
		r := &s.reg.recipes[v.pick - 1]
		station, _ := sandbox.recipe_station(r)
		can =
			!busy &&
			(station == .Hand || v.shown.near_fabricator) &&
			sandbox.can_make(s.reg, r, &s.inventory)
		label := sandbox.tr(
			.Craft_Output,
			r.output.count,
			sandbox.item_label(s.reg, r.output.item),
		)
		ui.label(ctx, label, ui.cut_top(&side, t.row_height), .Left)
		info, _ := game.item_info(s.reg, r.output.item)
		if info.description != "" {
			ui.draw_text(
				ctx,
				ui.cut_top(&side, t.row_height),
				info.description,
				small,
				t.text_muted,
				.Left,
			)
		}
	}
	make_at := ui.cut_top(&side, t.row_height)
	if ui.button(ctx, sandbox.tr(.Craft_Make), make_at, disabled = !can) {
		ask := sandbox.Craft{u16(v.pick - 1)}
		engine.game_request(s, &ask)
	}
	ui.cut_top(&side, 2 * t.spacing)
	ui.label(ctx, sandbox.tr(.Craft_Outposts), ui.cut_top(&side, t.row_height), .Left)
	if v.shown.count == 0 {
		ui.label(
			ctx,
			sandbox.tr(.Craft_No_Outposts),
			ui.cut_top(&side, t.row_height),
			.Left,
			t.text_muted,
		)
	}
	for o in v.shown.outposts[:min(int(v.shown.count), len(v.shown.outposts))] {
		if side.h < t.row_height {break}
		line := ui.cut_top(&side, t.row_height)
		marks := make([dynamic]string, context.temp_allocator)
		if o.mine {append(&marks, sandbox.tr(.Craft_Outpost_Mine))}
		if o.home {append(&marks, sandbox.tr(.Craft_Outpost_Home))}
		ui.label(ctx, sandbox.tr(.Craft_Outpost, o.at.x, o.at.y, o.at.z), line, .Left)
		ui.label(
			ctx,
			strings.join(marks[:], ", ", context.temp_allocator),
			line,
			.Right,
			t.text_muted,
		)
	}
	if ui.button(ctx, sandbox.tr(.Craft_Close), close) {engine.game_screen_close(s)}
}
