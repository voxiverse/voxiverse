package render

import "core:math"
import "core:testing"

@(private = "file")
project :: proc(m: matrix[4, 4]f32, p: [3]f32) -> [3]f32 {
	c := m * [4]f32{p.x, p.y, p.z, 1}
	return c.xyz / c.w
}

@(test)
test_projection_reverse_z :: proc(t: ^testing.T) {
	proj := perspective_reverse_z(math.PI / 2, 1, 0.1)
	near := project(proj, {0, 0, -0.1})
	testing.expect(t, abs(near.z - 1) < 1e-5, "near plane at depth 1")
	far := project(proj, {0, 0, -10_000})
	testing.expect(t, far.z > 0 && far.z < 1e-4, "far away approaches depth 0")
	testing.expect(
		t,
		project(proj, {0, 0, -5}).z > project(proj, {0, 0, -6}).z,
		"nearer is greater",
	)
	up := project(proj, {0, 1, -2})
	testing.expect(t, up.y < 0, "world up is clip -y (Vulkan)")
	right := project(proj, {1, 0, -2})
	testing.expect(t, right.x > 0)
}

@(test)
test_view_matrix_and_forward :: proc(t: ^testing.T) {
	for angles in ([][2]f32{{0, 0}, {math.PI / 2, 0}, {1, 0.5}, {-2, -1}}) {
		yaw, pitch := angles[0], angles[1]
		eye := [3]f32{3, 4, 5}
		v := view_matrix(eye, yaw, pitch)
		// A point ahead of the camera lands on -z in view space.
		ahead :=
			v *
			[4]f32 {
					eye.x + forward(yaw, pitch).x * 10,
					eye.y + forward(yaw, pitch).y * 10,
					eye.z + forward(yaw, pitch).z * 10,
					1,
				}
		testing.expectf(
			t,
			abs(ahead.x) < 1e-4 && abs(ahead.y) < 1e-4 && abs(ahead.z + 10) < 1e-4,
			"yaw %v pitch %v: %v",
			yaw,
			pitch,
			ahead,
		)
	}
	// Yaw turns left: at a quarter turn the camera looks down -x.
	f := forward(math.PI / 2, 0)
	testing.expect(t, abs(f.x + 1) < 1e-5 && abs(f.z) < 1e-5)
}

@(test)
test_frustum_culling :: proc(t: ^testing.T) {
	vp := perspective_reverse_z(math.PI / 2, 16.0 / 9, 0.1) * view_matrix({0, 0, 0}, 0, 0)
	planes := frustum_planes(vp)
	box :: proc(planes: ^Planes, lo: [3]f32) -> bool {return box_visible(planes, lo, lo + 16)}
	testing.expect(t, box(&planes, {-8, -8, -40}), "ahead")
	testing.expect(t, !box(&planes, {-8, -8, 30}), "behind")
	testing.expect(t, !box(&planes, {-500, -8, -40}), "far left")
	testing.expect(t, !box(&planes, {-8, 300, -40}), "far above")
	testing.expect(t, box(&planes, {-8, -8, -100_000}), "very far ahead (no far plane)")
	testing.expect(t, box(&planes, {-8, -8, -8}), "around the camera")
}

// The sky model: the sun rises in the east (+x), is highest at noon and
// sets in the west; nights are dark with stars; the glow belongs to
// sunrise and sunset; nothing jumps from one moment to the next.
@(test)
test_sky_through_a_day :: proc(t: ^testing.T) {
	sunrise, noon, sunset, midnight := sky_at(0.25), sky_at(0.5), sky_at(0.75), sky_at(0)
	testing.expect(t, abs(sunrise.sun.y) < 1e-5 && sunrise.sun.x > 0.99, "sun rises in the east")
	testing.expect(t, abs(sunset.sun.y) < 1e-5 && sunset.sun.x < -0.99, "sun sets in the west")
	testing.expect(t, noon.sun.y > 0.9 && midnight.sun.y < -0.9)
	testing.expect(
		t,
		noon.sun.y < 0.99,
		"the sun never passes overhead (the sky shader needs that)",
	)
	luma :: proc(c: [3]f32) -> f32 {return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b}
	testing.expect(t, luma(noon.sky_light) > 5 * luma(midnight.sky_light), "nights are dark")
	testing.expect(t, luma(midnight.sky_light) > 0.05, "but not black")
	testing.expect(t, midnight.stars > 0.99 && noon.stars == 0)
	testing.expect(t, sunset.glow_k > 0.5 && sunrise.glow_k > 0.5 && noon.glow_k < 0.01)
	testing.expect(t, midnight.glow_k < 0.01)

	// Continuity: a second of a 20-minute day changes little (dawn, the
	// fastest change, takes about a minute).
	step :: 1.0 / 1200.0
	previous := sky_at(0)
	for i in 1 ..= 1200 {
		s := sky_at(f64(i) * step)
		for k in 0 ..< 3 {
			testing.expectf(
				t,
				abs(s.sky_light[k] - previous.sky_light[k]) < 0.03,
				"light jumps at %d",
				i,
			)
			testing.expectf(
				t,
				abs(s.horizon[k] - previous.horizon[k]) < 0.03,
				"horizon jumps at %d",
				i,
			)
		}
		previous = s
	}
}

// scene.glsl's Scene: two mat4, sixteen vec4, an ivec4, the cloud map's address (std430).
#assert(size_of(Scene) == 2 * 64 + 17 * 16 + 16)
#assert(offset_of(Scene, camera) == 128)
#assert(offset_of(Scene, water) == 272)
#assert(offset_of(Scene, lamp) == 288)
#assert(offset_of(Scene, grade_more) == 352)
#assert(offset_of(Scene, gate) == 368)
#assert(offset_of(Scene, camera_chunk) == 384)
#assert(offset_of(Scene, cloud_map) == 400)

// world.glsl's push constants and chunk draw records.
#assert(offset_of(World_Push, textures) == 8)
#assert(offset_of(World_Push, time) == 16)
#assert(size_of(Chunk_Draw) == 16)

// world_cull.comp's records (std430: an ivec3 and a uint, a uint, 14 uints,
// padding to the ivec3's 16), its push constants and statistics.
#assert(size_of(Cull_Record) == 80)
#assert(offset_of(Cull_Record, counts) == 20)
#assert(offset_of(Cull_Push, count) == 32)
#assert(size_of(Cull_Stats) == 16)

// The cloud map: blobs, not noise; it tiles; some sky stays clear.
@(test)
test_cloud_map :: proc(t: ^testing.T) {
	m := new(Cloud_Map)
	defer free(m)
	cloud_map_generate(m)
	cloudy, neighbours_alike := 0, 0
	for y in 0 ..< CLOUD_MAP_SIZE {
		for x in 0 ..< CLOUD_MAP_SIZE {
			c := cloud_map_get(m, x, y)
			if c {cloudy += 1}
			if c == cloud_map_get(m, x + 1, y) {neighbours_alike += 1}
		}
	}
	cells := CLOUD_MAP_SIZE * CLOUD_MAP_SIZE
	testing.expectf(t, cloudy > cells / 6 && cloudy < cells / 2, "cover %d of %d", cloudy, cells)
	testing.expectf(
		t,
		neighbours_alike > cells * 8 / 10,
		"only %d of %d neighbours alike: noise, not blobs",
		neighbours_alike,
		cells,
	)
	testing.expect(
		t,
		cloud_map_get(m, -1, 5) == cloud_map_get(m, CLOUD_MAP_SIZE - 1, 5),
		"it repeats",
	)
}

// The weather's cover closes the clouds into a sheet: every cell cloud in fair weather
// stays cloud, and every cell is cloud at a whole cover.
@(test)
test_cloud_cover :: proc(t: ^testing.T) {
	m := new(Cloud_Map)
	defer free(m)
	cloud_map_generate(m)
	fair, overcast, lost := 0, 0, 0
	for y in 0 ..< CLOUD_MAP_SIZE {
		for x in 0 ..< CLOUD_MAP_SIZE {
			a := cloud_map_get(m, x, y)
			b := cloud_map_get(m, x, y, cloud_threshold(1))
			if a {fair += 1}
			if b {overcast += 1}
			if a && !cloud_map_get(m, x, y, cloud_threshold(0.5)) {lost += 1}
		}
	}
	cells := CLOUD_MAP_SIZE * CLOUD_MAP_SIZE
	testing.expect_value(t, lost, 0)
	testing.expect_value(t, cloud_threshold(0), CLOUD_CLEAR)
	testing.expectf(t, overcast == cells, "overcast covers %d of %d", overcast, cells)
	testing.expect(t, overcast > fair)
}

// No weather leaves the sky as it was; cloud darkens it and hides the stars and the
// glow; mist brings the fog in; a flash lights it.
@(test)
test_sky_weathered :: proc(t: ^testing.T) {
	for f in ([]f64{0, 0.25, 0.5, 0.74}) {
		sky := sky_at(f)
		testing.expect_value(t, sky_weathered(sky, {}), sky)
		grey := sky_weathered(sky, {cover = 1, rain = 1, storm = 1})
		testing.expect(t, grey.sky_light.g < sky.sky_light.g && grey.stars <= sky.stars * 0.01)
		testing.expect(t, grey.glow_k < sky.glow_k * 0.2 || sky.glow_k == 0)
		testing.expect_value(t, grey.cover, 1)
		lit := sky_weathered(sky, {cover = 1, flash = 1})
		testing.expect(t, lit.sky_light.b > grey.sky_light.b + 0.5)
	}
	misty := sky_weathered(sky_at(0.27), {fog = 1})
	camera: Camera
	clear_scene := scene_make(camera, sky_at(0.27), 192, 0)
	misty_scene := scene_make(camera, misty, 192, 0)
	testing.expect(t, misty_scene.zenith.w <= MIST_FOG + 0.01 && clear_scene.zenith.w == 192)
	testing.expect_value(t, clear_scene.cloud_origin.y, CLOUD_CLEAR)
	testing.expect_value(t, clear_scene.axis.w, 0)
	overcast_scene := scene_make(camera, sky_weathered(sky_at(0.5), {cover = 1}), 192, 0)
	testing.expect(
		t,
		overcast_scene.axis.w == 1 && overcast_scene.cloud_origin.y == CLOUD_OVERCAST,
	)
}

// sort_keys orders by the high 32 bits (distances' bits), equal ones kept
// in order, as a comparison sort would.
@(test)
test_sort_keys :: proc(t: ^testing.T) {
	distances := []f32{9, 0.5, 300, 9, 0, 1e6, 0.25, 9}
	keys := make([]u64, len(distances))
	defer delete(keys)
	for d, i in distances {keys[i] = u64(transmute(u32)d) << 32 | u64(i)}
	scratch := make([dynamic]u64)
	defer delete(scratch)
	sort_keys(keys, &scratch)
	want := []u32{4, 6, 1, 0, 3, 7, 2, 5}
	for k, i in keys {
		testing.expectf(t, u32(k) == want[i], "place %d: index %d, want %d", i, u32(k), want[i])
	}
	// Keys whose high bytes are all the same (the passes they skip).
	near := []f32{2.5, 2.25, 2.75, 2.25}
	for d, i in near {keys[i] = u64(transmute(u32)d) << 32 | u64(i)}
	sort_keys(keys[:len(near)], &scratch)
	want_near := []u32{1, 3, 0, 2}
	for k, i in keys[:len(near)] {
		testing.expectf(
			t,
			u32(k) == want_near[i],
			"near place %d: index %d, want %d",
			i,
			u32(k),
			want_near[i],
		)
	}
}

// Wherever the camera is along each axis (below a chunk, within it, above
// it), a layer's visible face groups make at most CULL_RUNS runs, and the
// runs cover the visible groups' vertices and, when they would be three
// runs, the smaller gap's, in order.
@(test)
test_runs_of_visible_face_groups :: proc(t: ^testing.T) {
	counts := [FACE_GROUPS]u32{4, 8, 12, 16, 20, 24, 28}
	SIDES :: [3]f32{-5, 8, 21} // the chunk's box is 0 to 16
	for x in SIDES {
		for y in SIDES {
			for z in SIDES {
				faces := facing({0, 0, 0}, {x, y, z})
				runs := face_runs(faces, counts[:], 100) // (more than CULL_RUNS: out of bounds)
				want, got: u32
				drawn := bridged(faces, counts[:])
				testing.expect(t, drawn & faces == faces)
				for n, g in counts {if drawn & (1 << u8(g)) != 0 {want += n}}
				for r in runs {got += r.count}
				testing.expectf(
					t,
					got == want,
					"eye %v: runs %v cover %d vertices, not %d",
					[3]f32{x, y, z},
					runs,
					got,
					want,
				)
			}
		}
	}
	// The most there can be: +x, +z and the both-ways group, then -y: the gap of
	// +y (8 vertices) is drawn, not -z's (20).
	runs := face_runs(0b0101101, counts[:], 0)
	testing.expect_value(t, runs, [CULL_RUNS]Run{{0, 40}, {60, 24}})
	testing.expect_value(t, bridged(0b0101101, counts[:]), 0b0101111)
	// Two runs, or one, are left as they are.
	testing.expect_value(t, bridged(0b1101111, counts[:]), 0b1101111)
	testing.expect_value(t, bridged(0b0001111, counts[:]), 0b0001111)
	testing.expect_value(t, bridged(0, counts[:]), 0)
}

// cull_reference (what the GPU's culling is checked against, `--check
// cull`): a chunk out of view draws nothing; one in view draws its runs.
@(test)
test_cull_reference :: proc(t: ^testing.T) {
	vp := perspective_reverse_z(math.PI / 2, 16.0 / 9, 0.1) * view_matrix({8, 8, 8}, 0, 0)
	planes := frustum_planes(vp)
	r := Cull_Record {
		slot         = 9,
		first_vertex = 1000,
	}
	for &c in r.counts {c = 4}
	r.chunk = {0, 0, -3} // ahead (the camera looks down -z)
	commands, stats, in_view := cull_reference(r, &planes, {8, 8, 8}, {0, 0, 0})
	testing.expect(t, in_view)
	testing.expect_value(t, stats, Cull_Stats{drawn = 1, triangles = 2 * 12, commands = 4})
	// The camera is within the chunk's x and y and past its +z side: every
	// group but -z faces it, two runs a layer (+x +y +z both, -y -x).
	testing.expect_value(
		t,
		commands,
		[CULL_LAYERS * CULL_RUNS]Cull_Command {
			{24, 1, 0, 1000, 9},
			{12, 1, 0, 1020, 9},
			{24, 1, 0, 1028, 9},
			{12, 1, 0, 1048, 9},
		},
	)
	r.chunk = {0, 0, 3} // behind
	commands, stats, in_view = cull_reference(r, &planes, {8, 8, 8}, {0, 0, 0})
	testing.expect(t, !in_view)
	testing.expect_value(t, stats, Cull_Stats{})
	testing.expect_value(t, commands, [CULL_LAYERS * CULL_RUNS]Cull_Command{})
}

// A camera's cut reaches the scene the world's vertex shader reads (its clip distance:
// nothing at that y or above); with none, the cut is far above anything there is.
@(test)
test_scene_carries_the_cut :: proc(t: ^testing.T) {
	sky := sky_at(0.5)
	cut := scene_make({chunk = {0, 2, 0}, cut = 37}, sky, 100, 0)
	testing.expect_value(t, cut.camera_chunk.w, 37)
	whole := scene_make({chunk = {0, 2, 0}}, sky, 100, 0)
	testing.expect_value(t, whole.camera_chunk.w, NO_CUT)
	testing.expect(t, NO_CUT > 256 + 16, "above the world's top")
}
