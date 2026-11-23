package engine

import "core:mem"
import "core:slice"

import "client:render"
import "client:ui"
import "common:game"

// Marks: what a game's client part draws in the world from its HUD hook: a label or a
// bar over a point (a tower's range, a quest giver's name, a creep's health), a health
// bar over each entity the server says is hurt (entity_bars), and an outline of
// blocks (a placement's ghost, a building's footprint, a selection). Labels and bars are
// HUD drawing at the point's place on the screen, so they are as sharp as the HUD and
// drawn over the world; outlines are lines in the world, drawn with the debug lines.
// The view they project through is the frame's (screen_view_update, before the HUD).

MAX_WORLD_BOXES :: 64 // outlines a frame
MAX_WORLD_LINES :: 2 * 8192 // ends of the lines a game draws on the ground a frame (ground_outline)
MARK_DISTANCE :: 64 // blocks: marks further from the eyes are not drawn
BAR_WIDTH :: 40 // a health bar, in UI units
BAR_HEIGHT :: 5

// Screen_View: how the world meets the screen this frame (the camera the frame is
// drawn with), so a HUD can draw at a place in the world.
Screen_View :: struct {
	camera: render.Camera,
	size:   [2]f32, // the window, pixels
	set:    bool,
}

// World_Box: an outline of blocks lo..hi (inclusive) to draw this frame.
World_Box :: struct {
	lo, hi: game.Block_Pos,
	color:  [4]u8,
}

// screen_view_update: the frame's view, for world_point (the HUD calls it first).
screen_view_update :: proc(app: ^App) {
	s := app.session
	w := &app.window
	s.screen_view = {
		camera = camera_render(&s.view, w.width, w.height, camera_fov(s, app.settings)),
		size   = {f32(w.width), f32(w.height)},
		set    = true,
	}
}

// world_point: where p in the world is on the screen this frame (UI units); false
// behind the eyes, farther than MARK_DISTANCE, or with no view yet.
world_point :: proc(s: ^Session, ctx: ^ui.Context, p: [3]f64) -> (at: [2]f32, ok: bool) {
	v := &s.screen_view
	if !v.set {return}
	d := p - s.camera.position
	if d.x * d.x + d.y * d.y + d.z * d.z > MARK_DISTANCE * MARK_DISTANCE {return}
	origin := game.chunk_origin(v.camera.chunk)
	rel := p - {f64(origin.x), f64(origin.y), f64(origin.z)}
	clip := v.camera.view_proj * [4]f32{f32(rel.x), f32(rel.y), f32(rel.z), 1}
	if clip.w <= 0.05 {return} 	// behind the camera
	return {
			(clip.x / clip.w * 0.5 + 0.5) * v.size.x / ctx.scale,
			(clip.y / clip.w * 0.5 + 0.5) * v.size.y / ctx.scale,
		},
		true
}

// world_label: text on a dark plate over p, as players' names are.
world_label :: proc(s: ^Session, ctx: ^ui.Context, p: [3]f64, text: string) -> bool {
	at := world_point(s, ctx, p) or_return
	t := &ctx.theme
	width := ui.measure_text(ctx, text, t.font_size) + 2 * t.padding
	r := ui.Rect{at.x - width / 2, at.y - t.row_height / 2, width, t.row_height}
	ui.fill_rect(ctx, r, t.hud_fill)
	ui.draw_text(ctx, r, text, t.font_size, t.text, .Center)
	return true
}

// world_bar: a bar over p, full to `fraction` (0..1), in the theme's health colours.
world_bar :: proc(s: ^Session, ctx: ^ui.Context, p: [3]f64, fraction: f32) -> bool {
	at := world_point(s, ctx, p) or_return
	bar_draw(ctx, bar_rect(at), fraction)
	return true
}

@(private = "file")
bar_rect :: proc(at: ui.Vec2) -> ui.Rect {
	return {at.x - BAR_WIDTH / 2, at.y - BAR_HEIGHT / 2, BAR_WIDTH, BAR_HEIGHT}
}

@(private = "file")
bar_draw :: proc(ctx: ^ui.Context, r: ui.Rect, fraction: f32) {
	t := &ctx.theme
	ui.fill_rect(ctx, ui.rect_expand(r, 1), t.meter_back)
	ui.fill_rect(ctx, r, t.health_empty)
	ui.fill_rect(ctx, {r.x, r.y, r.w * clamp(fraction, 0, 1), r.h}, t.health_full)
}

// entity_bars: a health bar over every entity the session knows of a kind (0: any)
// whose health is below its most (all of them with `always`), just over its box. In a
// crowd the bars do not pile up: the most hurt are drawn first, and a bar that would
// overlap one already drawn is left out, so what shows of a melee is its worst wounds and
// a lone hurt unit always shows (a game draws the picked ones' own with entity_bar).
entity_bars :: proc(s: ^Session, ctx: ^ui.Context, kind: game.Kind_Id = 0, always := false) {
	now, live := session_others_now(s)
	if !live {return}
	Bar :: struct {
		at:       ui.Vec2,
		fraction: f32,
	}
	bars := make([dynamic]Bar, context.temp_allocator)
	for _, &e in s.entities {
		if e.max_health == 0 || (kind != 0 && e.kind != kind) {continue}
		if !always && e.health >= e.max_health {continue}
		v, ok := track_view(&e.track, now)
		info := game.kind_info(s.reg, e.kind)
		if !ok || info == nil {continue}
		at := world_point(
			s,
			ctx,
			v.position + {0, f64(info.box[1]) + ENTITY_MARK_LIFT, 0},
		) or_continue
		append(&bars, Bar{at, f32(e.health) / f32(e.max_health)})
	}
	slice.sort_by(bars[:], proc(a, b: Bar) -> bool {
		return(
			a.fraction < b.fraction ||
			(a.fraction == b.fraction &&
					(a.at.y < b.at.y || (a.at.y == b.at.y && a.at.x < b.at.x))) \
		)
	})
	drawn := make([dynamic]ui.Rect, context.temp_allocator)
	next: for b in bars {
		r := bar_rect(b.at)
		for d in drawn {
			o := ui.rect_intersect(ui.rect_expand(d, 1), r)
			if o.w > 0 && o.h > 0 {continue next}
		}
		append(&drawn, r)
		bar_draw(ctx, r, b.fraction)
	}
}

// ENTITY_MARK_LIFT: blocks over an entity's box where its marks go.
ENTITY_MARK_LIFT :: 0.35

// entity_top: the point just over an entity the session shows (its box's top, lifted
// by ENTITY_MARK_LIFT), where its marks go; false: not known, or not yet placed.
entity_top :: proc(s: ^Session, id: u32) -> (at: [3]f64, ok: bool) {
	e, known := &s.entities[id]
	if !known {return}
	info := game.kind_info(s.reg, e.kind)
	if info == nil {return}
	p := entity_place(s, id) or_return
	return p + {0, f64(info.box[1]) + ENTITY_MARK_LIFT, 0}, true
}

// entity_label: text on a plate over an entity (a name kept in a game's record keyed by
// the entity: game.key_entity), `rows` plates higher (0: just over it; a bar's height
// is a third of a row); false when it is not shown.
entity_label :: proc(s: ^Session, ctx: ^ui.Context, id: u32, text: string, rows: f32 = 0) -> bool {
	at := entity_top(s, id) or_return
	p := world_point(s, ctx, at) or_return
	t := &ctx.theme
	width := ui.measure_text(ctx, text, t.font_size) + 2 * t.padding
	r := ui.Rect{p.x - width / 2, p.y - t.row_height * (rows + 0.5), width, t.row_height}
	ui.fill_rect(ctx, r, t.hud_fill)
	ui.draw_text(ctx, r, text, t.font_size, t.text, .Center)
	return true
}

// entity_bar: an entity's health bar over it, hurt or not (entity_bars puts one over
// every hurt one of a kind); false when it is not shown or has no health.
entity_bar :: proc(s: ^Session, ctx: ^ui.Context, id: u32) -> bool {
	e, known := &s.entities[id]
	if !known || e.max_health == 0 {return false}
	at := entity_top(s, id) or_return
	return world_bar(s, ctx, at, f32(e.health) / f32(e.max_health))
}

// world_box: an outline of the blocks lo..hi drawn in the world this frame (at most
// MAX_WORLD_BOXES; more are not drawn).
world_box :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8) {
	if s.world_box_count >= MAX_WORLD_BOXES {return}
	s.world_boxes[s.world_box_count] = {lo, hi, color}
	s.world_box_count += 1
}

// world_line: a line in the world this frame (MAX_WORLD_LINES ends; more are not drawn).
world_line :: proc(s: ^Session, a, b: [3]f64, color: [4]u8) {
	if len(s.world_lines) + 2 > MAX_WORLD_LINES {return}
	append(&s.world_lines, render.Debug_Point{a, color}, render.Debug_Point{b, color})
}

// world_boxes_draw: the frame's outlines, into the debug lines (then gone).
world_boxes_draw :: proc(s: ^Session, d: ^render.Debug_Draw) {
	for b in s.world_boxes[:s.world_box_count] {
		lo := [3]f64{f64(b.lo.x), f64(b.lo.y), f64(b.lo.z)}
		hi := [3]f64{f64(b.hi.x), f64(b.hi.y), f64(b.hi.z)} + 1
		render.debug_box(d, lo - 0.01, hi + 0.01, b.color)
		// (a second, a hair inside: thick enough to read at a distance)
		render.debug_box(d, lo + 0.02, hi - 0.02, b.color)
	}
	s.world_box_count = 0
	fills_draw(s, d)
}

// entity_place: where the session shows an entity now (false: not known, or not
// yet placed).
entity_place :: proc(s: ^Session, id: u32) -> (at: [3]f64, ok: bool) {
	e, known := &s.entities[id]
	if !known {return}
	now, live := session_others_now(s)
	if !live {return}
	v := track_view(&e.track, now) or_return
	return v.position, true
}

// What a game's HUD is made of (its client part's hud hook draws them): a line of status
// across the top of the screen, banners in big text across its middle, and a flash: a
// banner that stands a few seconds after something happened (a wave set out, a level
// gained). Banners are laid out for a screen 720 high and shrink with a smaller one (the
// engine gives a game's HUD only the screen below F3 while it is open).

// top_bar: a line of text centred across the top of rest, on the HUD's backing, cut
// from rest (what is under it is left for the rest of the HUD).
top_bar :: proc(ctx: ^ui.Context, rest: ^ui.Rect, text: string) {
	t := &ctx.theme
	bar := ui.cut_top(rest, t.row_height + t.padding)
	ui.fill_rect(ctx, bar, t.hud_fill)
	ui.draw_text(ctx, bar, text, t.font_size, t.text, .Center)
}

// BANNER_HEIGHT: the screen height banners are laid out for.
BANNER_HEIGHT :: 720

// banner: a line of big text across the screen, its middle `at` pixels from the
// screen's (negative: above it), `scale` times the title's size, with a shadow.
banner :: proc(ctx: ^ui.Context, at: f32, text: string, scale: f32, color: ui.Color) {
	k := min(1, ctx.screen.h / BANNER_HEIGHT)
	size := ctx.theme.title_size * scale * k
	y := ctx.screen.y + ctx.screen.h / 2 + at * k
	r := ui.Rect{ctx.screen.x, y - size, ctx.screen.w, size * 2}
	shadow := ctx.theme.text_shadow
	shadow.a = u8(u32(shadow.a) * u32(color.a) / 255) // (a fading banner's shadow fades with it)
	ui.draw_text(ctx, {r.x + 3, r.y + 3, r.w, r.h}, text, size, shadow, .Center)
	ui.draw_text(ctx, r, text, size, color, .Center)
}

// Tone: what a flash's news is, which colours it.
Tone :: enum u8 {
	Plain,
	Good,
	Warn,
	Bad,
}

// tone_color: a tone's colour in the theme.
tone_color :: proc(t: ^ui.Theme, tone: Tone) -> ui.Color {
	switch tone {
	case .Good:
		return t.success
	case .Warn:
		return t.log_warn
	case .Bad:
		return t.log_error
	case .Plain:
	}
	return t.text
}

FLASH_SECONDS :: 3.0
FLASH_TEXT_MAX :: 64
FLASH_POP :: 0.25 // seconds a flash takes to pop in (from FLASH_POP_FROM of its size, past it and back)
FLASH_POP_FROM :: 0.7
FLASH_FADE :: 0.4 // ... and to fade at its end

// Flash: a banner shown for a while, kept in the game's view (it outlives the frame its
// news came in). It pops in and fades out on the feel clock (feel.odin), simply there and
// gone under Reduce motion.
Flash :: struct {
	text:    [FLASH_TEXT_MAX]u8,
	len:     int,
	tone:    Tone,
	born:    f64, // the feel clock when it was shown
	seconds: f32, // ... and how long it stands
}

// flash: show text as a banner from now for seconds (it replaces the one shown).
flash :: proc(f: ^Flash, s: ^Session, text: string, tone := Tone.Plain, seconds := FLASH_SECONDS) {
	f.len = copy(f.text[:], text)
	f.tone, f.born, f.seconds = tone, feel_now(s), f32(seconds)
}

// flash_shown: the flash's text while it stands ("" once it has gone).
flash_shown :: proc(f: ^Flash, s: ^Session) -> string {
	if f.len == 0 || feel_age(s, f.born) >= f.seconds {return ""}
	return string(f.text[:f.len])
}

// flash_draw: the flash, while it stands, as a banner at `at` (banner's), popping in and
// fading out.
flash_draw :: proc(ctx: ^ui.Context, f: ^Flash, s: ^Session, at: f32 = -160, scale: f32 = 1) {
	text := flash_shown(f, s)
	if text == "" {return}
	color := tone_color(&ctx.theme, f.tone)
	if s.feel.still {
		banner(ctx, at, text, scale, color)
		return
	}
	age := feel_age(s, f.born)
	pop := FLASH_POP_FROM + (1 - FLASH_POP_FROM) * ui.ease(.Out_Back, age / FLASH_POP)
	color.a = u8(f32(color.a) * clamp((f.seconds - age) / FLASH_FADE, 0, 1))
	banner(ctx, at, text, scale * pop, color)
}

// The logbook's places as the HUD and the player menu show them (the server keeps the
// logbook: game.Logbook, Session.logbook).

// logbook_place_at: where a logbook's place is (the middle of its block's column).
logbook_place_at :: proc(p: ^game.Logbook_Place) -> [3]f64 {
	return {f64(p.at.x) + 0.5, f64(p.at.y), f64(p.at.z) + 0.5}
}

// logbook_here: the place is in the world the player is in now.
logbook_here :: proc(s: ^Session, p: ^game.Logbook_Place) -> bool {return(
		p.world ==
		s.logbook.here \
	)}

// The minimap's ground (client/overview draws it; the player menu's map too): a map seen
// from above, each cell the colour of its top block, read a few rows a frame.

MINIMAP_ROWS_A_FRAME :: 4 // rows of cells whose colour is read again each frame

// Minimap: a game's map from above in a corner of the HUD, its ground read from the world a
// few rows a frame (minimap_init, minimap_ground, minimap_draw).
Minimap :: struct {
	lo, hi:   [2]i32, // the map's blocks (x, z), inclusive
	y_lo:     i32, // the heights its ground lies between
	y_hi:     i32,
	cell:     i32, // blocks a side of a cell
	size:     [2]int, // cells
	colors:   [][4]u8, // each cell's ground (alpha 0: not read yet)
	next_row: int,
}

// minimap_init: a minimap of the map lo..hi (x, z), its ground between y_lo and y_hi, in
// cells of `cell` blocks (the session's arena, with the game's state).
minimap_init :: proc(
	m: ^Minimap,
	lo, hi: [2]i32,
	y_lo, y_hi: i32,
	cell: i32 = 2,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	m.lo, m.hi, m.y_lo, m.y_hi, m.cell = lo, hi, y_lo, y_hi, max(cell, 1)
	m.size = {int((hi.x - lo.x) / m.cell) + 1, int((hi.y - lo.y) / m.cell) + 1}
	err: mem.Allocator_Error
	m.colors, err = make([][4]u8, m.size.x * m.size.y, allocator, loc)
	return err == nil
}

// minimap_move: the minimap's map moved to begin at lo, as big as it was, its ground to be
// read again.
minimap_move :: proc(m: ^Minimap, lo: [2]i32) {
	m.hi += lo - m.lo
	m.lo = lo
	for &c in m.colors {c = {}}
	m.next_row = 0
}

// minimap_ground: a few rows of the ground's colours read from the world again.
minimap_ground :: proc(m: ^Minimap, s: ^Session) {
	if len(m.colors) == 0 {return}
	for _ in 0 ..< MINIMAP_ROWS_A_FRAME {
		cz := m.next_row
		m.next_row = (m.next_row + 1) % m.size.y
		for cx in 0 ..< m.size.x {
			x := m.lo.x + i32(cx) * m.cell + m.cell / 2
			z := m.lo.y + i32(cz) * m.cell + m.cell / 2
			if b, _, ok := ground_top(s, x, z, m.y_lo, m.y_hi); ok {
				m.colors[cz * m.size.x + cx] = block_colour(s, b)
			}
		}
	}
}
