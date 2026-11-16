package skirmish_client

import "core:fmt"
import "core:math"
import "core:mem/virtual"

import "client:engine"
import "client:overview"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:skirmish"

// Skirmish's client part (the game: games/skirmish): a free camera over the field (no body:
// the movement keys, the window's edges and the middle button pan it, the wheel zooms), the
// side's units and buildings picked with the pointer (client/overview: a click, a double
// click, a box, control groups on the digits with Ctrl to keep), and ordered: the right
// button on the ground moves them, on a foe attacks it, on a crystal outcrop or a grove sets
// workers to gather; the command panel's buttons (and their keys) attack-move, stop, put up a
// building where the pointer places its ghost, train at a building. The fog darkens the
// ground the side does not see; the minimap shows the field, the side's units and buildings
// and the foes it sees, and a press on it moves the camera there. Every order is a request
// its server part judges.

GAME :: engine.Game {
	info       = skirmish.INFO,
	kinds      = skirmish.KINDS,
	state      = View,
	camera     = camera,
	started    = started,
	ended      = ended,
	received   = received,
	hud        = hud,
	debug      = debug,
	scoreboard = scoreboard,
	keys       = KEYS,
	no_hotbar  = true, // (a commander is bodiless: its digits are the control groups)
}

SMALL_UNIT :: 16 // pixels: a unit drawn shorter than this gets its side's square

CAMERA :: engine.Game_Camera {
	kind     = .Free,
	distance = 26,
	near     = 12,
	far      = 80,
	angle    = 58,
}

// The game's keys: the control groups on the digits, the command panel's five slots.
SLOT_KEYS :: 10 // KEYS[SLOT_KEYS + i] is the panel's slot i
SLOTS :: 5
KEYS :: []engine.Game_Key {
	{"Group 0", .Num_0},
	{"Group 1", .Num_1},
	{"Group 2", .Num_2},
	{"Group 3", .Num_3},
	{"Group 4", .Num_4},
	{"Group 5", .Num_5},
	{"Group 6", .Num_6},
	{"Group 7", .Num_7},
	{"Group 8", .Num_8},
	{"Group 9", .Num_9},
	{"Command 1", .Z},
	{"Command 2", .X},
	{"Command 3", .V},
	{"Command 4", .B},
	{"Command 5", .N},
}

Tool :: enum u8 {
	Pick, // the pointer picks; the right button orders
	Place, // a building's ghost follows the pointer
	Attack, // the next left click attack-moves
}

MAX_KNOWN :: 512

Known_Building :: struct {
	id:     u32,
	record: skirmish.Building_Record,
}

Known_Unit :: struct {
	id:     u32,
	record: skirmish.Unit_Record,
}

View :: struct {
	match:     skirmish.Match,
	economy:   skirmish.Economy,
	sides:     [skirmish.MAX_SIDES + 1]skirmish.Side_Record, // by team
	names:     [skirmish.MAX_SIDES + 1][16]u8,
	buildings: [MAX_KNOWN]Known_Building,
	units:     [MAX_KNOWN]Known_Unit,
	nodes:     [64]u32, // the nodes known (ids)
	sel:       overview.Selection,
	fog:       overview.Fog,
	minimap:   overview.Minimap,
	templates: [skirmish.Building]game.Template,
	tool:      Tool,
	placing:   skirmish.Building,
	unit_kind: [skirmish.Unit]game.Kind_Id,
	orders:    int, // requests sent (tests)
	shots:     int,
	flash:     engine.Flash,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

camera :: proc(s: ^engine.Session) -> engine.Game_Camera {return CAMERA}

started :: proc(s: ^engine.Session) {
	v := view(s)
	arena := virtual.arena_allocator(&s.arena)
	lo, hi := [2]i32{0, 0}, [2]i32{skirmish.MAP - 1, skirmish.MAP - 1}
	top := i32(skirmish.GROUND + skirmish.HIGH + 6)
	_ = overview.fog_init(&v.fog, lo, hi, skirmish.GROUND - 1, top, arena)
	overview.minimap_init(&v.minimap, lo, hi, skirmish.GROUND - 1, top, 2, arena)
	for &t, b in v.templates {t = skirmish.building_template(b, arena)}
	for &k, u in v.unit_kind {k, _ = game.registry_kind(s.reg, skirmish.UNITS[u].kind)}
}

ended :: proc(s: ^engine.Session) {}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if m, ok := engine.game_value(s, r, skirmish.Match); ok && m != nil {
		if m.phase != v.match.phase && m.phase == .Playing {
			overview.selection_clear(&v.sel)
			v.sel.groups = {}
			for &e in v.fog.explored {e = false}
		}
		v.match = m^
	}
	if e, ok := engine.game_value(s, r, skirmish.Economy); ok && e != nil {v.economy = e^}
	if side, ok := engine.game_value(s, r, skirmish.Side_Record); ok {
		team := int(r.key.a)
		if team >= 1 && team <= skirmish.MAX_SIDES {
			if side == nil {
				v.sides[team] = {}
			} else {
				v.sides[team] = side^
				n := copy(v.names[team][:], side.name)
				v.sides[team].name = string(v.names[team][:n])
			}
		}
	}
	if b, ok := engine.game_value(s, r, skirmish.Building_Record); ok {
		known_put(v.buildings[:], u32(r.key.a), b)
	}
	if u, ok := engine.game_value(s, r, skirmish.Unit_Record); ok {
		known_put(v.units[:], u32(r.key.a), u)
	}
	if n, ok := engine.game_value(s, r, skirmish.Node_Record); ok {
		id := u32(r.key.a)
		for &slot in v.nodes {
			if n == nil && slot == id {slot = 0; break}
			if n != nil && slot == id {break}
			if n != nil && slot == 0 {slot = id; break}
		}
	}
	if shot, ok := engine.game_value(s, r, skirmish.Shot); ok && shot != nil {
		v.shots += 1
		streak(
			s,
			{f64(shot.from.x), f64(shot.from.y), f64(shot.from.z)},
			{f64(shot.to.x), f64(shot.to.y), f64(shot.to.z)},
		)
	}
}

// known_put: a record keyed by an entity kept, changed or forgotten (nil).
known_put :: proc(list: []$K, id: u32, value: ^$T) {
	free := -1
	for &k, i in list {
		if k.id == id {
			if value == nil {k = {}} else {k.record = value^}
			return
		}
		if k.id == 0 && free < 0 {free = i}
	}
	if value != nil && free >= 0 {list[free] = {id, value^}}
}

building_of :: proc(v: ^View, id: u32) -> ^skirmish.Building_Record {
	for &k in v.buildings {if k.id == id {return &k.record}}
	return nil
}

unit_of :: proc(v: ^View, id: u32) -> ^skirmish.Unit_Record {
	for &k in v.units {if k.id == id {return &k.record}}
	return nil
}

is_node :: proc(v: ^View, id: u32) -> bool {
	for n in v.nodes {if n == id && id != 0 {return true}}
	return false
}

STREAK_SECONDS :: 0.25

streak :: proc(s: ^engine.Session, from, to: [3]f64) {
	d := to - from
	n := clamp(int(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) / 0.35), 2, 40)
	for i in 0 ..< n {
		engine.puff_add(
			s,
			{
				position = from + d * (f64(i) + 0.5) / f64(n),
				life = STREAK_SECONDS,
				size = 0.06,
				color = {255, 230, 140, 255},
			},
		)
	}
}

// ---- orders ----

// selected_units: the picked ids that are units (the buildings among them aside).
selected_units :: proc(v: ^View) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for id in overview.selected(&v.sel) {if unit_of(v, id) != nil {append(&out, id)}}
	return out[:]
}

// selected_building: the first picked building (0: none).
selected_building :: proc(v: ^View) -> u32 {
	for id in overview.selected(&v.sel) {if building_of(v, id) != nil {return id}}
	return 0
}

// order: the units told, in requests of MAX_ORDER_IDS each.
order :: proc(
	s: ^engine.Session,
	units: []u32,
	kind: skirmish.Order_Kind,
	at: game.Block_Pos,
	target: u32 = 0,
	building := skirmish.Building.Barracks,
) {
	v := view(s)
	for i := 0; i < len(units); i += skirmish.MAX_ORDER_IDS {
		o := skirmish.Order {
			kind     = kind,
			target   = target,
			at       = {i16(at.x), i16(at.y), i16(at.z)},
			building = building,
		}
		part := units[i:min(i + skirmish.MAX_ORDER_IDS, len(units))]
		o.count = u8(copy(o.ids[:], part))
		engine.game_request(s, &o)
		v.orders += 1
	}
}

// pointed: the block a walker stands in over the ground under the pointer.
pointed :: proc(s: ^engine.Session) -> (game.Block_Pos, bool) {
	t := engine.pointer_tool(s)
	return t.ground + {0, 1, 0}, t.on_ground
}

// command: the right button's order on what it is over.
command :: proc(s: ^engine.Session, press: engine.Pointer_Press) {
	v := view(s)
	units := selected_units(v)
	at := press.from + {0, 1, 0}
	if len(units) == 0 {
		if b := selected_building(v); b != 0 {
			rally := skirmish.Rally{b, {i16(at.x), i16(at.z)}}
			engine.game_request(s, &rally)
			v.orders += 1
		}
		return
	}
	target := press.entity
	e, known := s.entities[target]
	switch {
	case target != 0 && known && e.team != 0 && e.team != v.economy.team:
		order(s, units, .Attack, at, target)
	case target != 0 && is_node(v, target):
		order(s, units, .Gather, at, target)
	case:
		order(s, units, .Move, at)
	}
}

// ---- the HUD ----

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	t := &ctx.theme
	team := v.economy.team
	rest := ctx.screen
	engine.top_bar(ctx, &rest, status(s))

	// The field: the fog, the picked units' rings, the health of the hurt, the ghost.
	overview.fog_update(&v.fog, s, team)
	overview.minimap_ground(&v.minimap, s)
	if team != 0 {overview.fog_draw(&v.fog, s, {0, 0, 0, 110}, {0, 0, 0, 200})}
	overview.rings_draw(&v.sel, s, 0.55, skirmish.TEAM_COLORS[team])
	engine.entity_bars(s, ctx)
	overview.small_marks(s, ctx, SMALL_UNIT, skirmish.TEAM_COLORS[:])

	// The panel along the bottom: the minimap, what is picked, the commands.
	panel := ui.cut_bottom(&rest, 180)
	ui.panel(ctx, panel)
	inner := ui.rect_shrink(panel, t.padding)
	mapr := ui.cut_left(&inner, inner.h)
	marks := minimap_marks(s)
	if at, pressed := overview.minimap_draw(
		&v.minimap,
		s,
		ctx,
		mapr,
		&v.fog if team != 0 else nil,
		marks,
		{0, 0, 0, 110},
		{0, 0, 0, 220},
	); pressed {
		overview.minimap_jump(s, at, f64(skirmish.GROUND + skirmish.HIGH + 2))
	}
	ui.cut_left(&inner, t.padding)
	slots := ui.cut_right(&inner, 5 * 88)
	picked(s, ctx, inner)
	commands(s, ctx, slots)
	hint := ui.cut_bottom(&rest, t.row_height)
	ui.draw_text(ctx, hint, hint_text(v), t.font_size * 0.8, t.text_muted, .Center)

	// The pointer: groups, picks, orders.
	if v.match.phase == .Playing && team != 0 && !v.economy.lost {
		groups(s, ctx)
		pointer(s, ctx)
	}
	overview.selection_draw(&v.sel, ctx)
	results(s, ctx)
}

status :: proc(s: ^engine.Session) -> string {
	v := view(s)
	m := v.match
	clock := fmt.tprintf("%d:%02d", m.seconds / 60, m.seconds % 60)
	switch m.phase {
	case .Waiting:
		return skirmish.tr(.Status_Waiting)
	case .Playing:
		e := v.economy
		if e.team == 0 {return skirmish.tr(.Status_Watching, clock)}
		return skirmish.tr(
			.Status_Playing,
			e.stock[.Ore],
			e.stock[.Wood],
			e.supply,
			e.supply_cap,
			clock,
		)
	case .Results:
		return skirmish.tr(.Status_Results, m.seconds)
	}
	return ""
}

hint_text :: proc(v: ^View) -> string {
	switch v.tool {
	case .Place:
		return skirmish.tr(.Hint_Place, skirmish.tr(skirmish.BUILDINGS[v.placing].name))
	case .Attack:
		return skirmish.tr(.Hint_Attack_Move)
	case .Pick:
	}
	return skirmish.tr(.Hint_Commands)
}

// minimap_marks: a dot for each unit and building the session knows (its side's colour),
// larger for buildings, and the nodes in their resource's.
minimap_marks :: proc(s: ^engine.Session) -> []overview.Mark {
	v := view(s)
	out := make([dynamic]overview.Mark, context.temp_allocator)
	for id, e in s.entities {
		p := engine.entity_place(s, id) or_continue
		switch {
		case building_of(v, id) != nil:
			append(&out, overview.Mark{{p.x, p.z}, skirmish.TEAM_COLORS[e.team], 6})
		case is_node(v, id):
			append(&out, overview.Mark{{p.x, p.z}, {140, 120, 230, 255}, 3})
		case e.team != 0:
			append(&out, overview.Mark{{p.x, p.z}, skirmish.TEAM_COLORS[e.team], 3})
		}
	}
	return out[:]
}

// picked: what is picked, in words.
picked :: proc(s: ^engine.Session, ctx: ^ui.Context, r: ui.Rect) {
	v := view(s)
	t := &ctx.theme
	area := r
	units := selected_units(v)
	line :: proc(ctx: ^ui.Context, area: ^ui.Rect, text: string) {
		ui.draw_text(
			ctx,
			ui.cut_top(area, ctx.theme.row_height),
			text,
			ctx.theme.font_size,
			ctx.theme.text,
			.Left,
		)
	}
	switch {
	case len(units) == 1:
		e := s.entities[units[0]]
		u := unit_of(v, units[0])
		line(
			ctx,
			&area,
			skirmish.tr(
				.Selected_One,
				skirmish.tr(skirmish.UNITS[u.unit].name),
				e.health,
				e.max_health,
			),
		)
		if u.carrying > 0 {
			line(
				ctx,
				&area,
				skirmish.tr(
					.Carrying,
					u.carrying,
					skirmish.tr(.Resource_Ore if u.resource == .Ore else .Resource_Wood),
				),
			)
		}
	case len(units) > 1:
		line(ctx, &area, skirmish.tr(.Selected_Units, len(units)))
		counts: [skirmish.Unit]int
		for id in units {counts[unit_of(v, id).unit] += 1}
		for n, u in counts {
			if n >
			   0 {line(ctx, &area, fmt.tprintf("%d  %s", n, skirmish.tr(skirmish.UNITS[u].name)))}
		}
	case selected_building(v) != 0:
		id := selected_building(v)
		b := building_of(v, id)
		e := s.entities[id]
		name := skirmish.tr(skirmish.BUILDINGS[b.building].name)
		if b.built < 100 {
			line(ctx, &area, skirmish.tr(.Building_Progress, name, b.built))
		} else {
			line(ctx, &area, skirmish.tr(.Selected_One, name, e.health, e.max_health))
		}
		if b.queued > 0 {
			line(
				ctx,
				&area,
				skirmish.tr(
					.Training,
					skirmish.tr(skirmish.UNITS[b.queue[0]].name),
					b.training,
					b.queued - 1,
				),
			)
		}
	}
	_ = t
}

// Slot: one of the command panel's buttons.
Slot :: struct {
	label: string,
	cost:  string, // its cost; what it lacks when it is off (said in the warning colour)
	act:   proc(s: ^engine.Session, arg: int),
	arg:   int,
	off:   bool,
}

// short_text: what a side's stock lacks of a cost ("" when it has it all).
short_text :: proc(stock, cost: skirmish.Cost) -> string {
	ore := max(int(cost[.Ore]) - int(stock[.Ore]), 0)
	wood := max(int(cost[.Wood]) - int(stock[.Wood]), 0)
	switch {
	case ore > 0 && wood > 0:
		return skirmish.tr(.Short_Both, ore, wood)
	case ore > 0:
		return skirmish.tr(.Short_Ore, ore)
	case wood > 0:
		return skirmish.tr(.Short_Wood, wood)
	}
	return ""
}

// commands: the panel's buttons for what is picked, each with its key.
commands :: proc(s: ^engine.Session, ctx: ^ui.Context, r: ui.Rect) {
	v := view(s)
	slots: [SLOTS]Slot
	units := selected_units(v)
	workers := false
	for id in units {if unit_of(v, id).unit == .Worker {workers = true}}
	stock := skirmish.Cost {
		.Ore  = int(v.economy.stock[.Ore]),
		.Wood = int(v.economy.stock[.Wood]),
	}
	switch {
	case workers:
		for b, i in ([4]skirmish.Building{.Barracks, .Workshop, .Tower, .Depot}) {
			info := skirmish.BUILDINGS[b]
			short := short_text(stock, info.cost)
			slots[i] = {
				skirmish.tr(info.name),
				short if short != "" else cost_text(info.cost),
				place,
				int(b),
				short != "",
			}
		}
		slots[4] = {skirmish.tr(.Command_Stop), "", stop, 0, false}
	case len(units) > 0:
		slots[0] = {skirmish.tr(.Command_Attack_Move), "", attack_tool, 0, false}
		slots[1] = {skirmish.tr(.Command_Stop), "", stop, 0, false}
	case selected_building(v) != 0:
		b := building_of(v, selected_building(v))
		i := 0
		for u in skirmish.Unit {
			if u not_in skirmish.BUILDINGS[b.building].trains {continue}
			info := skirmish.UNITS[u]
			short := short_text(stock, info.cost)
			why := skirmish.tr(.Unbuilt) if b.built < 100 else short
			slots[i] = {
				skirmish.tr(info.name),
				why if why != "" else cost_text(info.cost),
				train,
				int(u),
				why != "",
			}
			i += 1
		}
	}
	w := r.w / SLOTS
	for slot, i in slots {
		if slot.act == nil {continue}
		cell := ui.Rect{r.x + f32(i) * w, r.y, w - 6, r.h - 24}
		key := engine.game_key_label(s, SLOT_KEYS + i)
		clicked := ui.button(ctx, "", cell, disabled = slot.off, id = fmt.tprintf("slot %d", i))
		// (its name in the middle, its cost under it, its key in the corner)
		t := &ctx.theme
		color := t.text_muted if slot.off else t.text
		size := t.font_size * 0.85
		mid := ui.Rect{cell.x, cell.y + cell.h / 2 - t.row_height, cell.w, t.row_height}
		ui.draw_text(ctx, mid, slot.label, size, color, .Center)
		ui.draw_text(
			ctx,
			{mid.x, mid.y + t.row_height, mid.w, mid.h},
			slot.cost,
			size,
			t.warning if slot.off else t.text_muted,
			.Center,
		)
		ui.draw_text(
			ctx,
			{cell.x + 6, cell.y + 4, cell.w - 12, t.row_height},
			key,
			size,
			t.focus_ring,
			.Left,
		)
		if (clicked || engine.game_key_pressed(s, SLOT_KEYS + i)) &&
		   !slot.off {slot.act(s, slot.arg)}
	}
}

cost_text :: proc(c: skirmish.Cost) -> string {
	switch {
	case c[.Wood] == 0:
		return skirmish.tr(.Cost_Ore, c[.Ore])
	case c[.Ore] == 0:
		return skirmish.tr(.Cost_Wood, c[.Wood])
	}
	return skirmish.tr(.Cost_Both, c[.Ore], c[.Wood])
}

place :: proc(s: ^engine.Session, arg: int) {
	v := view(s)
	v.tool, v.placing = .Place, skirmish.Building(arg)
}

attack_tool :: proc(s: ^engine.Session, arg: int) {view(s).tool = .Attack}

stop :: proc(s: ^engine.Session, arg: int) {
	v := view(s)
	order(s, selected_units(v), .Stop, {})
	v.tool = .Pick
}

train :: proc(s: ^engine.Session, arg: int) {
	v := view(s)
	t := skirmish.Train{selected_building(v), skirmish.Unit(arg)}
	engine.game_request(s, &t)
	v.orders += 1
}

// groups: a digit picks its group; Ctrl and a digit keeps the picked set under it.
groups :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	for n in 0 ..< overview.MAX_GROUPS {
		if !engine.game_key_pressed(s, n) {continue}
		if .Ctrl in ctx.input.modifiers {
			overview.group_keep(&v.sel, n)
		} else {
			overview.group_pick(&v.sel, n)
		}
	}
}

// pointer: what the pointer does on the field with the tool in hand.
pointer :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	tool := engine.pointer_tool(s)
	primary, secondary := tool.buttons[.Primary], tool.buttons[.Secondary]
	switch v.tool {
	case .Place:
		at, on := pointed(s)
		if !on {return}
		corner := skirmish.building_corner(v.placing, {at.x, at.z})
		color := [4]u8{90, 230, 110, 140}
		if !skirmish.can_afford(
			skirmish.Cost{.Ore = int(v.economy.stock[.Ore]), .Wood = int(v.economy.stock[.Wood])},
			skirmish.BUILDINGS[v.placing].cost,
		) {
			color = {240, 70, 60, 140}
		}
		engine.structure_ghost(s, &v.templates[v.placing], {corner.x, at.y, corner.y}, 0, color)
		if primary.clicked {
			order(s, selected_units(v), .Build, at, 0, v.placing)
			v.tool = .Pick
		}
		if secondary.clicked {v.tool = .Pick}
	case .Attack:
		if primary.clicked {
			units := selected_units(v)
			e, known := s.entities[primary.entity]
			if primary.entity != 0 && known && e.team != 0 && e.team != v.economy.team {
				order(s, units, .Attack, primary.from + {0, 1, 0}, primary.entity)
			} else {
				order(s, units, .Attack_Move, primary.from + {0, 1, 0})
			}
			v.tool = .Pick
		}
		if secondary.clicked {v.tool = .Pick}
	case .Pick:
		overview.selection_update(&v.sel, s, ctx, v.economy.team)
		if secondary.clicked {command(s, secondary)}
	}
}

// results: the match's end, over the field.
results :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	t := &ctx.theme
	m := v.match
	if m.phase != .Results {
		engine.flash_draw(ctx, &v.flash, s, -160)
		return
	}
	head, color := skirmish.tr(.Draw), t.log_warn
	switch {
	case m.winner != 0 && m.winner == v.economy.team:
		head, color = skirmish.tr(.Won), t.success
	case v.economy.team != 0:
		head = skirmish.tr(.Lost)
	case m.winner != 0:
		head = skirmish.tr(.Side_Wins, v.sides[m.winner].name)
	}
	engine.banner(ctx, -160, head, 1.5, color)
	engine.banner(ctx, -60, skirmish.tr(.Next_Match, m.seconds), 0.6, t.text)
}

// scoreboard: every side of the match: its units, buildings, kills and its player's wins.
scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	m := v.match
	board.title = skirmish.tr(
		.Board_Title,
		m.match,
		fmt.tprintf("%d:%02d", m.seconds / 60, m.seconds % 60),
	)
	engine.scoreboard_columns(
		board,
		skirmish.tr(.Column_Units),
		skirmish.tr(.Column_Buildings),
		skirmish.tr(.Column_Killed),
		skirmish.tr(.Column_Wins),
	)
	for side, team in v.sides {
		if side.team == 0 {continue}
		engine.scoreboard_row(
			board,
			side.name,
			fmt.tprint(side.units),
			fmt.tprint(side.built),
			fmt.tprint(side.killed),
			fmt.tprint(side.wins),
			you = u8(team) == v.economy.team,
		)
	}
}

debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	return fmt.tprintf(
		"match %d %v team %d picked %d tool %v orders %d shots %d",
		v.match.match,
		v.match.phase,
		v.economy.team,
		len(overview.selected(&v.sel)),
		v.tool,
		v.orders,
		v.shots,
	)
}
