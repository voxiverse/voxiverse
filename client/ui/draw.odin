package ui

import "core:math"
import "core:mem"
import "core:strings"

import "../font"

// Draw output. Vertices are in pixels; colors are sRGB as authored (the
// shader converts to linear); every command carries a scissor rect, so text
// and shapes are clipped exactly.

Color :: [4]u8

Vertex :: struct {
	pos:   [2]f32, // pixels
	uv:    [2]f32, // atlas (rects sample its white texel)
	color: Color,
}

// Image: a picture the renderer owns (the player's preview), drawn whole by
// draw_image; 0 is the atlas.
Image :: distinct u32

Draw_Command :: struct {
	image:       Image, // what it samples (0: the atlas)
	scissor:     [4]i32, // x, y, w, h in pixels
	first_index: u32,
	index_count: u32,
	smooth:      bool, // sampled with a linear filter (icons), else pixel-exact
}

@(private)
Layer_List :: struct {
	vertices: [dynamic]Vertex,
	indices:  [dynamic]u32,
	commands: [dynamic]Draw_Command,
}

// Output is what the renderer consumes after end_frame.
Output :: struct {
	vertices:         []Vertex,
	indices:          []u32,
	commands:         []Draw_Command, // draw in order
	atlas_pixels:     []u8, // RGBA8, atlas_size x atlas_size
	atlas_size:       int,
	atlas_dirty_rows: [2]int, // [first, end) rows changed this frame; empty if equal
	layers:           [Layer]Layer_List,
}

@(private)
output_begin :: proc(out: ^Output, allocator: mem.Allocator) {
	for &l in out.layers {
		l.vertices = make([dynamic]Vertex, 0, 1024, allocator)
		l.indices = make([dynamic]u32, 0, 1536, allocator)
		l.commands = make([dynamic]Draw_Command, 0, 16, allocator)
	}
}

// output_end concatenates the layers bottom to top.
@(private)
output_end :: proc(out: ^Output, glyphs: ^Glyph_Cache) {
	vertex_count, index_count, command_count := 0, 0, 0
	for l in out.layers {
		vertex_count += len(l.vertices)
		index_count += len(l.indices)
		command_count += len(l.commands)
	}
	allocator := out.layers[.Base].vertices.allocator
	vertices := make([dynamic]Vertex, 0, vertex_count, allocator)
	indices := make([dynamic]u32, 0, index_count, allocator)
	commands := make([dynamic]Draw_Command, 0, command_count, allocator)
	for l in out.layers {
		base_vertex, base_index := u32(len(vertices)), u32(len(indices))
		append(&vertices, ..l.vertices[:])
		for i in l.indices {append(&indices, i + base_vertex)}
		for c in l.commands {
			c := c
			c.first_index += base_index
			append(&commands, c)
		}
	}
	out.vertices, out.indices, out.commands = vertices[:], indices[:], commands[:]
	out.atlas_pixels, out.atlas_size = glyphs.pixels, glyphs.size
	out.atlas_dirty_rows = {glyphs.dirty_y0, glyphs.dirty_y1}
	// Handed to the renderer: start collecting the next frame's changes.
	glyphs.dirty_y0, glyphs.dirty_y1 = 0, 0
}

// ---------------------------------------------------------------------------
// Primitives (UI units in, pixels out)
// ---------------------------------------------------------------------------

// fill_rect draws a solid rectangle.
fill_rect :: proc(ctx: ^Context, r: Rect, color: Color) {
	if color.a == 0 {return}
	u := glyph_cache_white_uv(&ctx.glyphs)
	push_quad(ctx, pixel_rect(ctx, r), {u, u}, color)
}

// stroke_rect draws a rectangle outline `thickness` units wide, inside r.
stroke_rect :: proc(ctx: ^Context, r: Rect, thickness: f32, color: Color) {
	t := thickness
	fill_rect(ctx, {r.x, r.y, r.w, t}, color)
	fill_rect(ctx, {r.x, r.y + r.h - t, r.w, t}, color)
	fill_rect(ctx, {r.x, r.y + t, t, r.h - 2 * t}, color)
	fill_rect(ctx, {r.x + r.w - t, r.y + t, t, r.h - 2 * t}, color)
}

// add_icon keeps an image (size x size, sRGB RGBA) to draw with draw_icon.
add_icon :: proc(ctx: ^Context, size: int, pixels: [][4]u8) -> (Icon, bool) {
	return icon_add(&ctx.glyphs, size, pixels)
}

// draw_icon draws icon filling r, multiplied by tint (white: as it is).
draw_icon :: proc(ctx: ^Context, r: Rect, icon: Icon, tint := Color{255, 255, 255, 255}) {
	g := &ctx.glyphs
	if int(icon) < 0 || int(icon) >= len(g.icons) {return}
	img := g.icons[icon]
	inv := 1 / f32(g.size)
	uv := [2][2]f32 {
		{f32(img.at.x) * inv, f32(img.at.y) * inv},
		{f32(img.at.x + img.size) * inv, f32(img.at.y + img.size) * inv},
	}
	push_quad(ctx, pixel_rect(ctx, r), uv, tint, smooth = true)
}

// draw_image draws a renderer-owned picture filling r, smoothly.
draw_image :: proc(ctx: ^Context, r: Rect, image: Image) {
	push_quad(
		ctx,
		pixel_rect(ctx, r),
		{{0, 0}, {1, 1}},
		{255, 255, 255, 255},
		smooth = true,
		image = image,
	)
}

Align :: enum u8 {
	Left,
	Center,
	Right,
}

// draw_text draws one line of text vertically centred in r, aligned
// horizontally. size is the font size in UI units.
draw_text :: proc(
	ctx: ^Context,
	r: Rect,
	text: string,
	size: f32,
	color: Color,
	align := Align.Left,
) {
	if len(text) == 0 || color.a == 0 {return}
	width := measure_text(ctx, text, size)
	x := r.x
	switch align {
	case .Left:
	case .Center:
		x = r.x + (r.w - width) / 2
	case .Right:
		x = r.x + r.w - width
	}
	ascent, descent := font_line_metrics(ctx, size)
	baseline := r.y + (r.h - (ascent - descent)) / 2 + ascent
	draw_text_at(ctx, {x, baseline}, text, size, color)
}

// draw_text_at draws text with its baseline starting at pos (UI units).
draw_text_at :: proc(ctx: ^Context, pos: Vec2, text: string, size: f32, color: Color) {
	draw_text_styled(ctx, pos, text, size, color, {})
}

// Text_Effect: how styled text is drawn: bold twice, a pixel apart (and a
// pixel wider per letter); italic slanted; a line under or through.
Text_Effect :: enum u8 {
	Bold,
	Italic,
	Underline,
	Strike,
}
Text_Effects :: bit_set[Text_Effect]

// ITALIC_SLANT: how far italic leans (across per up).
ITALIC_SLANT :: 0.2

// draw_text_styled draws text with its baseline starting at pos (UI units)
// with effects; returns its width (UI units, as measure_text_styled).
draw_text_styled :: proc(
	ctx: ^Context,
	pos: Vec2,
	text: string,
	size: f32,
	color: Color,
	effects: Text_Effects,
) -> f32 {
	append(&ctx.texts, text) // (what the frame says: tests read it)
	pixel_size := u16(math.round(size * ctx.scale))
	if pixel_size == 0 {return 0}
	// Snap the pen to whole pixels so glyph bitmaps map 1:1 (crisp text).
	pen := [2]f32{math.round(pos.x * ctx.scale), math.round(pos.y * ctx.scale)}
	start := pen.x
	bold := f32(max(1, math.round(ctx.scale))) if .Bold in effects else 0
	slant := f32(ITALIC_SLANT) if .Italic in effects else 0
	clip := pixel_rect(ctx, current_clip(ctx))
	for r in text {
		g, ok := glyph_cache_get(&ctx.glyphs, r, pixel_size)
		if !ok {g, ok = glyph_cache_get(&ctx.glyphs, '?', pixel_size)}
		if ok && g.w > 0 {
			quad := [4]f32{pen.x + g.offset.x, pen.y + g.offset.y, f32(g.w), f32(g.h)}
			// Glyphs entirely outside the clip are skipped; partial ones are
			// cut by the scissor.
			if quad[0] < clip[0] + clip[2] &&
			   quad[0] + quad[2] > clip[0] &&
			   quad[1] < clip[1] + clip[3] &&
			   quad[1] + quad[3] > clip[1] {
				inv := 1 / f32(ctx.glyphs.size)
				uv := [2][2]f32 {
					{f32(g.x) * inv, f32(g.y) * inv},
					{f32(g.x + g.w) * inv, f32(g.y + g.h) * inv},
				}
				push_quad(ctx, quad, uv, color, slant, pen.y)
				if bold > 0 {
					push_quad(ctx, quad + {bold, 0, 0, 0}, uv, color, slant, pen.y)
				}
			}
		}
		pen.x += g.advance + bold
	}
	if effects & {.Underline, .Strike} != {} {
		u := glyph_cache_white_uv(&ctx.glyphs)
		ascent, descent := font_line_metrics(ctx, size)
		thick := max(1, math.round(f32(pixel_size) / 12))
		if .Underline in effects {
			y := pen.y + math.round(-descent * ctx.scale * 0.4)
			push_quad(ctx, {start, y, pen.x - start, thick}, {u, u}, color)
		}
		if .Strike in effects {
			y := pen.y - math.round(ascent * ctx.scale * 0.3)
			push_quad(ctx, {start, y, pen.x - start, thick}, {u, u}, color)
		}
	}
	return (pen.x - start) / ctx.scale
}

// draw_text_tilted draws one line of text centred on `centre` (UI units),
// turned by `angle` radians (clockwise on the screen), over the layer's clip.
// Glyphs are rasterized once at `raster_size` (UI units; 0: `size`) rounded up
// to whole pixels, and the quads scaled by the continuous factor
// size * scale / pixel size, so text whose size changes every frame (a pulse)
// scales smoothly and never fetches glyphs at a new size.
draw_text_tilted :: proc(
	ctx: ^Context,
	centre: Vec2,
	text: string,
	size: f32,
	color: Color,
	angle: f32,
	raster_size: f32 = 0,
) {
	append(&ctx.texts, text)
	raster := raster_size if raster_size > 0 else size
	pixel_size := u16(math.ceil(max(raster, size) * ctx.scale))
	if pixel_size == 0 || len(text) == 0 {return}
	k := size * ctx.scale / f32(pixel_size) // quad scale: raster pixels to screen pixels
	width := measure_text(ctx, text, size) * ctx.scale
	ascent, descent := font_line_metrics(ctx, size)
	c := centre * ctx.scale
	turn := [4]f32{c.x, c.y, math.sin(angle), math.cos(angle)}
	pen := [2]f32{c.x - width / 2, c.y + (ascent + descent) * ctx.scale / 2}
	inv := 1 / f32(ctx.glyphs.size)
	for r in text {
		g, ok := glyph_cache_get(&ctx.glyphs, r, pixel_size)
		if !ok {g, ok = glyph_cache_get(&ctx.glyphs, '?', pixel_size)}
		if ok && g.w > 0 {
			quad := [4]f32{pen.x + g.offset.x * k, pen.y + g.offset.y * k, f32(g.w) * k, f32(g.h) * k}
			uv := [2][2]f32 {
				{f32(g.x) * inv, f32(g.y) * inv},
				{f32(g.x + g.w) * inv, f32(g.y + g.h) * inv},
			}
			push_quad(ctx, quad, uv, color, smooth = true, turn = turn)
		}
		pen.x += g.advance * k
	}
}

// measure_text_styled is the width of text drawn with effects (UI units).
measure_text_styled :: proc(ctx: ^Context, text: string, size: f32, effects: Text_Effects) -> f32 {
	width := measure_text(ctx, text, size)
	if .Bold in effects {
		width += f32(strings.rune_count(text)) * max(1, math.round(ctx.scale)) / ctx.scale
	}
	return width
}

// measure_text is the width of text in UI units.
measure_text :: proc(ctx: ^Context, text: string, size: f32) -> f32 {
	width: f32
	for r in text {
		f, g := glyph_font(&ctx.glyphs, r)
		width += font.advance(f, g) * size / f.units_per_em
	}
	return width
}

// font_line_metrics: ascent (above baseline, positive) and descent (below,
// negative), UI units.
font_line_metrics :: proc(ctx: ^Context, size: f32) -> (ascent, descent: f32) {
	f := ctx.glyphs.font
	scale := size / f.units_per_em
	return f.ascent * scale, f.descent * scale
}

@(private)
pixel_rect :: proc(ctx: ^Context, r: Rect) -> [4]f32 {
	s := ctx.scale
	x0, y0 := math.round(r.x * s), math.round(r.y * s)
	x1, y1 := math.round((r.x + r.w) * s), math.round((r.y + r.h) * s)
	return {x0, y0, x1 - x0, y1 - y0}
}

@(private)
push_quad :: proc(
	ctx: ^Context,
	q: [4]f32,
	uv: [2][2]f32,
	color: Color,
	slant: f32 = 0, // leaning right by this per pixel above baseline (italic)
	baseline: f32 = 0,
	smooth := false,
	image: Image = 0,
	turn: [4]f32 = {}, // centre x, y (pixels), sin, cos: the quad turned about it (cos 0: not turned)
) {
	if q[2] <= 0 || q[3] <= 0 {return}
	l := &ctx.output.layers[ctx.layer]
	color := color
	if ctx.theme.opacity < 1 {
		color.a = u8(math.round(f32(color.a) * max(ctx.theme.opacity, 0)))
	}
	clip := pixel_rect(ctx, current_clip(ctx))
	if clip[2] <= 0 || clip[3] <= 0 {return}
	scissor := [4]i32{i32(clip[0]), i32(clip[1]), i32(clip[2]), i32(clip[3])}

	// Extend the last command when the scissor is unchanged.
	if n := len(l.commands);
	   n == 0 ||
	   l.commands[n - 1].scissor != scissor ||
	   l.commands[n - 1].smooth != smooth ||
	   l.commands[n - 1].image != image {
		append(
			&l.commands,
			Draw_Command {
				scissor = scissor,
				first_index = u32(len(l.indices)),
				smooth = smooth,
				image = image,
			},
		)
	}
	base := u32(len(l.vertices))
	x0, y0, x1, y1 := q[0], q[1], q[0] + q[2], q[1] + q[3]
	top, bottom := slant * (baseline - y0), slant * (baseline - y1)
	append(
		&l.vertices,
		Vertex{{x0 + top, y0}, {uv[0].x, uv[0].y}, color},
		Vertex{{x1 + top, y0}, {uv[1].x, uv[0].y}, color},
		Vertex{{x1 + bottom, y1}, {uv[1].x, uv[1].y}, color},
		Vertex{{x0 + bottom, y1}, {uv[0].x, uv[1].y}, color},
	)
	if turn[3] != 0 {
		for i in 0 ..< 4 {
			d := l.vertices[int(base) + i].pos - {turn[0], turn[1]}
			l.vertices[int(base) + i].pos =
				{turn[0], turn[1]} + {d.x * turn[3] - d.y * turn[2], d.x * turn[2] + d.y * turn[3]}
		}
	}
	append(&l.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	l.commands[len(l.commands) - 1].index_count += 6
}
