package ui

import "core:math"

import "../font"

// The game's icon, drawn by code like every other asset: a dark cube in
// oblique three-quarter view with a white question mark on its front, on a
// transparent ground. Shared by the build (the executable's icon, the
// package's picture) and the game (the window's icon), so the code is here.
// Drawn at the size asked, never scaled from another: 4 x 4 samples a pixel
// for clean edges. Not quantized: it is a window icon, not a texture.

ICON_TOP :: [3]u8{0x2A, 0x2A, 0x2E}
ICON_FRONT :: [3]u8{0x1A, 0x1A, 0x1D}
ICON_RIGHT :: [3]u8{0x0E, 0x0E, 0x10}

// Where the faces are, in units of the icon's size (the front a
// square; the top and right the front's edges moved up and right).
ICON_FRONT_MIN :: [2]f32{0.10, 0.28}
ICON_FRONT_MAX :: [2]f32{0.72, 0.90}
ICON_DEPTH :: [2]f32{0.18, -0.18}

// app_icon: size x size pixels, RGBA, straight alpha.
app_icon :: proc(f: ^font.Font, size: int, allocator := context.allocator) -> []u8 {
	pixels := make([]u8, size * size * 4, allocator)
	s := f32(size)
	lo, hi := ICON_FRONT_MIN, ICON_FRONT_MAX
	// Which face a point (units of size) is on: 1 front, 2 top, 3 right, 0 none.
	face :: proc(p: [2]f32) -> int {
		lo, hi, d := ICON_FRONT_MIN, ICON_FRONT_MAX, ICON_DEPTH
		if p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y {return 1}
		// Top: above the front's top edge, shifted right by how far up it is.
		up := lo.y - p.y
		if up > 0 && up <= -d.y {
			shift := up * d.x / -d.y
			if p.x >= lo.x + shift && p.x < hi.x + shift {return 2}
		}
		// Right: right of the front's right edge, shifted up by how far right.
		out := p.x - hi.x
		if out >= 0 && out <= d.x {
			shift := out * -d.y / d.x
			if p.y >= lo.y - shift && p.y < hi.y - shift {return 3}
		}
		return 0
	}
	colors := [4][3]u8{{}, ICON_FRONT, ICON_TOP, ICON_RIGHT}
	N :: 4
	for y in 0 ..< size {
		for x in 0 ..< size {
			sum: [3]f32
			covered: f32
			for sy in 0 ..< N {
				for sx in 0 ..< N {
					p := [2]f32 {
						(f32(x) + (f32(sx) + 0.5) / N) / s,
						(f32(y) + (f32(sy) + 0.5) / N) / s,
					}
					c := face(p)
					if c == 0 {continue}
					covered += 1
					for k in 0 ..< 3 {sum[k] += f32(colors[c][k])}
				}
			}
			if covered == 0 {continue}
			out := pixels[(x + y * size) * 4:][:4]
			for k in 0 ..< 3 {out[k] = u8(math.round(sum[k] / covered))}
			out[3] = u8(math.round(255 * covered / (N * N)))
		}
	}

	// The question mark: white, centred on the front by the bounds of its
	// outline, composited over what is there.
	front_h := (hi.y - lo.y) * s
	g := font.glyph_index(f, '?')
	bm, ok := font.rasterize(f, g, font.scale_for_size(f, 0.62 * front_h), context.temp_allocator)
	if !ok || bm.width == 0 {return pixels}
	cx := math.round((lo.x + hi.x) / 2 * s - f32(bm.width) / 2)
	cy := math.round((lo.y + hi.y) / 2 * s - f32(bm.height) / 2)
	for by in 0 ..< bm.height {
		for bx in 0 ..< bm.width {
			a := f32(bm.pixels[bx + by * bm.width]) / 255
			px, py := int(cx) + bx, int(cy) + by
			if a == 0 || px < 0 || py < 0 || px >= size || py >= size {continue}
			dst := pixels[(px + py * size) * 4:][:4]
			da := f32(dst[3]) / 255
			oa := a + da * (1 - a)
			for k in 0 ..< 3 {
				dst[k] = u8(math.round((255 * a + f32(dst[k]) * da * (1 - a)) / oa))
			}
			dst[3] = u8(math.round(255 * oa))
		}
	}
	return pixels
}
