package build

import "core:testing"

// The visual baselines' comparison on synthetic pictures: identical, one
// pixel off, and the same picture shifted by a pixel (a camera a little off),
// which must fail.

@(private = "file")
TEST_W :: 64
@(private = "file")
TEST_H :: 36

// test_picture: blocks of colour 4 pixels wide, as a voxel scene has, moved
// right by shift pixels.
@(private = "file")
test_picture :: proc(shift: int) -> []u8 {
	rgba := make([]u8, TEST_W * TEST_H * 4, context.temp_allocator)
	for y in 0 ..< TEST_H {
		for x in 0 ..< TEST_W {
			cell := (x - shift + TEST_W) / 4 + y / 4
			i := (y * TEST_W + x) * 4
			rgba[i] = u8(cell * 37)
			rgba[i + 1] = u8(cell * 91)
			rgba[i + 2] = u8(cell * 13)
			rgba[i + 3] = 255
		}
	}
	return rgba
}

@(test)
test_image_diff_identical :: proc(t: ^testing.T) {
	a := test_picture(0)
	d := image_diff(a, test_picture(0))
	testing.expect_value(t, d, Image_Diff{})
	testing.expect(t, image_passes(d))
}

@(test)
test_image_diff_one_pixel :: proc(t: ^testing.T) {
	a, b := test_picture(0), test_picture(0)
	// One pixel's red channel, by more than the tolerance.
	b[(10 * TEST_W + 20) * 4] ~= 0x80
	d := image_diff(a, b)
	pixels := f64(TEST_W * TEST_H)
	testing.expect_value(t, d.share, 1 / pixels)
	testing.expect_value(t, d.mean, 128 / (pixels * 3))
	// Within the tolerance, a pixel does not differ (its difference still counts in the mean).
	c := test_picture(0)
	c[(10 * TEST_W + 20) * 4 + 1] ~= IMAGE_TOLERANCE
	testing.expect_value(t, image_diff(a, c).share, 0)
	// The picture of the difference: that pixel red, the rest grey.
	pic := image_diff_picture(a, b, context.temp_allocator)
	i := (10 * TEST_W + 20) * 4
	testing.expect_value(
		t,
		[4]u8{pic[i], pic[i + 1], pic[i + 2], pic[i + 3]},
		[4]u8{255, 0, 0, 255},
	)
	testing.expect(t, pic[0] == pic[1] && pic[1] == pic[2])
}

@(test)
test_image_diff_shifted :: proc(t: ^testing.T) {
	d := image_diff(test_picture(0), test_picture(1))
	// Every block's edge column differs: a quarter of the pixels.
	testing.expect(t, d.share > 0.2, "a shifted picture differs at every edge")
	testing.expect(t, !image_passes(d))
}

@(test)
test_scenes_of :: proc(t: ^testing.T) {
	names := scenes_of(
		"# a comment\n\nnorth: look 0 0\n  cave : /tp 1 2 3; look 0 0\nnot a scene\n",
	)
	defer delete(names)
	testing.expect_value(t, len(names), 2)
	if len(names) == 2 {
		testing.expect_value(t, names[0], "north")
		testing.expect_value(t, names[1], "cave")
	}
}
