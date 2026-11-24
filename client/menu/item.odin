package menu

import "core:fmt"
import "core:math"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"

// Items as every screen shows them: a slot holding a stack, an item's name in its rarity's
// colour, its tooltip (the name, a type line, its stats, its description, and how it
// compares with what is worn or held), and a pane, the titled part of a screen that holds
// slots or rows. The inventory, a chest, the HUD and a game's own screens (a crafting bench,
// a trader) draw items with these, so an item looks the same everywhere.

// INVENTORY_SLOT: a slot's size in a screen (the hotbar's is engine.SLOT_SIZE).
INVENTORY_SLOT :: ui.Vec2{44, 44}
TOOLTIP_WIDTH :: 300 // a tooltip's most width: its description wraps to it
PANE_HEADING :: 26 // a pane's title row

// item_title: an item's name as players read it ("rocket launcher"; a pack's without its
// namespace: "flint pick", not "sandbox:flint_pick").
item_title :: proc(reg: ^game.Registry, item: game.Item) -> string {
	id := game.item_name(reg, item)
	if at := strings.index_byte(id, ':'); at >= 0 {id = id[at + 1:]}
	name, _ := strings.replace_all(id, "_", " ", context.temp_allocator)
	return name
}

// item_rarity: an item's rarity (common for an item that names none, or no item).
item_rarity :: proc(reg: ^game.Registry, item: game.Item) -> game.Rarity {
	info, _ := game.item_info(reg, item)
	return info.rarity
}

// rarity_color: the theme's colour for a rarity (an item's name, its slot's frame).
rarity_color :: proc(t: ^ui.Theme, r: game.Rarity) -> ui.Color {return t.rarity[int(r)]}

@(rodata)
RARITY_TEXT := [game.Rarity]engine.Text {
	.Common    = .Rarity_Common,
	.Uncommon  = .Rarity_Uncommon,
	.Rare      = .Rarity_Rare,
	.Epic      = .Rarity_Epic,
	.Legendary = .Rarity_Legendary,
}

// stack_slot draws a slot holding stack: its icon (its name, if it has none), its count
// (more than one), its number key (key > 0), framed when selected, and an item rarer than
// common framed in its rarity's colour.
stack_slot :: proc(
	ctx: ^ui.Context,
	reg: ^game.Registry,
	icons: ^engine.Item_Icons,
	r: ui.Rect,
	stack: game.Stack,
	selected: bool,
	key := 0,
) {
	t := &ctx.theme
	ui.fill_rect(ctx, r, t.slot_fill) // (blending is linear: lighter than it reads)
	frame := t.text if selected else t.faint_border
	if rarity := item_rarity(reg, stack.item);
	   !selected && !game.stack_empty(stack) && rarity != .Common {
		frame = ui.with_alpha(rarity_color(t, rarity), 200)
	}
	ui.stroke_rect(ctx, r, 2 if selected else 1, frame)
	inner := ui.rect_shrink(r, 4)
	small := t.font_size * 0.75
	if game.stack_empty(stack) {
		if key > 0 {
			ui.draw_text(
				ctx,
				{inner.x, inner.y, inner.w, small},
				fmt.tprint(key),
				small,
				t.text_muted,
			)
		}
		return
	}
	if icon, ok := icons[stack.item]; ok {
		side := min(inner.w, inner.h)
		ui.draw_icon(ctx, ui.rect_center(inner, side, side), icon)
	} else {
		ui.push_clip_rect(ctx, inner)
		title := item_title(reg, stack.item)
		align := ui.Align.Center if ui.measure_text(ctx, title, small) <= inner.w else .Left
		ui.draw_text(ctx, inner, title, small, t.text, align)
		ui.pop_clip_rect(ctx)
	}
	if key > 0 {
		ui.draw_text(
			ctx,
			{inner.x + 1, inner.y + 1, inner.w, small},
			fmt.tprint(key),
			small,
			t.text_shadow,
		)
		ui.draw_text(ctx, {inner.x, inner.y, inner.w, small}, fmt.tprint(key), small, t.text_muted)
	}
	if stack.count > 1 {
		corner := ui.Rect{inner.x, inner.y + inner.h - small, inner.w, small}
		count := fmt.tprint(stack.count)
		ui.draw_text(
			ctx,
			{corner.x + 1, corner.y + 1, corner.w, corner.h},
			count,
			small,
			t.text_shadow,
			.Right,
		)
		ui.draw_text(ctx, corner, count, small, t.text, .Right)
	}
}

// pane: a titled part of a screen (the bag, the equipment, a chest's slots, a list): its
// frame and title; what is left inside for its content.
pane :: proc(ctx: ^ui.Context, r: ui.Rect, title: string) -> ui.Rect {
	t := &ctx.theme
	ui.fill_rect(ctx, r, t.list_fill)
	ui.stroke_rect(ctx, r, 1, t.faint_border)
	inner := ui.rect_shrink(r, t.padding / 2)
	head := ui.cut_top(&inner, PANE_HEADING)
	ui.draw_text(ctx, ui.rect_shrink(head, t.padding / 2), title, t.font_size, t.text_muted)
	return inner
}

// pane_size: how big a pane is round content w by h.
pane_size :: proc(t: ^ui.Theme, w, h: f32) -> ui.Vec2 {
	return {w + t.padding, h + t.padding + PANE_HEADING}
}

// item_type: the line under an item's name: what kind of thing it is.
item_type :: proc(reg: ^game.Registry, item: game.Item) -> engine.Text {
	info, _ := game.item_info(reg, item)
	switch {
	case info.weapon != nil:
		return .Item_Type_Weapon
	case info.gather.kind == .Pick:
		return .Item_Type_Pick
	case info.gather.kind == .Blade:
		return .Item_Type_Blade
	case info.consume != nil:
		return .Item_Type_Consumable
	case info.melee != nil:
		return .Item_Type_Melee
	case info.tool != nil || info.grapple != nil:
		return .Item_Type_Tool
	case info.equip != nil:
		switch info.equip.? {
		case .Head:
			return .Item_Type_Head
		case .Chest:
			return .Item_Type_Chest
		case .Legs:
			return .Item_Type_Legs
		case .Feet:
			return .Item_Type_Feet
		case .Offhand:
			return .Item_Type_Offhand
		case .Trinket_1, .Trinket_2:
			return .Item_Type_Trinket
		}
	case info.block != .Air && game.item_of_block(reg, info.block) == item:
		return .Item_Type_Block
	}
	return .Item_Type_Material
}

// Stat: a number a tooltip shows of an item, and compares.
Stat :: enum u8 {
	Damage, // a hit's (a shot's: every pellet)
	Fire_Rate, // shots a second
	Magazine,
	Range, // blocks
	Reach, // a melee weapon's, blocks
	Tier, // a tool's: the blocks it gathers (game.Gather_Info)
	Gather_Speed, // ... how many times as fast as hands
	Yield, // ... what it adds to an ore's or stone's drop
	Max_Health, // the modifiers': worn or held
	Speed, // percent
	Jump, // percent
	Air_Jumps,
	Defence, // percent of harm taken off
	Fall_Guard, // percent of a fall's harm taken off
}

Stats :: struct {
	value: [Stat]f32,
	has:   bit_set[Stat],
}

// item_stats: an item's numbers: a weapon's, then what wearing it changes.
item_stats :: proc(reg: ^game.Registry, item: game.Item) -> (st: Stats) {
	info, ok := game.item_info(reg, item)
	if !ok {return}
	put :: proc(st: ^Stats, s: Stat, v: f32) {
		st.value[s] += v
		st.has += {s}
	}
	if w, is := info.weapon.?; is {
		put(&st, .Damage, w.damage * f32(max(w.pellets, 1)))
		put(&st, .Fire_Rate, w.fire_rate)
		put(&st, .Magazine, f32(w.magazine))
		put(&st, .Range, w.range)
	}
	if m, is := info.melee.?; is {
		put(&st, .Damage, m.damage)
		put(&st, .Reach, m.reach)
	}
	if g := info.gather; g.tier > 0 || g.speed > 0 {
		put(&st, .Tier, f32(g.tier))
		put(&st, .Gather_Speed, max(g.speed, 1))
		if g.yield > 0 {put(&st, .Yield, f32(g.yield))}
	}
	for m in info.modifiers {
		if m.amount == 0 {continue}
		#partial switch m.kind {
		case .Max_Health:
			put(&st, .Max_Health, m.amount)
		case .Speed:
			put(&st, .Speed, m.amount * 100)
		case .Jump:
			put(&st, .Jump, m.amount * 100)
		case .Air_Jumps:
			put(&st, .Air_Jumps, m.amount)
		case .Defence:
			put(&st, .Defence, m.amount * 100)
		case .Fall_Guard:
			put(&st, .Fall_Guard, m.amount * 100)
		}
	}
	return
}

@(rodata)
STAT_TEXT := [Stat]engine.Text {
	.Damage       = .Stat_Damage,
	.Fire_Rate    = .Stat_Fire_Rate,
	.Magazine     = .Stat_Magazine,
	.Range        = .Stat_Range,
	.Reach        = .Stat_Reach,
	.Tier         = .Stat_Tier,
	.Gather_Speed = .Stat_Gather_Speed,
	.Yield        = .Stat_Yield,
	.Max_Health   = .Stat_Max_Health,
	.Speed        = .Stat_Speed,
	.Jump         = .Stat_Jump,
	.Air_Jumps    = .Stat_Air_Jumps,
	.Defence      = .Stat_Defence,
	.Fall_Guard   = .Stat_Fall_Guard,
}

// STAT_SIGNED: the stats that are changes (a modifier's, a tool's yield), written with their
// sign; STAT_PERCENT those that are percentages.
STAT_SIGNED :: bit_set[Stat]{.Yield, .Max_Health, .Speed, .Jump, .Air_Jumps, .Defence, .Fall_Guard}
STAT_PERCENT :: bit_set[Stat]{.Speed, .Jump, .Defence, .Fall_Guard}

// use_lines: what using an item up does (its `consume`): "Heals 4", "1 health a second for
// 10 s", "Harm -20% for 10 s".
use_lines :: proc(reg: ^game.Registry, item: game.Item) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	info, _ := game.item_info(reg, item)
	use, is := info.consume.?
	if !is {return lines[:]}
	if use.heal > 0 {append(&lines, engine.tr(.Use_Heal, number_text(use.heal)))}
	if use.seconds > 0 && use.regen > 0 {
		append(&lines, engine.tr(.Use_Regen, number_text(use.regen), number_text(use.seconds)))
	}
	if use.seconds > 0 && use.defence > 0 {
		append(
			&lines,
			engine.tr(.Use_Defence, number_text(use.defence * 100), number_text(use.seconds)),
		)
	}
	return lines[:]
}

// number_text: a number as a tooltip writes it: whole when it is, else one decimal; signed
// when asked.
number_text :: proc(v: f32, signed := false) -> string {
	whole := math.abs(v - math.round(v)) < 0.05
	if signed {return fmt.tprintf("%+.0f", v) if whole else fmt.tprintf("%+.1f", v)}
	return fmt.tprintf("%.0f", v) if whole else fmt.tprintf("%.1f", v)
}

// stat_line: "Damage 6", "Speed +10%".
stat_line :: proc(s: Stat, v: f32) -> string {
	return engine.tr(STAT_TEXT[s], number_text(v, s in STAT_SIGNED))
}

// ability_lines: what wearing an item grants or takes away ("Grants fly").
ability_lines :: proc(reg: ^game.Registry, item: game.Item) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	info, _ := game.item_info(reg, item)
	for m in info.modifiers {
		if m.kind != .Grant_Ability && m.kind != .Revoke_Ability {continue}
		at := int(m.amount)
		if at < 0 || at >= len(game.Ability) {continue}
		key := engine.Text.Stat_Grants if m.kind == .Grant_Ability else .Stat_Removes
		append(&lines, engine.tr(key, game.ability_name(game.Ability(at))))
	}
	return lines[:]
}

// item_lines: what a tooltip says of an item, as plain lines: its name, its type line, its
// stats, its description (none: none); with_tags adds its item tags.
item_lines :: proc(reg: ^game.Registry, item: game.Item, with_tags := false) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, item_title(reg, item))
	append(&lines, type_line(reg, item))
	st := item_stats(reg, item)
	for s in Stat {if s in st.has {append(&lines, stat_line(s, st.value[s]))}}
	append(&lines, ..ability_lines(reg, item))
	append(&lines, ..use_lines(reg, item))
	info, _ := game.item_info(reg, item)
	if info.description != "" {append(&lines, info.description)}
	if with_tags {
		tags := make([dynamic]string, context.temp_allocator)
		for tag, i in reg.item_tags {
			if game.registry_item_in_tag(reg, item, i32(i)) {append(&tags, tag.id)}
		}
		if len(tags) > 0 {
			append(
				&lines,
				engine.tr(.Item_Tags, strings.join(tags[:], ", ", context.temp_allocator)),
			)
		}
	}
	return lines[:]
}

// type_line: "Rare trinket".
type_line :: proc(reg: ^game.Registry, item: game.Item) -> string {
	return engine.tr(
		.Item_Type_Line,
		engine.tr(RARITY_TEXT[item_rarity(reg, item)]),
		engine.tr(item_type(reg, item)),
	)
}

// item_compared: what an item is compared with in its tooltip: the stack worn where it
// would go (a trinket: the first trinket slot that holds one), or for a weapon the one in
// hand; none when nothing is there, or it is the same stack (worn: true then).
item_compared :: proc(
	reg: ^game.Registry,
	inv: ^game.Inventory,
	slot: int,
) -> (
	with: game.Stack,
	worn: bool,
) {
	if slot < 0 || slot >= game.ALL_SLOTS {return}
	st := game.slot_at(inv, slot)^
	if game.stack_empty(st) {return}
	if slot >= game.EQUIP_BASE && slot < game.CHEST_BASE {return {}, true}
	info, _ := game.item_info(reg, st.item)
	if e, is := info.equip.?; is && e != .Offhand {
		if game.equip_trinket(e) {
			e = .Trinket_1 if !game.stack_empty(inv.equipment[.Trinket_1]) else .Trinket_2
		}
		return inv.equipment[e], false
	}
	if info.weapon != nil || info.melee != nil {
		if slot == inv.selected {return {}, true}
		held := game.inventory_held(inv)
		hinfo, _ := game.item_info(reg, held.item)
		if hinfo.weapon != nil || hinfo.melee != nil {return held, false}
	}
	return
}

// Tip_Line: a line of a tooltip, in its colour.
@(private = "file")
Tip_Line :: struct {
	text:  string,
	color: ui.Color,
	gap:   bool, // a little space above it
}

// item_tooltip: an item's tooltip by the pointer, or beside a slot (the pad's cursor), on
// the top layer on the panels' colour, opaque, framed in its rarity's colour: its
// name in its rarity's colour, its type line, its stats (beside each, how it differs from
// `compared`'s, green for better and red for worse), what it grants, its description,
// and "Compared with <item>" or "Equipped" (worn: it is the stack worn or held).
item_tooltip :: proc(
	ctx: ^ui.Context,
	reg: ^game.Registry,
	stack: game.Stack,
	compared: game.Stack = {},
	worn := false,
	beside: Maybe(ui.Rect) = nil,
) {
	if game.stack_empty(stack) {return}
	t := &ctx.theme
	item := stack.item
	inner_w := f32(TOOLTIP_WIDTH) - 2 * t.padding
	lines := make([dynamic]Tip_Line, context.temp_allocator)
	append(&lines, Tip_Line{item_title(reg, item), rarity_color(t, item_rarity(reg, item)), false})
	append(&lines, Tip_Line{type_line(reg, item), t.text_muted, false})
	st := item_stats(reg, item)
	comparing := !game.stack_empty(compared)
	other := item_stats(reg, compared.item) if comparing else {}
	first := true
	for s in Stat {
		if s not_in st.has && !(comparing && s in other.has) {continue}
		text := stat_line(s, st.value[s])
		color := t.text
		if comparing {
			d := st.value[s] - other.value[s]
			if math.abs(d) >= 0.05 {
				text = fmt.tprintf("%s  (%s)", text, number_text(d, true))
				color = t.gain if d > 0 else t.loss
			}
		}
		append(&lines, Tip_Line{text, color, first})
		first = false
	}
	for l in ability_lines(reg, item) {append(&lines, Tip_Line{l, t.text, false})}
	for l in use_lines(reg, item) {append(&lines, Tip_Line{l, t.text, false})}
	info, _ := game.item_info(reg, item)
	if info.description != "" {
		for part, i in ui.wrap_words(ctx, info.description, t.font_size, inner_w) {
			append(&lines, Tip_Line{part, t.text_muted, i == 0})
		}
	}
	if comparing {
		append(
			&lines,
			Tip_Line {
				engine.tr(.Item_Compared, item_title(reg, compared.item)),
				t.text_muted,
				true,
			},
		)
	} else if worn {
		append(&lines, Tip_Line{engine.tr(.Item_Equipped), t.text_muted, true})
	}

	line_h := t.font_size + 6
	w, h: f32
	for l in lines {
		w = max(w, ui.measure_text(ctx, l.text, t.font_size))
		h += line_h + (line_h / 3 if l.gap else 0)
	}
	w = min(w, inner_w) + 2 * t.padding
	h += 2 * t.padding - 4
	tip := ui.tooltip_rect(ctx.input.mouse, ctx.screen, w, h)
	if r, ok := beside.?; ok {
		tip = {r.x + r.w + 4, r.y + (r.h - h) / 2, w, h}
		if tip.x + w > ctx.screen.x + ctx.screen.w {tip.x = r.x - 4 - w}
		tip.y = clamp(tip.y, ctx.screen.y, max(ctx.screen.y + ctx.screen.h - h, ctx.screen.y))
	}
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	ui.push_clip_rect(ctx, ctx.screen)
	defer ui.pop_clip_rect(ctx)
	ui.fill_rect(ctx, tip, ui.with_alpha(t.background, 255)) // (opaque: nothing under it shows through)
	ui.stroke_rect(ctx, tip, 1, rarity_color(t, item_rarity(reg, item)))
	row := ui.rect_shrink(tip, t.padding)
	row.y -= 2
	for l in lines {
		if l.gap {ui.cut_top(&row, line_h / 3)}
		ui.draw_text(ctx, ui.cut_top(&row, line_h), l.text, t.font_size, l.color)
	}
}

// slot_tooltip: the tooltip of an inventory's slot (a chest's too), compared with what is
// worn or held.
slot_tooltip :: proc(
	ctx: ^ui.Context,
	reg: ^game.Registry,
	inv: ^game.Inventory,
	slot: int,
	beside: Maybe(ui.Rect) = nil,
) {
	if slot < 0 || slot >= game.ALL_SLOTS {return}
	with, worn := item_compared(reg, inv, slot)
	item_tooltip(ctx, reg, game.slot_at(inv, slot)^, with, worn, beside)
}
