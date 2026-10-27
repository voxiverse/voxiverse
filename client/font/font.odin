package font

import "core:math"
import "core:mem"

// TrueType fonts in pure Odin: parsing (cmap formats 4 and 12, simple and
// composite glyf outlines, horizontal metrics) and anti-aliased glyph
// rasterization by exact area coverage. No hinting and no shaping: enough for
// a monospace UI font rendered at the pixel size it is shown at.
//
// The Font borrows the file's bytes; keep them alive as long as the Font.

Font :: struct {
	data:             []u8,
	units_per_em:     f32,
	ascent:           f32, // font units, positive up
	descent:          f32, // font units, negative
	line_gap:         f32,
	num_glyphs:       int,
	num_hmetrics:     int,
	loca_long:        bool,
	cmap_format:      u16,
	cmap:             []u8, // the chosen subtable
	loca, glyf, hmtx: []u8,
}

Glyph :: distinct u16

// Bitmap is a rasterized glyph: one coverage byte per pixel, rows top to
// bottom. (x, y) is where its top-left corner goes relative to the pen
// position on the baseline (y grows downward).
Bitmap :: struct {
	width, height: int,
	x, y:          int,
	pixels:        []u8,
}

load :: proc(data: []u8) -> (f: Font, ok: bool) {
	f.data = data
	if len(data) < 12 {return}
	version := be_u32(data, 0)
	if version != 0x00010000 && version != 0x74727565 {return} 	// TrueType outlines only
	num_tables := int(be_u16(data, 4))
	tables: map[string][]u8
	tables.allocator = context.temp_allocator
	for i in 0 ..< num_tables {
		rec := 12 + 16 * i
		if rec + 16 > len(data) {return}
		tag := string(data[rec:rec + 4])
		offset, length := int(be_u32(data, rec + 8)), int(be_u32(data, rec + 12))
		if offset + length > len(data) {return}
		tables[tag] = data[offset:offset + length]
	}
	head, hhea, maxp, cmap := tables["head"], tables["hhea"], tables["maxp"], tables["cmap"]
	f.loca, f.glyf, f.hmtx = tables["loca"], tables["glyf"], tables["hmtx"]
	if len(head) < 54 ||
	   len(hhea) < 36 ||
	   len(maxp) < 6 ||
	   len(cmap) < 4 ||
	   f.loca == nil ||
	   f.glyf == nil ||
	   f.hmtx == nil {
		return
	}
	f.units_per_em = f32(be_u16(head, 18))
	f.loca_long = be_i16(head, 50) == 1
	f.ascent = f32(be_i16(hhea, 4))
	f.descent = f32(be_i16(hhea, 6))
	f.line_gap = f32(be_i16(hhea, 8))
	f.num_hmetrics = int(be_u16(hhea, 34))
	f.num_glyphs = int(be_u16(maxp, 4))

	// Prefer a full-Unicode subtable (format 12), else BMP (format 4).
	best := -1
	for i in 0 ..< int(be_u16(cmap, 2)) {
		rec := 4 + 8 * i
		if rec + 8 > len(cmap) {break}
		platform, encoding := be_u16(cmap, rec), be_u16(cmap, rec + 2)
		offset := int(be_u32(cmap, rec + 4))
		if offset + 4 > len(cmap) {continue}
		unicode := platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
		format := be_u16(cmap, offset)
		if !unicode || (format != 4 && format != 12) {continue}
		if best < 0 || format == 12 {
			best = offset
			f.cmap_format = format
		}
	}
	if best < 0 {return}
	f.cmap = cmap[best:]
	return f, true
}

// scale_for_size converts font units to pixels for an em size in pixels.
scale_for_size :: proc(f: ^Font, pixel_size: f32) -> f32 {
	return pixel_size / f.units_per_em
}

glyph_index :: proc(f: ^Font, r: rune) -> Glyph {
	c := u32(r)
	t := f.cmap
	switch f.cmap_format {
	case 4:
		if c > 0xFFFF || len(t) < 14 {return 0}
		seg_count := int(be_u16(t, 6)) / 2
		ends, starts := 14, 14 + seg_count * 2 + 2
		deltas, ranges := starts + seg_count * 2, starts + seg_count * 4
		if ranges + seg_count * 2 > len(t) {return 0}
		for i in 0 ..< seg_count {
			end := u32(be_u16(t, ends + 2 * i))
			if c > end {continue}
			start := u32(be_u16(t, starts + 2 * i))
			if c < start {return 0}
			delta := be_u16(t, deltas + 2 * i)
			range_offset := int(be_u16(t, ranges + 2 * i))
			if range_offset == 0 {return Glyph(u16(c) + delta)}
			at := ranges + 2 * i + range_offset + 2 * int(c - start)
			if at + 2 > len(t) {return 0}
			g := be_u16(t, at)
			return Glyph(g + delta) if g != 0 else 0
		}
	case 12:
		if len(t) < 16 {return 0}
		groups := int(be_u32(t, 12))
		lo, hi := 0, groups - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			rec := 16 + 12 * mid
			if rec + 12 > len(t) {return 0}
			start, end := be_u32(t, rec), be_u32(t, rec + 4)
			switch {
			case c < start:
				hi = mid - 1
			case c > end:
				lo = mid + 1
			case:
				return Glyph(be_u32(t, rec + 8) + (c - start))
			}
		}
	}
	return 0
}

// advance is the horizontal advance in font units.
advance :: proc(f: ^Font, g: Glyph) -> f32 {
	i := min(int(g), f.num_hmetrics - 1)
	if 4 * i + 2 > len(f.hmtx) {return 0}
	return f32(be_u16(f.hmtx, 4 * i))
}

// ---------------------------------------------------------------------------
// Outlines
// ---------------------------------------------------------------------------

Point :: [2]f32

// Outline is a glyph as closed polylines (quadratics flattened), in pixels
// with y down, relative to the pen position on the baseline.
@(private)
Outline :: struct {
	points:   [dynamic]Point,
	contours: [dynamic]int, // end index (exclusive) of each contour in points
	min, max: Point,
}

@(private)
glyph_data :: proc(f: ^Font, g: Glyph) -> []u8 {
	if int(g) >= f.num_glyphs {return nil}
	start, end: int
	if f.loca_long {
		if 4 * int(g) + 8 > len(f.loca) {return nil}
		start, end = int(be_u32(f.loca, 4 * int(g))), int(be_u32(f.loca, 4 * int(g) + 4))
	} else {
		if 2 * int(g) + 4 > len(f.loca) {return nil}
		start, end = 2 * int(be_u16(f.loca, 2 * int(g))), 2 * int(be_u16(f.loca, 2 * int(g) + 2))
	}
	if start >= end || end > len(f.glyf) {return nil}
	return f.glyf[start:end]
}

// Affine transform for composite glyph components: x' = a*x + c*y + dx ...
@(private)
Transform :: struct {
	a, b, c, d, dx, dy: f32,
}

@(private)
IDENTITY :: Transform{1, 0, 0, 1, 0, 0}

@(private)
build_outline :: proc(
	f: ^Font,
	g: Glyph,
	scale: f32,
	out: ^Outline,
	xf := IDENTITY,
	depth := 0,
) -> bool {
	data := glyph_data(f, g)
	if len(data) < 10 {return true} 	// empty glyph (space)
	contours := int(be_i16(data, 0))
	if contours >= 0 {
		return simple_outline(data, contours, scale, xf, out)
	}
	if depth > 8 {return false}
	// Composite: a list of transformed component glyphs.
	ARG_WORDS :: 0x1
	ARGS_ARE_XY :: 0x2
	HAVE_SCALE :: 0x8
	MORE :: 0x20
	HAVE_XY_SCALE :: 0x40
	HAVE_2X2 :: 0x80
	at := 10
	for {
		if at + 4 > len(data) {return false}
		flags := be_u16(data, at)
		component := Glyph(be_u16(data, at + 2))
		at += 4
		arg1, arg2: f32
		if flags & ARG_WORDS != 0 {
			if at + 4 > len(data) {return false}
			arg1, arg2 = f32(be_i16(data, at)), f32(be_i16(data, at + 2))
			at += 4
		} else {
			if at + 2 > len(data) {return false}
			arg1, arg2 = f32(i8(data[at])), f32(i8(data[at + 1]))
			at += 2
		}
		t := Transform{1, 0, 0, 1, 0, 0}
		if flags & ARGS_ARE_XY != 0 {t.dx, t.dy = arg1, arg2} 	// else: point matching (unsupported, rare)
		switch {
		case flags & HAVE_SCALE != 0:
			if at + 2 > len(data) {return false}
			t.a = f2dot14(data, at)
			t.d = t.a
			at += 2
		case flags & HAVE_XY_SCALE != 0:
			if at + 4 > len(data) {return false}
			t.a, t.d = f2dot14(data, at), f2dot14(data, at + 2)
			at += 4
		case flags & HAVE_2X2 != 0:
			if at + 8 > len(data) {return false}
			t.a, t.b, t.c, t.d =
				f2dot14(data, at),
				f2dot14(data, at + 2),
				f2dot14(data, at + 4),
				f2dot14(data, at + 6)
			at += 8
		}
		// Compose: apply the component transform, then the parent's.
		combined := Transform {
			a  = xf.a * t.a + xf.c * t.b,
			b  = xf.b * t.a + xf.d * t.b,
			c  = xf.a * t.c + xf.c * t.d,
			d  = xf.b * t.c + xf.d * t.d,
			dx = xf.a * t.dx + xf.c * t.dy + xf.dx,
			dy = xf.b * t.dx + xf.d * t.dy + xf.dy,
		}
		build_outline(f, component, scale, out, combined, depth + 1) or_return
		if flags & MORE == 0 {break}
	}
	return true
}

@(private)
simple_outline :: proc(
	data: []u8,
	contour_count: int,
	scale: f32,
	xf: Transform,
	out: ^Outline,
) -> bool {
	ON_CURVE :: 0x01
	X_SHORT :: 0x02
	Y_SHORT :: 0x04
	REPEAT :: 0x08
	X_SAME_OR_POSITIVE :: 0x10
	Y_SAME_OR_POSITIVE :: 0x20

	if contour_count == 0 {return true}
	at := 10
	if at + 2 * contour_count + 2 > len(data) {return false}
	end_points := make([]int, contour_count, context.temp_allocator)
	for &e, i in end_points {e = int(be_u16(data, at + 2 * i))}
	at += 2 * contour_count
	n := end_points[contour_count - 1] + 1
	instructions := int(be_u16(data, at))
	at += 2 + instructions

	flags := make([]u8, n, context.temp_allocator)
	for i := 0; i < n; {
		if at >= len(data) {return false}
		flag := data[at]
		at += 1
		repeat := 1
		if flag & REPEAT != 0 {
			if at >= len(data) {return false}
			repeat += int(data[at])
			at += 1
		}
		for _ in 0 ..< repeat {
			if i < n {flags[i] = flag}
			i += 1
		}
	}
	coords := make([]Point, n, context.temp_allocator)
	value: i32
	for i in 0 ..< n { 	// x
		if flags[i] & X_SHORT != 0 {
			if at >= len(data) {return false}
			delta := i32(data[at])
			at += 1
			value += delta if flags[i] & X_SAME_OR_POSITIVE != 0 else -delta
		} else if flags[i] & X_SAME_OR_POSITIVE == 0 {
			if at + 2 > len(data) {return false}
			value += i32(be_i16(data, at))
			at += 2
		}
		coords[i].x = f32(value)
	}
	value = 0
	for i in 0 ..< n { 	// y
		if flags[i] & Y_SHORT != 0 {
			if at >= len(data) {return false}
			delta := i32(data[at])
			at += 1
			value += delta if flags[i] & Y_SAME_OR_POSITIVE != 0 else -delta
		} else if flags[i] & Y_SAME_OR_POSITIVE == 0 {
			if at + 2 > len(data) {return false}
			value += i32(be_i16(data, at))
			at += 2
		}
		coords[i].y = f32(value)
	}
	// Font units -> pixels, y down.
	for &p in coords {
		x := xf.a * p.x + xf.c * p.y + xf.dx
		y := xf.b * p.x + xf.d * p.y + xf.dy
		p = {x * scale, -y * scale}
	}

	start := 0
	for end in end_points {
		emit_contour(coords[start:end + 1], flags[start:end + 1], out)
		start = end + 1
	}
	return true
}

// emit_contour flattens one contour of on/off-curve points into a closed
// polyline. Two off-curve points in a row imply an on-curve point midway.
@(private)
emit_contour :: proc(pts: []Point, flags: []u8, out: ^Outline) {
	n := len(pts)
	if n < 2 {return}
	on :: proc(flags: []u8, i: int) -> bool {return flags[i] & 1 != 0}
	// Start at an on-curve point (or the midpoint of two off-curve points).
	first: Point
	first_index := -1
	for i in 0 ..< n {
		if on(flags, i) {first, first_index = pts[i], i; break}
	}
	if first_index < 0 {
		first = (pts[0] + pts[1]) * 0.5
		first_index = 0
	}
	add_point(out, first)
	prev := first
	control: Maybe(Point)
	for k in 1 ..= n {
		i := (first_index + k) % n
		p := pts[i]
		if on(flags, i) {
			if c, has := control.?; has {
				flatten_quad(out, prev, c, p)
				control = nil
			} else {
				add_point(out, p)
			}
			prev = p
		} else {
			if c, has := control.?; has {
				mid := (c + p) * 0.5
				flatten_quad(out, prev, c, mid)
				prev = mid
			}
			control = p
		}
	}
	if c, has := control.?; has {flatten_quad(out, prev, c, first)}
	append(&out.contours, len(out.points))
}

@(private)
add_point :: proc(out: ^Outline, p: Point) {
	if len(out.points) == 0 {out.min, out.max = p, p}
	out.min = {min(out.min.x, p.x), min(out.min.y, p.y)}
	out.max = {max(out.max.x, p.x), max(out.max.y, p.y)}
	append(&out.points, p)
}

// flatten_quad approximates a quadratic Bezier with line segments, more of
// them the more it bends (from font-rs).
@(private)
flatten_quad :: proc(out: ^Outline, p0, p1, p2: Point) {
	dev := p0 - 2 * p1 + p2
	devsq := dev.x * dev.x + dev.y * dev.y
	if devsq < 0.333 {
		add_point(out, p2)
		return
	}
	segments := 1 + int(math.floor(math.sqrt(math.sqrt(3 * devsq))))
	for i in 1 ..= segments {
		t := f32(i) / f32(segments)
		mt := 1 - t
		add_point(out, mt * mt * p0 + 2 * mt * t * p1 + t * t * p2)
	}
}

// ---------------------------------------------------------------------------
// Rasterization
// ---------------------------------------------------------------------------

// rasterize renders glyph g at the given scale (scale_for_size). The bitmap
// is empty (0x0) for glyphs without outlines, like space.
rasterize :: proc(
	f: ^Font,
	g: Glyph,
	scale: f32,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	bm: Bitmap,
	ok: bool,
) {
	outline: Outline
	outline.points.allocator = context.temp_allocator
	outline.contours.allocator = context.temp_allocator
	build_outline(f, g, scale, &outline) or_return
	if len(outline.points) == 0 {return {}, true}

	// Pixel bounds, plus a column of slack for the accumulation buffer.
	x0, y0 := int(math.floor(outline.min.x)), int(math.floor(outline.min.y))
	x1, y1 := int(math.ceil(outline.max.x)), int(math.ceil(outline.max.y))
	bm.width, bm.height = max(x1 - x0, 1), max(y1 - y0, 1)
	bm.x, bm.y = x0, y0

	acc := make([]f32, bm.width * bm.height + bm.width + 2, context.temp_allocator)
	offset := Point{f32(x0), f32(y0)}
	start := 0
	for end in outline.contours {
		for i in start ..< end {
			a := outline.points[i] - offset
			b := outline.points[start if i + 1 == end else i + 1] - offset
			draw_line(acc, bm.width, bm.height, a, b)
		}
		start = end
	}

	err: mem.Allocator_Error
	if bm.pixels, err = make([]u8, bm.width * bm.height, allocator, loc);
	   err != nil {return {}, false}
	sum: f32
	for i in 0 ..< len(bm.pixels) {
		sum += acc[i]
		bm.pixels[i] = u8(min(abs(sum), 1) * 255 + 0.5)
	}
	return bm, true
}

bitmap_destroy :: proc(bm: ^Bitmap, allocator := context.allocator) {
	delete(bm.pixels, allocator)
	bm^ = {}
}

// draw_line accumulates a line's signed area contribution per pixel; a
// running sum over each row then yields exact coverage (the font-rs method).
@(private)
draw_line :: proc(acc: []f32, w, h: int, p0, p1: Point) {
	if abs(p0.y - p1.y) <= 1e-6 {return}
	dir: f32 = 1
	p0, p1 := p0, p1
	if p0.y > p1.y {
		p0, p1 = p1, p0
		dir = -1
	}
	dxdy := (p1.x - p0.x) / (p1.y - p0.y)
	x := p0.x
	if p0.y < 0 {x -= p0.y * dxdy}
	y_start := max(int(p0.y), 0)
	y_end := min(h, int(math.ceil(p1.y)))
	for y in y_start ..< y_end {
		row := y * w
		dy := min(f32(y + 1), p1.y) - max(f32(y), p0.y)
		x_next := x + dxdy * dy
		d := dy * dir
		xa, xb := min(x, x_next), max(x, x_next)
		xa_floor := math.floor(xa)
		xa_i := int(xa_floor)
		xb_ceil := math.ceil(xb)
		xb_i := int(xb_ceil)
		if row + xa_i < 0 {
			x = x_next
			continue
		}
		if xb_i <= xa_i + 1 {
			xmf := 0.5 * (x + x_next) - xa_floor
			acc[row + xa_i] += d - d * xmf
			acc[row + xa_i + 1] += d * xmf
		} else {
			s := 1 / (xb - xa)
			xa_f := xa - xa_floor
			a0 := 0.5 * s * (1 - xa_f) * (1 - xa_f)
			xb_f := xb - xb_ceil + 1
			am := 0.5 * s * xb_f * xb_f
			acc[row + xa_i] += d * a0
			if xb_i == xa_i + 2 {
				acc[row + xa_i + 1] += d * (1 - a0 - am)
			} else {
				a1 := s * (1.5 - xa_f)
				acc[row + xa_i + 1] += d * (a1 - a0)
				for xi in xa_i + 2 ..< xb_i - 1 {
					acc[row + xi] += d * s
				}
				a2 := a1 + f32(xb_i - xa_i - 3) * s
				acc[row + xb_i - 1] += d * (1 - a2 - am)
			}
			acc[row + xb_i] += d * am
		}
		x = x_next
	}
}

// ---------------------------------------------------------------------------
// Big-endian readers (callers check bounds)
// ---------------------------------------------------------------------------

@(private)
be_u16 :: #force_inline proc(b: []u8, at: int) -> u16 {
	return u16(b[at]) << 8 | u16(b[at + 1])
}

@(private)
be_i16 :: #force_inline proc(b: []u8, at: int) -> i16 {
	return i16(be_u16(b, at))
}

@(private)
be_u32 :: #force_inline proc(b: []u8, at: int) -> u32 {
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

@(private)
f2dot14 :: #force_inline proc(b: []u8, at: int) -> f32 {
	return f32(be_i16(b, at)) / 16384
}
