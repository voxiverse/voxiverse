package render

import "core:fmt"
import "core:math"
import "core:testing"

import "common:base"

// The depth pyramid's CPU side (hiz.odin): its sizes and footprints, the
// reference pyramid, and the occlusion test's rules, ending with the
// property every culling decision rests on: a box with a pixel nearer than
// the depth buffer is never called occluded.

@(test)
test_hiz_sizes :: proc(t: ^testing.T) {
	Case :: struct {
		depth, size: [2]u32,
		mips:        u32,
	}
	cases := [?]Case {
		{{1, 1}, {1, 1}, 1},
		{{3, 2}, {2, 2}, 2},
		{{640, 360}, {512, 256}, 10},
		{{1280, 720}, {1024, 512}, 11},
		{{1366, 768}, {1024, 512}, 11},
		{{2560, 1440}, {2048, 1024}, 12},
		{{7680, 4320}, {4096, 4096}, 13},
	}
	for c in cases {
		size, mips := hiz_sizes(c.depth)
		testing.expectf(
			t,
			size == c.size && mips == c.mips,
			"%v: %v %d levels, not %v %d",
			c.depth,
			size,
			mips,
			c.size,
			c.mips,
		)
		testing.expect_value(t, hiz_mip_size(size, mips - 1), [2]u32{1, 1})
		// Level 0's footprints cover every depth texel, none outside.
		for axis in 0 ..< 2 {
			covered := make([]int, c.depth[axis], context.temp_allocator)
			for x in 0 ..< size[axis] {
				lo, hi := hiz_footprint(x, c.depth[axis], size[axis])
				testing.expectf(
					t,
					lo < hi && hi <= c.depth[axis],
					"%v axis %d texel %d: [%d, %d)",
					c.depth,
					axis,
					x,
					lo,
					hi,
				)
				// hiz.comp reads at most 3 texels a footprint each way.
				testing.expectf(
					t,
					hi - lo <= 3,
					"%v axis %d texel %d: [%d, %d) over 3 wide",
					c.depth,
					axis,
					x,
					lo,
					hi,
				)
				for d in lo ..< min(hi, c.depth[axis]) {covered[d] += 1}
			}
			for n, d in covered {
				testing.expectf(
					t,
					n >= 1,
					"%v axis %d: depth texel %d in no footprint",
					c.depth,
					axis,
					d,
				)
			}
		}
	}
}

@(test)
test_hiz_reference_is_the_minimum :: proc(t: ^testing.T) {
	// 8 x 4: four levels, each texel the minimum of the 2 x 2 above it.
	depth := [?]f32 {
		0.5,
		0.9,
		0.3,
		0.8,
		0.7,
		0.6,
		0.2,
		0.4,
		0.6,
		0.1,
		0.9,
		0.9,
		0.8,
		0.5,
		0.3,
		0.3,
		0.2,
		0.4,
		0.7,
		0.6,
		0.9,
		0.9,
		0.35,
		0.5,
		0.3,
		0.8,
		0.5,
		0.4,
		0.6,
		0.7,
		0.8,
		0.9,
	}
	r := hiz_reference(depth[:], {8, 4}, context.temp_allocator)
	testing.expect_value(t, r.size, [2]u32{8, 4})
	testing.expect_value(t, r.mips, 4)
	testing.expect(t, slice_equal(r.levels[0], depth[:]), "level 0 is the depth itself")
	testing.expect(
		t,
		slice_equal(r.levels[1], {0.1, 0.3, 0.5, 0.2, 0.2, 0.4, 0.6, 0.35}),
		fmt.tprint(r.levels[1]),
	)
	testing.expect(t, slice_equal(r.levels[2], {0.1, 0.2}), fmt.tprint(r.levels[2]))
	testing.expect(t, slice_equal(r.levels[3], {0.1}), fmt.tprint(r.levels[3]))

	// 3 x 2 into 2 x 2: the middle column is in both footprints.
	uneven := [?]f32{0.5, 0.2, 0.9, 0.4, 0.8, 0.3}
	u := hiz_reference(uneven[:], {3, 2}, context.temp_allocator)
	testing.expect_value(t, u.size, [2]u32{2, 2})
	testing.expect(t, slice_equal(u.levels[0], {0.2, 0.2, 0.4, 0.3}), fmt.tprint(u.levels[0]))
	testing.expect(t, slice_equal(u.levels[1], {0.2}), fmt.tprint(u.levels[1]))
}

@(private = "file")
slice_equal :: proc(a, b: []f32) -> bool {
	if len(a) != len(b) {return false}
	for x, i in a {if x != b[i] {return false}}
	return true
}

// A camera at the origin looking down -z, a 64 x 36 depth buffer.
@(private = "file")
TEST_CAMERA :: Raster_Camera {
	fov    = math.PI / 2.5,
	aspect = 64.0 / 36,
	near   = 0.1,
}
@(private = "file")
TEST_SIZE :: [2]u32{64, 36}

@(private = "file")
pyramid_of :: proc(boxes: []Raster_Box) -> Hiz_Reference {
	depth := make([]f32, TEST_SIZE.x * TEST_SIZE.y, context.temp_allocator)
	hiz_raster(depth, TEST_SIZE, TEST_CAMERA, boxes)
	return hiz_reference(depth, TEST_SIZE, context.temp_allocator)
}

@(test)
test_occlusion_reference_cases :: proc(t: ^testing.T) {
	view_proj := raster_view_proj(TEST_CAMERA)
	occluded :: proc(view_proj: matrix[4, 4]f32, b: Raster_Box, hiz: ^Hiz_Reference) -> bool {
		return occlusion_reference(view_proj, b.lo, b.hi, hiz).occluded
	}
	// A wall 6 wide at 10 to 11 in front.
	wall := pyramid_of({{{-3, -3, -11}, {3, 3, -10}}})
	testing.expect(
		t,
		occluded(view_proj, {{-1, -1, -30}, {1, 1, -28}}, &wall),
		"a box behind the wall",
	)
	testing.expect(
		t,
		!occluded(view_proj, {{20, -1, -30}, {22, 1, -28}}, &wall),
		"the box beside the wall",
	)
	testing.expect(
		t,
		!occluded(view_proj, {{-1, -1, -0.5}, {1, 1, 0.5}}, &wall),
		"a box across the near plane",
	)
	testing.expect(
		t,
		!occluded(view_proj, {{-0.5, -0.5, -12}, {0.5, 0.5, -10}}, &wall),
		"a box at the wall's depth",
	)
	// A wall over the whole screen; boxes larger than it, at the coarsest level.
	screen := pyramid_of({{{-100, -100, -11}, {100, 100, -10}}})
	testing.expect(
		t,
		occluded(view_proj, {{-200, -200, -60}, {200, 200, -50}}, &screen),
		"a box larger than the screen, behind",
	)
	testing.expect(
		t,
		!occluded(view_proj, {{-200, -200, -9}, {200, 200, -5}}, &screen),
		"a box larger than the screen, in front",
	)
	testing.expect(
		t,
		!occluded(view_proj, {{-200, -200, -60}, {200, 200, -50}}, &wall),
		"a box larger than the screen, behind the small wall",
	)
}

// test_occlusion_is_conservative: 500 random scenes (a random depth buffer
// size, 1 to 40 occluding boxes, a random camera), each with 200 random
// boxes: every box with a pixel nearer than the depth buffer there (the
// raster's own rule) must not be called occluded. A maximum reduction, a
// level one too fine or a footprint missing a texel each fail it.
@(test)
test_occlusion_is_conservative :: proc(t: ^testing.T) {
	r := base.rng_make(87)
	SCENES :: 500
	BOXES :: 200
	visible_count, occluded_count, wrong := 0, 0, 0
	for scene in 0 ..< SCENES {
		size := [2]u32{u32(base.rng_int_range(&r, 16, 321)), u32(base.rng_int_range(&r, 9, 181))}
		c := Raster_Camera {
			eye    = {
				base.rng_f32_range(&r, -20, 20),
				base.rng_f32_range(&r, -20, 20),
				base.rng_f32_range(&r, -20, 20),
			},
			yaw    = base.rng_f32_range(&r, -math.PI, math.PI),
			pitch  = base.rng_f32_range(&r, -1.4, 1.4),
			fov    = base.rng_f32_range(&r, 0.6, 1.8),
			aspect = f32(size.x) / f32(size.y),
			near   = 0.1,
		}
		occluders := make([dynamic]Raster_Box, context.temp_allocator)
		n := base.rng_int_range(&r, 1, 41)
		for len(occluders) < n {
			b := random_box(&r, c, 2, 40, 0.5, 20)
			if !box_near_eye(c, b, 0.5) {append(&occluders, b)}
		}
		depth := make([]f32, size.x * size.y, context.temp_allocator)
		hiz_raster(depth, size, c, occluders[:])
		hiz := hiz_reference(depth, size, context.temp_allocator)
		view_proj := raster_view_proj(c)
		for _ in 0 ..< BOXES {
			b := random_box(&r, c, 0.2, 80, 0.05, 8, 1.8)
			v := occlusion_reference(view_proj, b.lo, b.hi, &hiz)
			if v.occluded {occluded_count += 1}
			if !box_visible_in(depth, size, c, b) {continue}
			visible_count += 1
			if v.occluded {
				if wrong < 5 {
					testing.expectf(
						t,
						false,
						"scene %d (%v, %v): box %v is visible and was called occluded",
						scene,
						size,
						c,
						b,
					)
				}
				wrong += 1
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, wrong == 0, "%d visible boxes called occluded", wrong)
	// Not a test unless both kinds are common.
	total := SCENES * BOXES
	testing.expectf(
		t,
		occluded_count >= total / 10,
		"only %d of %d boxes occluded",
		occluded_count,
		total,
	)
	testing.expectf(
		t,
		visible_count >= total / 10,
		"only %d of %d boxes visible",
		visible_count,
		total,
	)
}
