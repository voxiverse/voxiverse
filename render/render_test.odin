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

// scene.glsl's Scene: two mat4, nine vec4, the cloud map's address (std430).
#assert(size_of(Scene) == 2 * 64 + 9 * 16 + 16)
#assert(offset_of(Scene, camera) == 128)
#assert(offset_of(Scene, cloud_map) == 272)

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
