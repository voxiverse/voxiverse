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
