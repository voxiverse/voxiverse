package build

import "core:testing"
import "core:time"

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

// Scene counts: the parse, an exact count equal and changed, a toleranced
// count within and outside its tolerance, and a count on one side only.
@(test)
test_images_counts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	baseline, _, ok := images_counts_parse("world_meshes 120\nchunks_occluded 40 ~2\n")
	testing.expect(t, ok)
	testing.expect_value(t, len(baseline), 2)
	if len(baseline) == 2 {
		testing.expect_value(t, baseline[1], Count{"chunks_occluded", 40, 2})
	}
	same, _, _ := images_counts_parse("world_meshes 120\nchunks_occluded 40\n")
	testing.expect_value(t, len(images_counts_compare(baseline, same)), 0)
	changed, _, _ := images_counts_parse("world_meshes 121\nchunks_occluded 40\n")
	differ := images_counts_compare(baseline, changed)
	testing.expect_value(t, len(differ), 1)
	if len(differ) == 1 {testing.expect_value(t, differ[0], "world_meshes 121, the baseline 120")}
	within, _, _ := images_counts_parse("world_meshes 120\nchunks_occluded 38\n")
	testing.expect_value(t, len(images_counts_compare(baseline, within)), 0)
	outside, _, _ := images_counts_parse("world_meshes 120\nchunks_occluded 43\n")
	differ = images_counts_compare(baseline, outside)
	testing.expect_value(t, len(differ), 1)
	if len(differ) ==
	   1 {testing.expect_value(t, differ[0], "chunks_occluded 43, the baseline 40 ~2")}
	extra, _, _ := images_counts_parse("world_meshes 120\nchunks_occluded 40\ndraw_calls 9\n")
	testing.expect_value(t, len(images_counts_compare(baseline, extra)), 1)
	missing, _, _ := images_counts_parse("world_meshes 120\n")
	testing.expect_value(t, len(images_counts_compare(baseline, missing)), 1)
	for bad in ([]string{"world_meshes\n", "world_meshes x\n", "a 1 2\n", "a 1 ~-1\n", "a 1\na 2\n"}) {
		_, line, parsed := images_counts_parse(bad)
		testing.expect(t, !parsed, bad)
		testing.expect(t, line != "", bad)
	}
}

// The whole suite renders the image baselines too (they rotted while only a separate
// command ran them); a run narrowed to packages, an optimization, a sanitizer or some
// tests does not.
@(test)
test_the_whole_suite_renders_the_images :: proc(t: ^testing.T) {
	testing.expect(t, test_renders_images({}, {}))
	testing.expect(t, !test_renders_images({"server/core"}, {}))
	testing.expect(t, !test_renders_images({}, {optimization = "-o:speed"}))
	testing.expect(t, !test_renders_images({}, {sanitizer = "address"}))
	testing.expect(t, !test_renders_images({}, {names = {"test_x"}}))
}

// A scene's limit is ten times its last rendering, at least the floor: an Earth scene
// that once took 240 s among three others gets 40 minutes, a quick one the floor.
@(test)
test_images_limit :: proc(t: ^testing.T) {
	testing.expect_value(t, images_limit(0), IMAGE_SCENE_FLOOR)
	testing.expect_value(t, images_limit(12), IMAGE_SCENE_FLOOR)
	testing.expect_value(t, images_limit(240), 40 * time.Minute)
}
