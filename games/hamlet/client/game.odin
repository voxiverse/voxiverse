package hamlet_client

import "core:fmt"
import "core:strconv"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:hamlet"

// Hamlet's client part (the game: games/hamlet): a free camera over the village (no
// body: the movement keys, the window's edges and the middle button pan it, the wheel
// zooms, F5 and Shift with the wheel turn it), a toolbar of tools and speeds, the
// town's line at the top, and the tools on the ground: a road dragged as an L, a zone
// dragged as a rectangle, a building's ghost at the pointer (the right button turns
// it; green where it may go, red where not), demolition. An overlay shows the roads'
// reach or how happy each house is. Every change is a request its server part judges.

GAME :: engine.Game {
	info      = hamlet.INFO,
	kinds     = hamlet.KINDS,
	state     = View,
	camera    = camera,
	started   = started,
	ended     = ended,
	received  = received,
	hud       = hud,
	debug     = debug,
	no_hotbar = true, // (the planner is bodiless: nothing in hand)
	commands  = {
		{
			"hamlet",
			"hamlet tool <look|road|zone|woodcutter|quarry|farm|storehouse|well|market|demolish> [x z [x2 z2]] | overlay <none|roads|happiness> | camera <distance> <degrees>: the tool in hand (with tiles: held there, as if dragged from the first to the second: a picture aid), the overlay, the camera",
			command,
		},
	},
}

CAMERA :: engine.Game_Camera {
	kind     = .Free,
	distance = 44,
	near     = 12,
	far      = 110,
	angle    = 62,
	heading  = 0,
}

Tool :: enum u8 {
	Look,
	Road,
	Zone,
	Build,
	Demolish,
}

Overlay :: enum u8 {
	None,
	Access, // the roads' reach
	Happiness,
}

MILESTONE_SECONDS :: 4.0

View :: struct {
	town:       hamlet.Town,
	tiles:      hamlet.Tiles,
	happy:      [hamlet.MAP][hamlet.MAP]u8,
	ground:     hamlet.Ground, // from the town's seed, as the server made it
	seed_known: bool,
	structures: [hamlet.MAX_STRUCTURES]hamlet.Structure_Record,
	present:    [hamlet.MAX_STRUCTURES]bool,
	templates:  [hamlet.Kind]game.Template,
	shaped:     bool,
	tool:       Tool,
	kind:       hamlet.Kind,
	rotation:   u8,
	overlay:    Overlay,
	flash:      engine.Flash, // a milestone reached
	requests:   int, // sent (tests)
	pinned:     bool, // the tool held at pin_from .. pin_to (`hamlet tool ... x z`: a picture aid)
	pin_from:   [2]i32,
	pin_to:     [2]i32,
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

camera :: proc(s: ^engine.Session) -> engine.Game_Camera {return CAMERA}

started :: proc(s: ^engine.Session) {
	v := view(s)
	v.shaped = true
	for &t, k in v.templates {
		ok: bool
		t, ok = hamlet.template_shape(s.reg, k)
		v.shaped &&= ok
	}
}

ended :: proc(s: ^engine.Session) {
	v := view(s)
	for &t in v.templates {delete(t.cells)}
}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if town, ok := engine.game_value(s, r, hamlet.Town); ok && town != nil {
		v.town = town^
		if !v.seed_known {
			hamlet.ground_make(&v.ground, town.seed)
			v.seed_known = true
		}
	}
	if row, ok := engine.game_value(s, r, hamlet.Row); ok && r.key.a >= 0 && r.key.a < hamlet.MAP {
		if row != nil {
			v.tiles[r.key.a] = row.tiles
			v.happy[r.key.a] = row.happy
		}
	}
	if st, ok := engine.game_value(s, r, hamlet.Structure_Record);
	   ok && r.key.a >= 0 && r.key.a < hamlet.MAX_STRUCTURES {
		v.present[r.key.a] = st != nil
		if st != nil {v.structures[r.key.a] = st^}
	}
	if m, ok := engine.game_value(s, r, hamlet.Milestone); ok && m != nil {
		text := hamlet.tr(.Milestone, m.population)
		engine.flash(&view(s).flash, s, text, .Good, MILESTONE_SECONDS)
	}
}

// send: a request to the server part, counted.
send :: proc(s: ^engine.Session, value: ^$T) {
	engine.game_request(s, value)
	view(s).requests += 1
}

// Colours of the marks on the ground (artwork: the game's own).
GOOD :: [4]u8{90, 230, 110, 110}
BAD :: [4]u8{240, 70, 60, 120}
ROAD :: [4]u8{200, 200, 190, 120}
ZONE :: [4]u8{120, 220, 120, 70}
OUTLINE :: [4]u8{255, 255, 255, 255}

tile_of :: proc(p: game.Block_Pos) -> [2]i32 {return {p.x, p.z}}

block_of :: proc(v: ^View, p: [2]i32) -> game.Block_Pos {
	return {p.x, hamlet.ground_top(&v.ground, p.x, p.y), p.y}
}

// tools: what the pointer does on the ground with the tool in hand, and the marks it
// leaves this frame.
tools :: proc(s: ^engine.Session) {
	v := view(s)
	p := engine.pointer_tool(s)
	if v.pinned {
		// (held where the command put it: drawn as a drag in progress, nothing sent)
		pinned := engine.Pointer_Tool {
			ground    = block_of(v, v.pin_to),
			on_ground = true,
		}
		pinned.buttons[.Primary] = {
			down = true,
			from = block_of(v, v.pin_from),
		}
		p = &pinned
	}
	if !p.on_ground || p.over_ui {return}
	here := tile_of(p.ground)
	primary, secondary := &p.buttons[.Primary], &p.buttons[.Secondary]
	switch v.tool {
	case .Look:
	case .Road:
		if primary.down || primary.released {
			path := hamlet.road_path(tile_of(primary.from), here)
			ok := hamlet.road_refusal(&v.tiles, path) == ""
			for t in path {
				b := block_of(v, t)
				engine.ground_fill(s, b, b, ROAD if ok else BAD)
			}
			if primary.released {
				r := hamlet.Lay_Road{tile16(tile_of(primary.from)), tile16(here)}
				send(s, &r)
			}
		} else {
			b := block_of(v, here)
			engine.ground_outline(s, b, b, OUTLINE)
		}
	case .Zone:
		for b, clear in ([2]^engine.Pointer_Press{primary, secondary}) {
			if !(b.down || b.released) {continue}
			lo, hi := engine.block_rect(block_of(v, tile_of(b.from)), block_of(v, here))
			lo.y, hi.y = hamlet.GROUND, hamlet.GROUND + hamlet.MAX_HILL
			engine.ground_fill(s, lo, hi, BAD if clear == 1 else ZONE)
			engine.ground_outline(s, lo, hi, OUTLINE)
			if b.released {
				r := hamlet.Zone{tile16(tile_of(b.from)), tile16(here), clear == 1}
				send(s, &r)
			}
		}
	case .Build:
		if secondary.clicked {v.rotation = (v.rotation + 1) % 4}
		size := hamlet.footprint(v.kind, v.rotation)
		at := here - size / 2
		floor, refusal := hamlet.placement(&v.tiles, &v.ground, v.kind, at, v.rotation, {.Grass})
		if refusal == "" && !hamlet.can_afford(stock(v), hamlet.KINDS_INFO[v.kind].cost) {
			refusal = hamlet.tr(.Short_Of_Stock)
		}
		if refusal != "" {
			floor = hamlet.ground_top(&v.ground, here.x, here.y) + 1
		}
		if v.shaped {
			engine.structure_ghost(
				s,
				&v.templates[v.kind],
				{at.x, floor, at.y},
				v.rotation,
				GOOD if refusal == "" else BAD,
			)
		}
		lo := game.Block_Pos{at.x, hamlet.GROUND, at.y}
		hi := game.Block_Pos{at.x + size.x - 1, hamlet.GROUND + hamlet.MAX_HILL, at.y + size.y - 1}
		engine.ground_outline(s, lo, hi, OUTLINE)
		if primary.clicked {
			r := hamlet.Build{v.kind, tile16(at), v.rotation}
			send(s, &r)
		}
	case .Demolish:
		t := hamlet.tile_at(&v.tiles, here.x, here.y)
		if t == .House || t == .Building {
			if k, found := structure_on(v, here); found {
				st := &v.structures[k]
				size := hamlet.footprint(st.kind, st.rotation)
				lo := game.Block_Pos{i32(st.at.x), hamlet.GROUND, i32(st.at.y)}
				hi := lo + {size.x - 1, hamlet.MAX_HILL, size.y - 1}
				engine.ground_fill(s, lo, hi, BAD)
			}
		} else if t == .Road || t == .Zone {
			b := block_of(v, here)
			engine.ground_fill(s, b, b, BAD)
		}
		if primary.clicked {
			r := hamlet.Demolish{tile16(here)}
			send(s, &r)
		}
	}
}

tile16 :: proc(p: [2]i32) -> [2]i16 {return {i16(p.x), i16(p.y)}}

stock :: proc(v: ^View) -> (out: [hamlet.Good]int) {
	for n, g in v.town.stock {out[g] = int(n)}
	return
}

// structure_on: the structure standing on tile p.
structure_on :: proc(v: ^View, p: [2]i32) -> (int, bool) {
	for st, k in v.structures {
		if !v.present[k] {continue}
		size := hamlet.footprint(st.kind, st.rotation)
		at := [2]i32{i32(st.at.x), i32(st.at.y)}
		if p.x >= at.x &&
		   p.y >= at.y &&
		   p.x < at.x + size.x &&
		   p.y < at.y + size.y {return k, true}
	}
	return 0, false
}

// marks: the zones always (a faint cover), and the overlay's colours.
marks :: proc(s: ^engine.Session) {
	v := view(s)
	for z in i32(0) ..< hamlet.MAP {
		x := i32(0)
		for x < hamlet.MAP {
			color, shown := mark_color(v, x, z)
			end := x
			for end + 1 < hamlet.MAP {
				c, sh := mark_color(v, end + 1, z)
				if sh != shown || c != color {break}
				end += 1
			}
			if shown {
				// (up to a roof's height: a house's cover lies on its roof)
				engine.ground_fill(
					s,
					{x, hamlet.GROUND, z},
					{end, hamlet.GROUND + hamlet.MAX_HILL + 6, z},
					color,
				)
			}
			x = end + 1
		}
	}
}

// mark_color: the cover of tile (x, z) this frame, if any.
mark_color :: proc(v: ^View, x, z: i32) -> (color: [4]u8, shown: bool) {
	t := v.tiles[z][x]
	switch v.overlay {
	case .None:
		return ZONE, t == .Zone
	case .Access:
		if t != .Grass && t != .Zone {return}
		for dz in -i32(hamlet.ACCESS_REACH) ..= hamlet.ACCESS_REACH {
			for dx in -i32(hamlet.ACCESS_REACH) ..= hamlet.ACCESS_REACH {
				if hamlet.tile_at(&v.tiles, x + dx, z + dz) == .Road {return GOOD, true}
			}
		}
		return BAD, true
	case .Happiness:
		if t != .House {return}
		h := v.happy[z][x]
		switch {
		case h == 0:
			return {150, 150, 150, 170}, true // (empty)
		case h >= 70:
			return {50, 220, 70, 200}, true
		case h >= 40:
			return {240, 210, 50, 200}, true
		}
		return {235, 50, 40, 210}, true
	}
	return
}

TOOLS :: [?]struct {
	label: hamlet.Text,
	tool:  Tool,
	kind:  hamlet.Kind,
} {
	{.Tool_Look, .Look, .House},
	{.Tool_Road, .Road, .House},
	{.Tool_Zone, .Zone, .House},
	{.Tool_Lumber, .Build, .Woodcutter},
	{.Tool_Quarry, .Build, .Quarry},
	{.Tool_Farm, .Build, .Farm},
	{.Tool_Store, .Build, .Storehouse},
	{.Tool_Well, .Build, .Well},
	{.Tool_Market, .Build, .Market},
	{.Tool_Demolish, .Demolish, .House},
}

SPEEDS :: [?]u8{0, 1, 2, 4}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	t := &ctx.theme
	screen := ctx.screen
	// The town's line.
	top := ui.cut_top(&screen, t.row_height + t.padding)
	ui.panel(ctx, top)
	town := v.town
	next := hamlet.tr(.All_Milestones)
	if int(town.milestone) < len(hamlet.MILESTONES) {
		next = hamlet.tr(.Next_Milestone, hamlet.MILESTONES[town.milestone])
	}
	ui.draw_text(
		ctx,
		top,
		hamlet.tr(
			.Status,
			town.day,
			town.population,
			town.housing,
			town.workers,
			town.jobs,
			town.stock[.Wood],
			town.stock[.Stone],
			town.stock[.Food],
			town.happiness,
			next,
		),
		t.font_size,
		t.text,
		.Center,
	)
	// The toolbar: the tools, the overlay, the speeds.
	bar := ui.cut_bottom(&screen, t.row_height + 2 * t.padding)
	ui.panel(ctx, bar)
	row := bar
	row.x += t.padding
	row.y += t.padding
	row.h = t.row_height
	width := (bar.w - 2 * t.padding) / f32(len(TOOLS) + 1 + len(SPEEDS))
	for entry, i in TOOLS {
		r := ui.Rect{row.x + f32(i) * width, row.y, width - 4, row.h}
		chosen := v.tool == entry.tool && (entry.tool != .Build || v.kind == entry.kind)
		if ui.button(ctx, hamlet.tr(entry.label), r, id = fmt.tprintf("tool %d", i)) {
			v.tool, v.kind = entry.tool, entry.kind
		}
		if chosen {lit(ctx, r, t.success)}
	}
	o := ui.Rect{row.x + f32(len(TOOLS)) * width, row.y, width - 4, row.h}
	labels := [Overlay]hamlet.Text {
		.None      = .Overlay_None,
		.Access    = .Overlay_Roads,
		.Happiness = .Overlay_Happy,
	}
	if ui.button(ctx, hamlet.tr(labels[v.overlay]), o, id = "overlay") {
		v.overlay = Overlay((int(v.overlay) + 1) % len(Overlay))
	}
	if v.overlay != .None {lit(ctx, o, t.warning)}
	for speed, i in SPEEDS {
		r := ui.Rect{row.x + f32(len(TOOLS) + 1 + i) * width, row.y, width - 4, row.h}
		label := hamlet.tr(.Pause) if speed == 0 else hamlet.tr(.Speed, speed)
		if ui.button(ctx, label, r, id = fmt.tprintf("speed %d", speed)) {
			r := hamlet.Set_Speed{speed}
			send(s, &r)
		}
		if town.speed == speed {lit(ctx, r, t.success)}
	}
	// The tool's line, over the toolbar.
	hint := ui.cut_bottom(&screen, t.row_height)
	ui.draw_text(ctx, hint, tool_hint(v), t.font_size, t.text, .Center)

	marks(s)
	tools(s)
	// Labels over the workplaces near the middle of the view.
	for st, k in v.structures {
		if !v.present[k] || st.kind == .House {continue}
		if abs(f64(st.at.x) - s.feet.x) > LABEL_REACH ||
		   abs(f64(st.at.y) - s.feet.z) > LABEL_REACH {continue}
		info := &hamlet.KINDS_INFO[st.kind]
		size := hamlet.footprint(st.kind, st.rotation)
		at := [3]f64 {
			f64(st.at.x) + f64(size.x) / 2,
			f64(st.floor) + f64(len(info.layers)) + 0.6,
			f64(st.at.y) + f64(size.y) / 2,
		}
		text := info.name
		if info.jobs > 0 {text = hamlet.tr(.Workplace, info.name, st.workers, info.jobs)}
		engine.world_label(s, ctx, at, text)
	}
	engine.flash_draw(ctx, &v.flash, s, -160)
}

// command: the console's `hamlet` (see GAME.commands).
command :: proc(app: ^engine.App, args: []string) {
	s := app.session
	if s == nil || s.state != .Playing || s.game.id != hamlet.INFO.id {return}
	v := view(s)
	ints :: proc(args: []string) -> (out: [4]i32, n: int) {
		for a, i in args {
			if i >= 4 {break}
			k, ok := strconv.parse_int(a)
			if !ok {break}
			out[i], n = i32(k), i + 1
		}
		return
	}
	if len(args) >= 2 && args[0] == "tool" {
		for name, tool in ([Tool]string{.Look = "look", .Road = "road", .Zone = "zone", .Build = "", .Demolish = "demolish"}) {
			if name != "" && name == args[1] {v.tool = tool}
		}
		for info, kind in hamlet.KINDS_INFO {
			if info.placed && lower(info.name) == args[1] {v.tool, v.kind = .Build, kind}
		}
		n, count := ints(args[2:])
		v.pinned = count >= 2
		v.pin_from = {n[0], n[1]}
		v.pin_to = {n[2], n[3]} if count >= 4 else v.pin_from
		return
	}
	if len(args) == 2 && args[0] == "overlay" {
		switch args[1] {
		case "none":
			v.overlay = .None
		case "roads":
			v.overlay = .Access
		case "happiness":
			v.overlay = .Happiness
		}
		return
	}
	if len(args) == 3 && args[0] == "camera" {
		n, count := ints(args[1:])
		if count == 2 {
			s.free.set = true
			s.free.distance = f32(n[0])
			s.free.heading = f32(n[1]) * 3.14159265 / 180
		}
	}
}

lower :: proc(s: string) -> string {
	b := make([]u8, len(s), context.temp_allocator)
	for c, i in transmute([]u8)s {b[i] = c + 32 if c >= 'A' && c <= 'Z' else c}
	return string(b)
}

LABEL_REACH :: 8 // tiles from the camera's focus: a workplace this near has its label

// lit: a button in use, underlined.
lit :: proc(ctx: ^ui.Context, r: ui.Rect, color: ui.Color) {
	ui.fill_rect(ctx, {r.x + 4, r.y + r.h - 4, r.w - 8, 3}, color)
}

tool_hint :: proc(v: ^View) -> string {
	switch v.tool {
	case .Look:
		return hamlet.tr(.Hint_Look)
	case .Road:
		return hamlet.tr(.Hint_Road)
	case .Zone:
		return hamlet.tr(.Hint_Zone)
	case .Build:
		info := &hamlet.KINDS_INFO[v.kind]
		return hamlet.tr(.Hint_Build, info.name, info.cost[.Wood], info.cost[.Stone])
	case .Demolish:
		return hamlet.tr(.Hint_Demolish)
	}
	return ""
}

debug :: proc(s: ^engine.Session) -> string {
	v := view(s)
	p := engine.pointer_tool(s)
	return fmt.tprintf(
		"seed %d tool %v overlay %v pointer %v %v requests %d",
		v.town.seed,
		v.tool,
		v.overlay,
		p.ground,
		p.on_ground,
		v.requests,
	)
}
