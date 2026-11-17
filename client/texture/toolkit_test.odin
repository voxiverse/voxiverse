package texture

import "core:testing"

// Field: a toolkit procedure as a number per pixel, to check that it tiles.
@(private = "file")
Field :: #type proc(x, y: int) -> f32

// expect_tiles: f repeats every SIZE pixels each way, and the step across
// the edge (from the last column to the first, the last row to the first)
// is no larger than the largest step inside: the left and right edges
// continue each other, and so do the top and bottom.
@(private = "file")
expect_tiles :: proc(t: ^testing.T, name: string, f: Field) {
	inside: f32
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			v := f(x, y)
			if f(x + SIZE, y) != v || f(x, y + SIZE) != v || f(x - SIZE, y - SIZE) != v {
				testing.expectf(t, false, "%s does not repeat at (%d, %d)", name, x, y)
				return
			}
			if x + 1 < SIZE {inside = max(inside, abs(f(x + 1, y) - v))}
			if y + 1 < SIZE {inside = max(inside, abs(f(x, y + 1) - v))}
		}
	}
	for i in 0 ..< SIZE {
		across := max(abs(f(SIZE - 1, i) - f(0, i)), abs(f(i, SIZE - 1) - f(i, 0)))
		testing.expectf(
			t,
			across <= inside + 1e-4,
			"%s has a seam at %d: %v > %v",
			name,
			i,
			across,
			inside,
		)
	}
}

@(test)
test_noise_tiles :: proc(t: ^testing.T) {
	expect_tiles(t, "noise 4", proc(x, y: int) -> f32 {return noise(7, x, y, 4, 4)})
	expect_tiles(t, "noise 8x2", proc(x, y: int) -> f32 {return noise(7, x, y, 8, 2)})
	expect_tiles(t, "noise 16", proc(x, y: int) -> f32 {return noise(7, x, y, 16, 16)})
	expect_tiles(t, "fbm", proc(x, y: int) -> f32 {return fbm(9, x, y, 8, 3)})
	for x in 0 ..< SIZE {
		for y in 0 ..< SIZE {
			v := fbm(9, x, y, 8, 3)
			testing.expect(t, v >= 0 && v <= 1)
		}
	}
}

@(test)
test_cells_tile :: proc(t: ^testing.T) {
	expect_tiles(t, "cells d1", proc(x, y: int) -> f32 {return cells(3, x, y, 4).d1})
	expect_tiles(t, "cells d2 - d1", proc(x, y: int) -> f32 {
		c := cells(3, x, y, 8)
		return c.d2 - c.d1
	})
	// A stone is the same stone across the edge.
	for i in 0 ..< SIZE {
		testing.expect_value(t, cells(3, SIZE + i, 5, 4).id, cells(3, i, 5, 4).id)
		testing.expect_value(t, cells(3, 5, i - SIZE, 4).id, cells(3, 5, i, 4).id)
	}
	// Every point is nearer its own pixels than any other point is.
	c := cells(3, 6, 6, 4)
	testing.expect(t, c.d1 <= c.d2)
}

@(test)
test_bricks_tile :: proc(t: ^testing.T) {
	// A running bond of 8 x 4 bricks, each course shifted 4 more: the joints
	// meet across both edges.
	shifted :: proc(x, y: int) -> Brick {return brick(x + (wrap(y) / 4) * 4, y, 8, 4)}
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			a := shifted(x, y)
			testing.expect_value(t, shifted(x + SIZE, y), a)
			testing.expect_value(t, shifted(x, y + SIZE), a)
		}
	}
	b := brick(7, 3, 8, 4)
	testing.expect(t, b.joint)
	testing.expect_value(t, brick(9, 5, 8, 4), Brick{course = 1, index = 1, u = 1, v = 1})
}

@(test)
test_bevel_lights_the_top_left :: proc(t: ^testing.T) {
	testing.expect_value(t, bevel(0, 1, 7, 3), 1)
	testing.expect_value(t, bevel(3, 0, 7, 3), 1)
	testing.expect_value(t, bevel(6, 1, 7, 3), -1)
	testing.expect_value(t, bevel(3, 2, 7, 3), -1)
	testing.expect_value(t, bevel(3, 1, 7, 3), 0)
	testing.expect_value(t, bevel(6, 0, 7, 3), 0) // (the top right corner: lit and shaded)
}

@(test)
test_dither_mixes_two_steps :: proc(t: ^testing.T) {
	ramp := Ramp {
		{0, 0, 0, 255},
		{50, 0, 0, 255},
		{100, 0, 0, 255},
		{150, 0, 0, 255},
		{200, 0, 0, 255},
	}
	testing.expect_value(t, dither(ramp, 0, 3, 3), ramp[0])
	testing.expect_value(t, dither(ramp, 1, 3, 3), ramp[4])
	// A quarter of the way from step 1 to step 2: a quarter of a 4 x 4 block is step 2.
	counts: [5]int
	for y in 0 ..< 4 {
		for x in 0 ..< 4 {
			c := dither(ramp, 0.25 + 0.25 / 4, x, y)
			for s, i in ramp {if c == s {counts[i] += 1}}
		}
	}
	testing.expect_value(t, counts, [5]int{0, 12, 4, 0, 0})
	testing.expect_value(t, pick(ramp, 0.5), ramp[2])
}
