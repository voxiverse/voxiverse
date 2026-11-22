package texture

import "core:math"

import "common:base"

// The generators' toolkit: small pure procedures of a pixel, each the same
// for (x, y) and (x + SIZE, y) or (x, y + SIZE) and continuous across that
// edge, so what is made of them tiles without a seam (toolkit_test.odin).
//
// A material is a Ramp: three to five colours from its shadow to its light,
// picked by hand from what it looks like. Noise and patterns only say how
// light a pixel is; the ramp says what colour that is, so the pixels form
// clusters of a few tones (pixel art), not a smear of colours.

Ramp :: [5]Rgba

// pick: the ramp's colour for v in 0..1, the nearest of its steps.
pick :: proc(ramp: Ramp, v: f32) -> Rgba {
	return ramp[clamp(int(v * 5), 0, 4)]
}

// wrap: v in 0..<SIZE, as a texture that repeats sees it.
wrap :: proc(v: int) -> int {
	return ((v % SIZE) + SIZE) % SIZE
}

// hash01: a well-mixed hash of (seed, x, y) in 0..<1 (white noise: no
// structure, so on its own it reads as grit). Its 32-bit mixing is not
// base.hash: every texture and its baseline is made of it.
hash01 :: proc(seed: u32, x, y: int) -> f32 {
	h := seed ~ u32(x) * 0x27d4_eb2d ~ u32(y) * 0x1656_67b1
	h = (h ~ h >> 15) * 0x85eb_ca6b
	h = (h ~ h >> 13) * 0xc2b2_ae35
	h ~= h >> 16
	return base.unit_f32(h)
}

// noise: value noise in 0..1 with nx by ny points across the texture, eased
// between them; few across and many down makes grain along a board, many
// across and few down the furrows of bark.
noise :: proc(seed: u32, x, y: int, nx, ny: int) -> f32 {
	px := f32(wrap(x)) * f32(nx) / SIZE
	py := f32(wrap(y)) * f32(ny) / SIZE
	gx, gy := int(px), int(py)
	fx, fy := ease(px - f32(gx)), ease(py - f32(gy))
	at :: proc(seed: u32, gx, gy, nx, ny: int) -> f32 {return hash01(seed, gx % nx, gy % ny)}
	a := math.lerp(at(seed, gx, gy, nx, ny), at(seed, gx + 1, gy, nx, ny), fx)
	b := math.lerp(at(seed, gx, gy + 1, nx, ny), at(seed, gx + 1, gy + 1, nx, ny), fx)
	return math.lerp(a, b, fy)
}

// fbm: octaves of noise from n points across up, each twice as fine and half
// the weight of the one before, in 0..1: large patches with smaller ones in
// them, as rock and soil are.
fbm :: proc(seed: u32, x, y, n, octaves: int) -> f32 {
	sum, weight, total: f32 = 0, 1, 0
	points := n
	for o in 0 ..< octaves {
		sum += weight * noise(seed + u32(o) * 0x9e37_79b9, x, y, points, points)
		total += weight
		weight *= 0.5
		points = min(points * 2, SIZE)
	}
	return sum / total
}

// Cell: where a pixel lies among points scattered one to each square of a
// grid (cellular or Worley noise): stones, pebbles, clumps of ore.
Cell :: struct {
	id:     u32, // the nearest point's square, hashed: a stone's own number
	d1, d2: f32, // pixels to the nearest point and to the second nearest
	dx, dy: f32, // the pixel's offset from the nearest point
}

// cells: Cell of (x, y) for n by n points, each placed at random in its
// square of the texture, repeating with it. d2 - d1 is small along the line
// between two stones: their mortar.
cells :: proc(seed: u32, x, y, n: int) -> (c: Cell) {
	cell := f32(SIZE) / f32(n)
	px, py := f32(wrap(x)) + 0.5, f32(wrap(y)) + 0.5
	gx, gy := int(px / cell), int(py / cell)
	c.d1, c.d2 = max(f32), max(f32)
	for j in -2 ..= 2 {
		for i in -2 ..= 2 {
			sx, sy := gx + i, gy + j // a square, maybe past the edge: its point repeats there
			wx, wy := ((sx % n) + n) % n, ((sy % n) + n) % n
			ox := (f32(sx) + 0.15 + 0.7 * hash01(seed, wx, wy)) * cell
			oy := (f32(sy) + 0.15 + 0.7 * hash01(seed ~ 0x68e3_1da4, wx, wy)) * cell
			d := math.sqrt((px - ox) * (px - ox) + (py - oy) * (py - oy))
			if d < c.d1 {
				c.d2 = c.d1
				c.d1, c.dx, c.dy = d, px - ox, py - oy
				c.id = u32(wy * n + wx) * 0x9e37_79b9 ~ seed
			} else if d < c.d2 {
				c.d2 = d
			}
		}
	}
	return
}

// Brick: where a pixel lies in a w by h brick whose last column and row are
// the joint (mortar, or the gap between boards).
Brick :: struct {
	course, index: int, // its row of bricks, and its place along it
	u, v:          int, // the pixel within the brick, joint included
	joint:         bool,
}

// brick: Brick of (x, y) for courses h pixels high of bricks w pixels long
// (each dividing SIZE). A running bond shifts each course: pass x already
// shifted by the course's offset (course = wrap(y) / h).
brick :: proc(x, y, w, h: int) -> (b: Brick) {
	assert(SIZE % w == 0 && SIZE % h == 0)
	b.course = wrap(y) / h
	b.index = wrap(x) / w
	b.u, b.v = wrap(x) % w, wrap(y) % h
	b.joint = b.u == w - 1 || b.v == h - 1
	return
}

// bevel: the light on a w by h shape (its joint not counted) at (u, v), lit
// from the top left: 1 along its top and left edges, -1 along its bottom and
// right, 0 inside. A shape that catches light reads as standing out.
bevel :: proc(u, v, w, h: int) -> f32 {
	lit := f32(int(u == 0) + int(v == 0)) - f32(int(u == w - 1) + int(v == h - 1))
	return clamp(lit, -1, 1)
}

// ease: smoothstep, so noise has no creases at its grid points.
@(private = "file")
ease :: proc(t: f32) -> f32 {
	return t * t * (3 - 2 * t)
}
