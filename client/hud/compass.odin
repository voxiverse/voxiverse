package hud

import "core:math"

import "client:engine"
import "client:ui"

// The compass: a strip along the top of the screen, the way the eyes face in its middle,
// half the horizon each side of it: a tick every 15 degrees, the eight points named, and a
// mark for each place in the journal (engine.journal_place: a gate, the ruin, a town, an
// outpost a game notes), at the strip's end when it lies behind.

COMPASS_WIDTH :: 480
COMPASS_HEIGHT :: 28
COMPASS_MARGIN :: 6 // from the top of the screen (or F3's bottom)
COMPASS_SPAN :: 180 // degrees across the strip
COMPASS_LABEL_CLEAR :: 8 // degrees: a point this near an end of the strip is not named
COMPASS_MARK_RANGE :: 4096 // blocks: a place farther than this is not marked

@(rodata)
COMPASS_POINTS := [8]engine.Text {
	.Compass_N,
	.Compass_NE,
	.Compass_E,
	.Compass_SE,
	.Compass_S,
	.Compass_SW,
	.Compass_W,
	.Compass_NW,
}

// compass_heading: the way the eyes face, degrees clockwise from north (-z), 0 ..< 360.
compass_heading :: proc(yaw: f32) -> f32 {
	return f32(math.mod(f64(-math.to_degrees(yaw)) + 720, 360))
}

// compass_bearing: the way from one point to another, degrees clockwise from north.
compass_bearing :: proc(from, to: [3]f64) -> f32 {
	d := to - from
	return f32(math.mod(math.to_degrees(math.atan2(d.x, -d.z)) + 720, 360))
}

// compass_offset: how far a bearing is from the heading, -180 ..< 180 (right is positive).
compass_offset :: proc(bearing, heading: f32) -> f32 {
	return f32(math.mod(f64(bearing - heading) + 540, 360)) - 180
}

// compass: the strip, under top (F3's bottom; 0: the screen's); where its bottom is, which
// the game's HUD and the target frame go under.
compass :: proc(ctx: ^ui.Context, s: ^engine.Session, top: f32) -> (bottom: f32) {
	t := &ctx.theme
	w := min(f32(COMPASS_WIDTH), ctx.screen.w - 2 * t.spacing)
	r := ui.Rect {
		ctx.screen.x + (ctx.screen.w - w) / 2,
		max(top, ctx.screen.y) + COMPASS_MARGIN,
		w,
		COMPASS_HEIGHT,
	}
	bottom = r.y + r.h
	ui.fill_rect(ctx, r, t.hud_fill)
	ui.stroke_rect(ctx, r, 1, t.faint_border)
	heading := compass_heading(s.camera.yaw)
	x_of :: proc(r: ui.Rect, offset: f32) -> f32 {return(
			r.x +
			r.w / 2 +
			offset / (COMPASS_SPAN / 2) * (r.w / 2) \
		)}
	ui.push_clip_rect(ctx, r)
	defer ui.pop_clip_rect(ctx)
	small := t.font_size * 0.8
	for deg := 0; deg < 360; deg += 15 {
		off := compass_offset(f32(deg), heading)
		if abs(off) > COMPASS_SPAN / 2 {continue}
		x := x_of(r, off)
		if deg % 45 == 0 {
			if abs(off) > COMPASS_SPAN / 2 - COMPASS_LABEL_CLEAR {continue} 	// (not half cut off at an end)
			name := engine.tr(COMPASS_POINTS[deg / 45])
			ink := t.text if deg % 90 == 0 else t.text_muted
			ui.draw_text(
				ctx,
				{x - 20, r.y, 40, r.h},
				name,
				small if deg % 90 != 0 else t.font_size,
				ink,
				.Center,
			)
		} else {
			ui.fill_rect(ctx, {x - 0.5, r.y + r.h - 7, 1, 5}, t.text_muted)
		}
	}
	// The journal's places.
	j := &s.journal
	for &p in j.places[:j.place_count] {
		d := p.at - s.camera.position
		if d.x * d.x + d.z * d.z > COMPASS_MARK_RANGE * COMPASS_MARK_RANGE {continue}
		off := clamp(
			compass_offset(compass_bearing(s.camera.position, p.at), heading),
			-COMPASS_SPAN / 2,
			COMPASS_SPAN / 2,
		)
		x := clamp(x_of(r, off), r.x + 4, r.x + r.w - 4)
		ui.fill_rect(ctx, {x - 3, r.y + 2, 6, 6}, t.meter_fill)
	}
	// The heading's mark.
	c := r.x + r.w / 2
	ui.fill_rect(ctx, {c - 1, r.y, 2, 5}, t.text)
	ui.fill_rect(ctx, {c - 1, r.y + r.h - 5, 2, 5}, t.text)
	return
}
