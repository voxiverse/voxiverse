package foundry_client

import "client:engine"
import "client:ui"
import "common:game"
import "games:foundry"

// The game's screen: a machine's panel (what it is doing, what it holds, its output taken
// and inputs put in, an assembler's recipe or a lab's research chosen) or the hand-crafting
// list (every hand recipe, those not researched yet greyed with what unlocks them).

PANEL_WIDTH :: 760

screen :: proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
	v := view(s)
	if top && engine.game_action_pressed(s, CRAFT_ACTION) && v.showing == .Craft && !v.opening {
		engine.game_screen_close(s)
		return
	}
	v.opening = false
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	switch v.showing {
	case .Panel:
		panel_draw(s, ctx)
	case .Craft:
		craft_draw(s, ctx)
	}
}

panel_draw :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	p := &v.panel
	t := &ctx.theme
	choices := choices_of(s, p)
	rows := f32(int(p.count) + len(choices) + 6)
	box := ui.rect_center(
		ctx.screen,
		PANEL_WIDTH,
		min(rows * (t.row_height + t.spacing) + 4 * t.padding + 48, ctx.screen.h),
	)
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * t.padding)
	ui.title(ctx, foundry.tr(.Panel_Title, foundry.kind_name(p.kind)), ui.cut_top(&area, 48))
	making := foundry.tr(.Panel_Nothing)
	if p.recipe != 0 && p.kind != .Lab && int(p.recipe) <= len(s.reg.recipes) {
		making = foundry.tr(
			.Panel_Making,
			item_label(s, s.reg.recipes[p.recipe - 1].output.item),
			p.progress,
			p.power,
		)
	}
	ui.label(ctx, making, ui.cut_top(&area, t.row_height))
	ui.label(
		ctx,
		foundry.state_name(p.state),
		ui.cut_top(&area, t.row_height),
		.Left,
		t.text_muted,
	)
	ui.label(ctx, foundry.tr(.Panel_Holds), ui.cut_top(&area, t.row_height), .Left, t.text_muted)
	for st in p.slots[:p.count] {
		text :=
			foundry.tr(.Panel_Empty) if game.stack_empty(st) else foundry.tr(.Label_Count, item_label(s, st.item), st.count)
		ui.label(ctx, text, ui.cut_top(&area, t.row_height))
	}
	if len(choices) > 0 {
		heading := foundry.tr(.Panel_Study) if p.kind == .Lab else foundry.tr(.Panel_Choose)
		ui.label(ctx, heading, ui.cut_top(&area, t.row_height), .Left, t.text_muted)
		for c in choices {
			r := ui.cut_top(&area, t.row_height)
			ui.push_id_int(ctx, int(c.value))
			if ui.button(ctx, c.text, r, disabled = !c.open) {
				choose := foundry.Choose{p.at, c.value}
				engine.game_request(s, &choose)
			}
			if c.chosen {ui.stroke_rect(ctx, ui.rect_shrink(r, 2), 2, t.focus_ring)}
			ui.pop_id(ctx)
		}
	}
	buttons := ui.cut_bottom(&area, t.row_height)
	third := buttons.w / 3
	if ui.button(ctx, foundry.tr(.Panel_Take), ui.cut_left(&buttons, third - t.spacing)) {
		take := foundry.Take{p.at}
		engine.game_request(s, &take)
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, foundry.tr(.Panel_Put), ui.cut_left(&buttons, third - t.spacing)) {
		put := foundry.Put{p.at}
		engine.game_request(s, &put)
	}
	ui.cut_left(&buttons, t.spacing)
	if ui.button(ctx, foundry.tr(.Panel_Close), buttons) {
		closing := foundry.Close{p.at}
		engine.game_request(s, &closing)
		engine.game_screen_close(s)
	}
}

Choice :: struct {
	text:   string,
	value:  u16,
	open:   bool,
	chosen: bool,
}

// choices_of: an assembler's recipes, or a lab's research, with what may be chosen.
choices_of :: proc(s: ^engine.Session, p: ^foundry.Panel) -> []Choice {
	out := make([dynamic]Choice, context.temp_allocator)
	studied := transmute(bit_set[foundry.Research])view(s).status.studied
	#partial switch p.kind {
	case .Assembler:
		for &r, i in s.reg.recipes {
			if r.machine != foundry.BY_ASSEMBLER {continue}
			append(
				&out,
				Choice {
					item_label(s, r.output.item),
					u16(i) + 1,
					foundry.recipe_open(r.id, studied),
					int(p.recipe) == i + 1,
				},
			)
		}
	case .Lab:
		for info, r in foundry.RESEARCH {
			open := r not_in studied && info.needs <= studied
			append(
				&out,
				Choice {
					info.name,
					u16(r) + 1,
					open,
					int(p.recipe) == int(r) + 1 && r not_in studied,
				},
			)
		}
	}
	return out[:]
}

craft_draw :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	t := &ctx.theme
	studied := transmute(bit_set[foundry.Research])view(s).status.studied
	hand := make([dynamic]int, context.temp_allocator)
	for r, i in s.reg.recipes {if r.machine == foundry.BY_HAND {append(&hand, i)}}
	box := ui.rect_center(
		ctx.screen,
		PANEL_WIDTH + 200,
		min(f32(len(hand) + 3) * (t.row_height + t.spacing / 2) + 48, ctx.screen.h),
	)
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * t.padding)
	ui.title(ctx, foundry.tr(.Craft_Title), ui.cut_top(&area, 40))
	for i in hand {
		r := &s.reg.recipes[i]
		row := ui.cut_top(&area, t.row_height)
		ui.cut_top(&area, t.spacing / 2)
		ui.push_id_int(ctx, i)
		open := foundry.recipe_open(r.id, studied)
		name := item_label(s, r.output.item)
		if r.output.count > 1 {name = foundry.tr(.Label_Count, name, r.output.count)}
		if ui.button(ctx, name, ui.cut_left(&row, 240), disabled = !open) {
			craft := foundry.Craft{u16(i)}
			engine.game_request(s, &craft)
		}
		needs, _, n := game.recipe_needs(r)
		parts := make([dynamic]string, context.temp_allocator)
		for k in 0 ..< n {append(&parts, foundry.tr(.Label_Count, item_label(s, needs[k].item), needs[k].count))}
		words := foundry.tr(.Craft_Needs, join(parts[:]))
		if lock, locked := foundry.recipe_locked(r.id); locked && !open {
			words = foundry.tr(.Craft_Locked, foundry.RESEARCH[lock].name)
		}
		ui.label(ctx, words, ui.rect_shrink(row, 2), .Left, t.text_muted if open else t.warning)
		ui.pop_id(ctx)
	}
	if ui.button(ctx, foundry.tr(.Panel_Close), ui.cut_bottom(&area, t.row_height)) {
		engine.game_screen_close(s)
	}
}

join :: proc(parts: []string) -> string {
	out := ""
	for p, i in parts {out = p if i == 0 else foundry.tr(.Joined, out, p)}
	return out
}
