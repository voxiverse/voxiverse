package overview

import "core:mem"

import "client:engine"
import "client:ui"

// The minimap: a game's map seen from above in a corner of the HUD. Its ground is the
// world's as the session holds it (each cell the colour of its top block, read a few rows a
// frame, a run of one colour drawn as one rectangle), its marks are the game's (a dot each:
// units, buildings, resources, in the colours it chooses), the fog darkens what its side
// does not see, and a frame shows where the camera looks. A click (or a drag) on it says
// where on the map the player pointed: the game moves its camera there (minimap_jump), or
// sends its units.

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

// Mark: a dot of the game's on the minimap.
Mark :: struct {
	at:    [2]f64, // x, z
	color: [4]u8,
	size:  f32, // UI units (0: 3)
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

// minimap_ground: a few rows of the ground's colours read from the world again.
minimap_ground :: proc(m: ^Minimap, s: ^engine.Session) {
	if len(m.colors) == 0 {return}
	for _ in 0 ..< MINIMAP_ROWS_A_FRAME {
		cz := m.next_row
		m.next_row = (m.next_row + 1) % m.size.y
		for cx in 0 ..< m.size.x {
			x := m.lo.x + i32(cx) * m.cell + m.cell / 2
			z := m.lo.y + i32(cz) * m.cell + m.cell / 2
			if b, _, ok := engine.ground_top(s, x, z, m.y_lo, m.y_hi); ok {
				m.colors[cz * m.size.x + cx] = engine.block_colour(s, b)
			}
		}
	}
}

// minimap_point: where a point of the map is on the minimap drawn in r.
minimap_point :: proc(m: ^Minimap, r: ui.Rect, x, z: f64) -> [2]f32 {
	w, h := f64(m.hi.x - m.lo.x + 1), f64(m.hi.y - m.lo.y + 1)
	return {r.x + f32((x - f64(m.lo.x)) / w) * r.w, r.y + f32((z - f64(m.lo.y)) / h) * r.h}
}

// minimap_world: the point of the map under a point of the minimap drawn in r.
minimap_world :: proc(m: ^Minimap, r: ui.Rect, p: [2]f32) -> [2]f64 {
	w, h := f64(m.hi.x - m.lo.x + 1), f64(m.hi.y - m.lo.y + 1)
	return {f64(m.lo.x) + f64((p.x - r.x) / r.w) * w, f64(m.lo.y) + f64((p.y - r.y) / r.h) * h}
}

// minimap_draw: the minimap in r: its ground, the fog of the side (nil: none), the game's
// marks, and the camera's focus framed. The pointer's press or drag on it gives the point
// of the map it is over (pointed), and the world does not take that click.
minimap_draw :: proc(
	m: ^Minimap,
	s: ^engine.Session,
	ctx: ^ui.Context,
	r: ui.Rect,
	fog: ^Fog,
	marks: []Mark,
	unseen, unexplored: [4]u8,
) -> (
	at: [2]f64,
	pointed: bool,
) {
	t := &ctx.theme
	ui.panel(ctx, ui.rect_shrink(r, -2))
	ui.block_pointer(ctx, r)
	cw, ch := r.w / f32(m.size.x), r.h / f32(m.size.y)
	for cz in 0 ..< m.size.y {
		y := r.y + f32(cz) * ch
		// A run of cells of one colour (and one fog) is one rectangle.
		for cx := 0; cx < m.size.x; {
			end := cx + 1
			for end < m.size.x && same_cell(m, fog, cz, cx, end) {end += 1}
			c := cell_color(m, fog, cz, cx, unseen, unexplored)
			if c.a > 0 {
				ui.fill_rect(ctx, {r.x + f32(cx) * cw, y, f32(end - cx) * cw + 0.5, ch + 0.5}, c)
			}
			cx = end
		}
	}
	for mark in marks {
		p := minimap_point(m, r, mark.at.x, mark.at.y)
		size := mark.size if mark.size > 0 else 3
		if !ui.rect_contains(r, p) {continue}
		ui.fill_rect(ctx, {p.x - size / 2, p.y - size / 2, size, size}, mark.color)
	}
	// The camera's focus.
	focus := minimap_point(m, r, s.feet.x, s.feet.z)
	view := f32(16) / f32(m.hi.x - m.lo.x + 1) * r.w
	ui.stroke_rect(ctx, {focus.x - view, focus.y - view * 0.6, 2 * view, 1.2 * view}, 1, t.text)
	ui.stroke_rect(ctx, r, 1, t.border)
	if .Left in ctx.input.mouse_down && ui.rect_contains(r, ctx.input.mouse) {
		return minimap_world(m, r, ctx.input.mouse), true
	}
	return
}

@(private = "file")
same_cell :: proc(m: ^Minimap, fog: ^Fog, cz, a, b: int) -> bool {
	i, j := cz * m.size.x + a, cz * m.size.x + b
	if m.colors[i] != m.colors[j] {return false}
	if fog == nil || !fog_ready(fog) {return true}
	return fog_state(m, fog, cz, a) == fog_state(m, fog, cz, b)
}

// fog_state: 0 seen, 1 explored, 2 never seen (a minimap cell's middle).
@(private = "file")
fog_state :: proc(m: ^Minimap, fog: ^Fog, cz, cx: int) -> int {
	x := f64(m.lo.x) + (f64(cx) + 0.5) * f64(m.cell)
	z := f64(m.lo.y) + (f64(cz) + 0.5) * f64(m.cell)
	if fog_sees(fog, x, z) {return 0}
	return 1 if fog_explored(fog, x, z) else 2
}

@(private = "file")
cell_color :: proc(m: ^Minimap, fog: ^Fog, cz, cx: int, unseen, unexplored: [4]u8) -> [4]u8 {
	c := m.colors[cz * m.size.x + cx]
	if c.a == 0 {return unexplored}
	if fog == nil || !fog_ready(fog) {return c}
	darken :: proc(c, over: [4]u8) -> [4]u8 {
		a := u32(over.a)
		mix :: proc(x, y, a: u32) -> u8 {return u8((x * (255 - a) + y * a) / 255)}
		return {
			mix(u32(c.r), u32(over.r), a),
			mix(u32(c.g), u32(over.g), a),
			mix(u32(c.b), u32(over.b), a),
			255,
		}
	}
	switch fog_state(m, fog, cz, cx) {
	case 1:
		return darken(c, unseen)
	case 2:
		return darken(c, unexplored)
	}
	return c
}

// minimap_jump: the camera's focus moved to a point of the map (the player's own place,
// asked of the server as any move is; height: the y to stand it at).
minimap_jump :: proc(s: ^engine.Session, at: [2]f64, height: f64) {
	engine.session_teleport(
		s,
		{position = {at.x, height, at.y}, yaw = s.camera.yaw, pitch = s.camera.pitch},
	)
}
