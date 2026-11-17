package sheet

import "base:runtime"
import "core:strings"

import "client:font"
import "client:texture"

// Canvas: a page of RGBA pixels, a fixed width, growing down as it is drawn.
Canvas :: struct {
	width:  int,
	height: int,
	pixels: [dynamic]texture.Rgba,
}

// Pen: the font at the sizes a sheet uses.
Pen :: struct {
	font: font.Font,
}

BACKGROUND :: texture.Rgba{29, 31, 36, 255}
@(rodata)
CHECKER := [2]texture.Rgba{{58, 61, 68, 255}, {72, 75, 83, 255}} // behind clear texels
TEXT :: texture.Rgba{230, 230, 230, 255}
DIM :: texture.Rgba{150, 154, 162, 255}
ACCENT :: texture.Rgba{240, 196, 96, 255}

// grow makes the canvas at least height pixels tall.
grow :: proc(c: ^Canvas, height: int) {
	if height <= c.height {return}
	if c.pixels.allocator.procedure == nil {c.pixels.allocator = runtime.heap_allocator()}
	// (room for twice the height at once: a canvas grows a row at a time)
	if c.width * height > cap(c.pixels) {reserve(&c.pixels, 2 * c.width * height)}
	resize(&c.pixels, c.width * height)
	for &p in c.pixels[c.width * c.height:] {p = BACKGROUND}
	c.height = height
}

// blend puts colour over the pixel at (x, y) with coverage (0..255) times its alpha.
blend :: proc(c: ^Canvas, x, y: int, colour: texture.Rgba, coverage := 255) {
	if x < 0 || x >= c.width || y < 0 {return}
	grow(c, y + 1)
	p := &c.pixels[y * c.width + x]
	a := coverage * int(colour.a) / 255
	for i in 0 ..< 3 {p[i] = u8((int(colour[i]) * a + int(p[i]) * (255 - a)) / 255)}
}

fill :: proc(c: ^Canvas, x, y, w, h: int, colour: texture.Rgba) {
	for j in y ..< y + h {
		for i in x ..< x + w {blend(c, i, j, colour)}
	}
}

// draw_texture draws pixels (texture.SIZE square) with each texel scale
// pixels wide, tiles x tiles times, over a checker that shows its clear parts.
draw_texture :: proc(c: ^Canvas, x, y: int, pixels: []texture.Rgba, scale, tiles: int) {
	side := texture.SIZE * scale * tiles
	for j in 0 ..< side {
		for i in 0 ..< side {
			texel := (j / scale) % texture.SIZE * texture.SIZE + (i / scale) % texture.SIZE
			check := CHECKER[(i / 8 + j / 8) % 2]
			blend(c, x + i, y + j, check)
			blend(c, x + i, y + j, pixels[texel])
		}
	}
}

// text_width: s's width in pixels at size.
text_width :: proc(pen: ^Pen, s: string, size: f32) -> int {
	scale := font.scale_for_size(&pen.font, size)
	w: f32
	for r in s {w += font.advance(&pen.font, font.glyph_index(&pen.font, r)) * scale}
	return int(w + 0.5)
}

// fit: s, cut short with ".." to be at most width pixels wide at size.
fit :: proc(pen: ^Pen, s: string, size: f32, width: int) -> string {
	if text_width(pen, s, size) <= width {return s}
	for n := len(s) - 1; n > 0; n -= 1 {
		cut := strings.concatenate({s[:n], ".."}, context.temp_allocator)
		if text_width(pen, cut, size) <= width {return cut}
	}
	return ""
}

// wrap: s broken after its commas into at most lines lines of at most width
// pixels at size, the last cut short with ".." if s does not fit.
wrap :: proc(pen: ^Pen, s: string, size: f32, width, lines: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	rest := s
	for rest != "" && len(out) < lines - 1 {
		cut := len(rest)
		for text_width(pen, rest[:cut], size) > width {
			comma := strings.last_index(rest[:cut - 1], ", ")
			if comma < 0 {break}
			cut = comma + 1
		}
		if text_width(pen, rest[:cut], size) > width {break}
		append(&out, rest[:cut])
		rest = strings.trim_left(rest[cut:], " ")
	}
	if rest != "" {append(&out, fit(pen, rest, size, width))}
	return out[:]
}

// draw_text draws s with its top at y (the line's ascent below it).
draw_text :: proc(c: ^Canvas, pen: ^Pen, x, y: int, s: string, size: f32, colour: texture.Rgba) {
	f := &pen.font
	scale := font.scale_for_size(f, size)
	baseline := y + int(f.ascent * scale + 0.5)
	pen_x: f32 = f32(x)
	for r in s {
		g := font.glyph_index(f, r)
		bm, ok := font.rasterize(f, g, scale, context.temp_allocator)
		if ok {
			ox := int(pen_x + 0.5) + bm.x
			for j in 0 ..< bm.height {
				for i in 0 ..< bm.width {
					cover := int(bm.pixels[j * bm.width + i])
					if cover > 0 {blend(c, ox + i, baseline + bm.y + j, colour, cover)}
				}
			}
		}
		pen_x += font.advance(f, g) * scale
	}
}

// line_height: the height of a line of text at size.
line_height :: proc(pen: ^Pen, size: f32) -> int {
	f := &pen.font
	scale := font.scale_for_size(f, size)
	return int((f.ascent - f.descent) * scale + 0.5)
}
