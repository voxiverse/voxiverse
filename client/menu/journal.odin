package menu

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

import "client:engine"
import "client:overview"
import "client:ui"
import "common:game"

// The journal (J) and the map (M): what the player has found, from their logbook (kept
// with their character by the server and sent to them: game.Logbook; the gates they
// opened, a game's places such as the sandbox's ruin, the creatures that came into view).
//
// The journal is two pages where the registry has quests (else the second alone), chosen by
// the row under its tab: the quests (quests.odin), shown first; and the places and
// creatures, two panes: the places, those in this world nearest first, each with how far
// and which way it lies ("120 m NE"), then those in other worlds; and the creatures met, in
// the order met. The map is the ground
// round the player seen from above (engine.Minimap, the minimap's ground read from the
// world as the session holds it, re-centred when the player walks off its middle), the
// player an arrow at their place and heading, each place a dot with its name (the tracked
// quest's, engine.quest_way, larger and gold); the places listed beside it.

JOURNAL_ROW :: 26
MAP_BLOCKS :: 256 // blocks the map spans each way
MAP_CELL :: 2 // blocks a side of its cells
MAP_RECENTRE :: 64 // blocks off its middle before it moves with the player
MAP_DEPTH :: 48 // blocks under and over the player its ground is looked for in
MAP_READS :: 3 // minimap_ground's rows read a frame while it is shown, times this
MAP_LIST_WIDTH :: 220

@(rodata)
PLACE_TEXT := [game.Logbook_Place_Kind]engine.Text {
	.Gate       = .Place_Gate,
	.Ruin       = .Place_Ruin,
	.Town       = .Place_Town,
	.Outpost    = .Place_Outpost,
	.Beacon     = .Place_Beacon,
	.Remains    = .Place_Remains,
	.Settlement = .Place_Settlement,
}

// place_title: a place as the journal names it: its own name, else its kind's.
place_title :: proc(p: ^game.Logbook_Place) -> string {
	if name := game.place_name(p); name != "" {return name}
	return engine.tr(PLACE_TEXT[p.kind])
}

// place_way: how far a place is from `from` and which way, "120 m NE" (in another world:
// that).
place_way :: proc(s: ^engine.Session, from: [3]f64, p: ^game.Logbook_Place) -> string {
	if !engine.logbook_here(s, p) {return engine.tr(.Journal_Elsewhere)}
	d := engine.logbook_place_at(p) - from
	far := math.sqrt(d.x * d.x + d.z * d.z)
	bearing := math.mod(math.to_degrees(math.atan2(d.x, -d.z)) + 720 + 22.5, 360)
	return engine.tr(.Journal_Distance, int(far), engine.tr(COMPASS_TEXT[int(bearing / 45) % 8]))
}

@(rodata)
COMPASS_TEXT := [8]engine.Text {
	.Compass_N,
	.Compass_NE,
	.Compass_E,
	.Compass_SE,
	.Compass_S,
	.Compass_SW,
	.Compass_W,
	.Compass_NW,
}

// places_by_distance: the logbook's places, those in this world nearest to `from` first,
// then those in others in the order found.
places_by_distance :: proc(s: ^engine.Session, from: [3]f64) -> []^game.Logbook_Place {
	Near :: struct {
		p: ^game.Logbook_Place,
		d: f64,
	}
	j := &s.logbook.logbook
	near := make([dynamic]Near, context.temp_allocator)
	for &p, i in j.places[:j.place_count] {
		d := engine.logbook_place_at(&p) - from
		far := d.x * d.x + d.z * d.z if engine.logbook_here(s, &p) else 1e30 + f64(i)
		append(&near, Near{&p, far})
	}
	slice.sort_by(near[:], proc(a, b: Near) -> bool {return a.d < b.d})
	out := make([]^game.Logbook_Place, len(near), context.temp_allocator)
	for n, i in near {out[i] = n.p}
	return out
}

// creature_name: a kind as players read it ("shambler").
creature_name :: proc(reg: ^game.Registry, kind: game.Kind_Id) -> string {
	info := game.kind_info(reg, kind)
	if info == nil {return ""}
	name, _ := strings.replace_all(game.kind_name(info), "_", " ", context.temp_allocator)
	return name
}

// list_rows: lines of text in r, each with its right-hand part, as many as fit (the last
// says how many more there are when they do not); empty: the line `none` instead.
@(private = "file")
list_rows :: proc(ctx: ^ui.Context, r: ui.Rect, left, right: []string, none: string) {
	t := &ctx.theme
	area := r
	if len(left) == 0 {
		ui.draw_text(ctx, ui.cut_top(&area, JOURNAL_ROW), none, t.font_size, t.text_muted)
		return
	}
	fits := int(area.h / JOURNAL_ROW)
	for name, i in left {
		line := ui.cut_top(&area, JOURNAL_ROW)
		if i == fits - 1 && len(left) > fits {
			ui.draw_text(ctx, line, fmt.tprintf("+%d", len(left) - i), t.font_size, t.text_muted)
			break
		}
		ui.draw_text(ctx, ui.rect_shrink(line, 2), name, t.font_size, t.text)
		if i <
		   len(
			   right,
		   ) {ui.draw_text(ctx, ui.rect_shrink(line, 2), right[i], t.font_size, t.text_muted, .Right)}
	}
}

// journal_ui: the journal's section.
journal_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	content, shown := section_frame(app, ctx)
	if !shown {return}
	if len(s.reg.quests) > 0 {
		journal_pages(app, ctx, ui.cut_top(&content, t.row_height))
		ui.cut_top(&content, t.spacing)
		if app.player_menu.journal_page == .Quests {
			quests_page(app, ctx, content)
			return
		}
	}
	half := (content.w - 2 * t.spacing) / 2
	left := ui.cut_left(&content, half)
	ui.cut_left(&content, 2 * t.spacing)
	j := &s.logbook.logbook
	names := make([dynamic]string, context.temp_allocator)
	ways := make([dynamic]string, context.temp_allocator)
	for p in places_by_distance(s, s.feet) {
		append(&names, place_title(p))
		append(&ways, place_way(s, s.feet, p))
	}
	list_rows(
		ctx,
		pane(ctx, left, engine.tr(.Journal_Places)),
		names[:],
		ways[:],
		engine.tr(.Journal_No_Places),
	)
	met := make([dynamic]string, context.temp_allocator)
	for k in j.met[:j.met_count] {append(&met, creature_name(s.reg, k))}
	list_rows(
		ctx,
		pane(ctx, content, engine.tr(.Journal_Creatures)),
		met[:],
		nil,
		engine.tr(.Journal_No_Creatures),
	)
}

@(rodata)
JOURNAL_PAGE_TEXT := [engine.Journal_Page]engine.Text {
	.Quests = .Journal_Quests_Page,
	.Log    = .Journal_Log_Page,
}

// journal_pages: the row of the journal's pages in r, the one shown lit, the others
// buttons that show theirs.
@(private = "file")
journal_pages :: proc(app: ^engine.App, ctx: ^ui.Context, r: ui.Rect) {
	t := &ctx.theme
	row := r
	for page in engine.Journal_Page {
		name := engine.tr(JOURNAL_PAGE_TEXT[page])
		b := ui.cut_left(&row, ui.measure_text(ctx, name, t.font_size) + 4 * t.padding)
		ui.cut_left(&row, t.spacing)
		if page == app.player_menu.journal_page {
			ui.fill_rect(ctx, b, t.hover)
			ui.stroke_rect(ctx, b, t.border_width, t.border)
			ui.draw_text(ctx, b, name, t.font_size, t.hover_text, .Center)
		} else if ui.button(ctx, name, b) {
			app.player_menu.journal_page = page
		}
	}
}

// map_ui: the map's section.
map_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	content, shown := section_frame(app, ctx)
	if !shown {return}
	m, made := map_follow(s)
	if !made {return}
	for _ in 0 ..< MAP_READS {engine.minimap_ground(m, s)}
	list := ui.cut_right(&content, MAP_LIST_WIDTH)
	ui.cut_right(&content, 2 * t.spacing)
	under := ui.cut_bottom(&content, t.row_height)
	side := min(content.w, content.h)
	r := ui.Rect{content.x + (content.w - side) / 2, content.y, side, side}
	j := &s.logbook.logbook
	marks := make([dynamic]overview.Mark, context.temp_allocator)
	for &p in j.places[:j.place_count] {
		if !engine.logbook_here(s, &p) {continue}
		at := engine.logbook_place_at(&p)
		append(&marks, overview.Mark{{at.x, at.z}, t.meter_fill, 8})
	}
	if way := engine.quest_way(s, engine.quest_tracked(s)); way != nil { 	// (the tracked quest's place: larger, in the quests' gold)
		at := engine.logbook_place_at(way)
		append(&marks, overview.Mark{{at.x, at.z}, engine.MADE_COLOR, 12})
	}
	overview.minimap_draw(m, s, ctx, r, nil, marks[:], t.list_fill, t.list_fill)
	ui.push_clip_rect(ctx, r)
	small := t.font_size * 0.8
	for &p in j.places[:j.place_count] {
		if !engine.logbook_here(s, &p) {continue}
		spot := engine.logbook_place_at(&p)
		at := overview.minimap_point(m, r, spot.x, spot.z)
		label := ui.Rect{at.x + 6, at.y - 9, 200, 18}
		name := place_title(&p)
		ui.draw_text(ctx, {label.x + 1, label.y + 1, label.w, label.h}, name, small, t.text_shadow)
		ui.draw_text(ctx, label, name, small, t.text)
	}
	// The player: an arrow at their place, pointing the way they face.
	at := overview.minimap_point(m, r, s.feet.x, s.feet.z)
	fx, fz := -math.sin(s.camera.yaw), -math.cos(s.camera.yaw)
	for k in 0 ..< 6 {
		d := f32(k) * 2
		ui.fill_rect(ctx, {at.x + fx * d - 2, at.y + fz * d - 2, 4, 4}, t.text)
	}
	ui.fill_rect(ctx, {at.x - 4, at.y - 4, 8, 8}, t.health_full)
	ui.pop_clip_rect(ctx)
	ui.draw_text(
		ctx,
		under,
		engine.tr(.Map_Across, MAP_BLOCKS),
		t.font_size,
		t.text_muted,
		.Center,
	)
	names := make([dynamic]string, context.temp_allocator)
	ways := make([dynamic]string, context.temp_allocator)
	for p in places_by_distance(s, s.feet) {
		append(&names, place_title(p))
		append(&ways, place_way(s, s.feet, p))
	}
	list_rows(
		ctx,
		pane(ctx, list, engine.tr(.Map_Places)),
		names[:],
		ways[:],
		engine.tr(.Journal_No_Places),
	)
}

// map_follow: the session's map, made the first time (its cells in the session's arena) and
// moved when the player has walked MAP_RECENTRE blocks off its middle; false when it could
// not be made.
map_follow :: proc(s: ^engine.Session) -> (^engine.Minimap, bool) {
	m := &s.world_map
	feet := [2]i32{i32(math.floor(s.feet.x)), i32(math.floor(s.feet.z))}
	y := i32(math.floor(s.feet.y))
	lo := feet - MAP_BLOCKS / 2
	if len(m.colors) == 0 {
		ok := engine.minimap_init(
			m,
			lo,
			lo + MAP_BLOCKS - 1,
			y - MAP_DEPTH,
			y + MAP_DEPTH,
			MAP_CELL,
			engine.session_allocator(s),
		)
		return m, ok
	}
	middle := (m.lo + m.hi) / 2
	if abs(feet.x - middle.x) > MAP_RECENTRE || abs(feet.y - middle.y) > MAP_RECENTRE {
		engine.minimap_move(m, lo)
		m.y_lo, m.y_hi = y - MAP_DEPTH, y + MAP_DEPTH
	}
	return m, true
}
