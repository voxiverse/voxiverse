package ui

import "core:log"
import "core:mem"

import "../font"

// Glyph cache: glyphs are rasterized on first use at the exact pixel size
// they are drawn at and shelf-packed into an R8 atlas. A 2x2 white block at
// the origin serves solid rectangles. The rows changed since the last
// end_frame are reported so the renderer uploads only those (everything, the
// first time). If the atlas fills up it is cleared and refilled (logged; text
// drawn earlier in that frame may show wrong glyphs for one frame).

GLYPH_ATLAS_SIZE :: 1024

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

Glyph_Cache :: struct {
	font:               ^font.Font,
	pixels:             []u8,
	size:               int,
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
	if c.pixels, err = make([]u8, c.size * c.size, allocator, loc); err != nil {return false}
	c.entries = make(map[Glyph_Key]Glyph_Entry, 256, allocator, loc)
	glyph_cache_clear(c)
	return true
}

@(private)
glyph_cache_destroy :: proc(c: ^Glyph_Cache) {
	delete(c.pixels, c.allocator)
	delete(c.entries)
	c^ = {}
}

@(private)
glyph_cache_clear :: proc(c: ^Glyph_Cache) {
	mem.zero_slice(c.pixels)
	clear(&c.entries)
	for y in 0 ..< 2 do for x in 0 ..< 2 {c.pixels[y * c.size + x] = 255}
	c.shelf_x, c.shelf_y, c.shelf_h = 4, 0, 4 // after the white block
	c.dirty_y0, c.dirty_y1 = 0, c.size // everything changed
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

	g := font.glyph_index(c.font, r)
	if g == 0 && r != 0 {return {}, false} 	// let the caller substitute
	scale := font.scale_for_size(c.font, f32(size))
	bm, raster_ok := font.rasterize(c.font, g, scale, context.temp_allocator)
	if !raster_ok {return {}, false}
	entry.advance = font.advance(c.font, g) * scale
	entry.offset = {f32(bm.x), f32(bm.y)}
	entry.w, entry.h = u16(bm.width), u16(bm.height)
	if bm.width > 0 && bm.height > 0 {
		x, y, placed := shelf_place(c, bm.width, bm.height)
		if !placed {
			log.warnf("ui: glyph atlas full (%d glyphs) - clearing it", len(c.entries))
			glyph_cache_clear(c)
			c.resets += 1
			x, y, placed = shelf_place(c, bm.width, bm.height)
			if !placed {return {}, false} 	// glyph larger than the atlas
		}
		for row in 0 ..< bm.height {
			copy(
				c.pixels[(y + row) * c.size + x:][:bm.width],
				bm.pixels[row * bm.width:][:bm.width],
			)
		}
		entry.x, entry.y = u16(x), u16(y)
		if c.dirty_y1 <= c.dirty_y0 {
			c.dirty_y0, c.dirty_y1 = y, y + bm.height
		} else {
			c.dirty_y0, c.dirty_y1 = min(c.dirty_y0, y), max(c.dirty_y1, y + bm.height)
		}
	}
	c.entries[key] = entry
	return entry, true
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
