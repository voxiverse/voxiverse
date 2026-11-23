package ui

import "core:log"
import "core:mem"

import "client:font"

// Glyph cache: glyphs are rasterized on first use at the exact pixel size
// they are drawn at and shelf-packed into an RGBA8 atlas (a glyph is white
// with its coverage as alpha; the shader multiplies the texel by the vertex
// colour). A 2x2 white block at the origin serves solid rectangles. Icons
// (small coloured images, see add_icon) share the atlas and survive a clear. The rows changed since the last
// end_frame are reported so the renderer uploads only those (everything, the
// first time). If the atlas fills up it is cleared and refilled (logged; text
// drawn earlier in that frame may show wrong glyphs for one frame).

GLYPH_ATLAS_SIZE :: 2048 // (icons are large)

@(private)
Glyph_Key :: struct {
	r:    rune,
	size: u16, // pixels
}

Glyph_Entry :: struct {
	x, y, w, h: u16, // atlas pixels
	offset:     [2]f32, // bitmap top-left relative to the pen on the baseline
	advance:    f32, // pixels
}

// Icon is a handle to an image added with add_icon.
Icon :: distinct int

@(private)
Icon_Image :: struct {
	pixels: [][4]u8, // sRGB, size x size
	size:   int,
	at:     [2]int, // where it is in the atlas now
}

// Drawn_Glyphs: the runes the caller draws itself, as strokes (the gate
// addresses' symbols), asked for whatever the font lacks. The strokes may be
// in the temp allocator. False: not one of them.
Drawn_Glyphs :: #type proc(r: rune) -> (font.Drawn, bool)

Glyph_Cache :: struct {
	drawn:              Drawn_Glyphs, // (nil: none)
	font:               ^font.Font,
	pixels:             []u8, // RGBA8, size x size
	size:               int,
	icons:              [dynamic]Icon_Image,
	entries:            map[Glyph_Key]Glyph_Entry,
	shelf_x, shelf_y:   int,
	shelf_h:            int,
	dirty_y0, dirty_y1: int, // rows changed this frame
	resets:             int,
	allocator:          mem.Allocator,
}

@(private)
glyph_cache_init :: proc(
	c: ^Glyph_Cache,
	f: ^font.Font,
	allocator: mem.Allocator,
	loc := #caller_location,
) -> bool {
	c^ = {}
	c.font = f
	c.allocator = allocator
	c.size = GLYPH_ATLAS_SIZE
	err: mem.Allocator_Error
	if c.pixels, err = make([]u8, c.size * c.size * 4, allocator, loc); err != nil {return false}
	c.entries = make(map[Glyph_Key]Glyph_Entry, 256, allocator, loc)
	glyph_cache_clear(c)
	return true
}

@(private)
glyph_cache_destroy :: proc(c: ^Glyph_Cache) {
	for i in c.icons {delete(i.pixels, c.allocator)}
	delete(c.icons)
	delete(c.pixels, c.allocator)
	delete(c.entries)
	c^ = {}
}

@(private)
glyph_cache_clear :: proc(c: ^Glyph_Cache) {
	mem.zero_slice(c.pixels)
	clear(&c.entries)
	for y in 0 ..< 2 do for x in 0 ..< 2 {
		for k in 0 ..< 4 {c.pixels[(y * c.size + x) * 4 + k] = 255}
	}
	c.shelf_x, c.shelf_y, c.shelf_h = 4, 0, 4 // after the white block
	c.dirty_y0, c.dirty_y1 = 0, c.size // everything changed
	for &i in c.icons {icon_place(c, &i)}
}

// icon_place puts an icon's pixels into the atlas (false: no room).
@(private = "file")
icon_place :: proc(c: ^Glyph_Cache, i: ^Icon_Image) -> bool {
	x, y, ok := shelf_place(c, i.size, i.size)
	if !ok {return false}
	i.at = {x, y}
	for row in 0 ..< i.size {
		for col in 0 ..< i.size {
			copy(
				c.pixels[((y + row) * c.size + x + col) * 4:][:4],
				i.pixels[row * i.size + col][:],
			)
		}
	}
	mark_dirty(c, y, y + i.size)
	return true
}

@(private = "file")
mark_dirty :: proc(c: ^Glyph_Cache, y0, y1: int) {
	if c.dirty_y1 <= c.dirty_y0 {
		c.dirty_y0, c.dirty_y1 = y0, y1
	} else {
		c.dirty_y0, c.dirty_y1 = min(c.dirty_y0, y0), max(c.dirty_y1, y1)
	}
}

// icon_add keeps a size x size image (sRGB RGBA, copied) in the atlas for
// good: a clear of the glyphs puts it back. False if the atlas has no room.
@(private)
icon_add :: proc(c: ^Glyph_Cache, size: int, pixels: [][4]u8) -> (Icon, bool) {
	assert(len(pixels) == size * size)
	img := Icon_Image {
		pixels = make([][4]u8, len(pixels), c.allocator),
		size   = size,
	}
	copy(img.pixels, pixels)
	if !icon_place(c, &img) {
		delete(img.pixels, c.allocator)
		return 0, false
	}
	append(&c.icons, img)
	return Icon(len(c.icons) - 1), true
}

// glyph_cache_white_uv is a texel inside the white block.
@(private)
glyph_cache_white_uv :: proc(c: ^Glyph_Cache) -> [2]f32 {
	return {1 / f32(c.size), 1 / f32(c.size)}
}

@(private)
glyph_cache_get :: proc(c: ^Glyph_Cache, r: rune, size: u16) -> (entry: Glyph_Entry, ok: bool) {
	key := Glyph_Key{r, size}
	if e, found := c.entries[key]; found {return e, true}

	bm: font.Bitmap
	raster_ok: bool
	if g := font.glyph_index(c.font, r); g != 0 || r == 0 {
		scale := font.scale_for_size(c.font, f32(size))
		bm, raster_ok = font.rasterize(c.font, g, scale, context.temp_allocator)
		entry.advance = font.advance(c.font, g) * scale
	} else if drawn, is_drawn := glyph_drawn(c, r); is_drawn {
		bm, raster_ok = font.rasterize_drawn(drawn, f32(size), context.temp_allocator)
		entry.advance = drawn.advance * f32(size)
	} else {
		return {}, false // let the caller substitute
	}
	if !raster_ok {return {}, false}
	entry.offset = {f32(bm.x), f32(bm.y)}
	entry.w, entry.h = u16(bm.width), u16(bm.height)
	if bm.width > 0 && bm.height > 0 {
		x, y, placed := shelf_place(c, bm.width, bm.height)
		if !placed {
			log.warnf("ui glyph atlas full (%d glyphs) - clearing it", len(c.entries))
			glyph_cache_clear(c)
			c.resets += 1
			x, y, placed = shelf_place(c, bm.width, bm.height)
			if !placed {return {}, false} 	// glyph larger than the atlas
		}
		for row in 0 ..< bm.height {
			for col in 0 ..< bm.width {
				at := ((y + row) * c.size + x + col) * 4
				c.pixels[at], c.pixels[at + 1], c.pixels[at + 2] = 255, 255, 255
				c.pixels[at + 3] = bm.pixels[row * bm.width + col]
			}
		}
		entry.x, entry.y = u16(x), u16(y)
		mark_dirty(c, y, y + bm.height)
	}
	c.entries[key] = entry
	return entry, true
}

// glyph_drawn: r drawn by the caller, if the font lacks it and it is one.
@(private)
glyph_drawn :: proc(c: ^Glyph_Cache, r: rune) -> (font.Drawn, bool) {
	if c.drawn == nil || font.glyph_index(c.font, r) != 0 {return {}, false}
	return c.drawn(r)
}

// glyph_advance: how far r moves the pen at an em size, in its units
// (the font's '?' for what neither the font nor the caller draws).
glyph_advance :: proc(c: ^Glyph_Cache, r: rune, size: f32) -> f32 {
	if drawn, is_drawn := glyph_drawn(c, r); is_drawn {return drawn.advance * size}
	g := font.glyph_index(c.font, r)
	if g == 0 && r != 0 {g = font.glyph_index(c.font, '?')}
	return font.advance(c.font, g) * size / c.font.units_per_em
}

// shelf_place finds room for a w×h glyph, one pixel of padding around it
// (so filtering never bleeds neighbours in).
@(private = "file")
shelf_place :: proc(c: ^Glyph_Cache, w, h: int) -> (x, y: int, ok: bool) {
	pw, ph := w + 1, h + 1
	if c.shelf_x + pw > c.size {
		c.shelf_x = 0
		c.shelf_y += c.shelf_h
		c.shelf_h = 0
	}
	if c.shelf_y + ph > c.size || pw > c.size {return}
	x, y = c.shelf_x, c.shelf_y
	c.shelf_x += pw
	c.shelf_h = max(c.shelf_h, ph)
	return x, y, true
}
