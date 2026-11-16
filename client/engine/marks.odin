package engine

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
	t := &ctx.theme
	r := ui.Rect{at.x - BAR_WIDTH / 2, at.y - BAR_HEIGHT / 2, BAR_WIDTH, BAR_HEIGHT}
	ui.fill_rect(ctx, ui.rect_expand(r, 1), t.meter_back)
	ui.fill_rect(ctx, r, t.health_empty)
	ui.fill_rect(ctx, {r.x, r.y, r.w * clamp(fraction, 0, 1), r.h}, t.health_full)
	return true
}

// entity_bars: a health bar over every entity the session knows of a kind (0: any)
// whose health is below its most (all of them with `always`), just over its box.
entity_bars :: proc(s: ^Session, ctx: ^ui.Context, kind: game.Kind_Id = 0, always := false) {
	now, live := session_others_now(s)
	if !live {return}
	for _, &e in s.entities {
		if e.max_health == 0 || (kind != 0 && e.kind != kind) {continue}
		if !always && e.health >= e.max_health {continue}
		v, ok := track_view(&e.track, now)
		info := game.kind_info(s.reg, e.kind)
		if !ok || info == nil {continue}
		world_bar(
			s,
			ctx,
			v.position + {0, f64(info.box[1]) + 0.35, 0},
			f32(e.health) / f32(e.max_health),
		)
	}
}

// world_box: an outline of the blocks lo..hi drawn in the world this frame (at most
// MAX_WORLD_BOXES; more are not drawn).
world_box :: proc(s: ^Session, lo, hi: game.Block_Pos, color: [4]u8) {
	if s.world_box_count >= MAX_WORLD_BOXES {return}
	s.world_boxes[s.world_box_count] = {lo, hi, color}
	s.world_box_count += 1
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
