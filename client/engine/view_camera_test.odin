package engine

import "core:math"
import "core:testing"

// A game's top-down camera: it hangs over the head looking down along its heading, the
// pointer's ray goes through what the frame shows under the pointer, and the movement
// keys move the avatar across the screen whichever way it faces.

@(test)
test_top_down_camera_hangs_over_the_head :: proc(t: ^testing.T) {
	eyes := [3]f64{10, 20, 30}
	v := camera_top_down(eyes, {kind = .Top_Down, distance = 12, angle = 60, heading = 0})
	d := v.position - eyes
	testing.expect(t, abs(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) - 12) < 1e-4)
	testing.expect(t, d.y > 10, "above the head")
	testing.expect(t, d.z > 5, "behind it: the heading looks down -z")
	testing.expect(t, abs(d.x) < 1e-4)
	testing.expect(t, abs(v.pitch + 60 * math.RAD_PER_DEG) < 1e-5)
}

@(test)
test_pointer_ray_goes_through_what_it_points_at :: proc(t: ^testing.T) {
	v := camera_top_down({4, 70, -9}, {kind = .Top_Down, distance = 14, angle = 55, heading = 1})
	view: Screen_View = {
		camera = camera_render(&v, 1280, 720, 70),
		size   = {1280, 720},
		set    = true,
	}
	// Points on the floor below, where the frame shows them.
	for p in ([][3]f64{{4, 68.4, -9}, {9.5, 68, -4}, {-2, 68, -14}}) {
		at, shown := screen_of(&view, p)
		if !testing.expect(t, shown) {continue}
		origin, dir, ok := pointer_ray(&view, at)
		if !testing.expect(t, ok) {continue}
		// The point lies on the ray: its distance from it is (almost) nothing.
		along := (p.x - origin.x) * dir.x + (p.y - origin.y) * dir.y + (p.z - origin.z) * dir.z
		off := p - (origin + dir * along)
		testing.expectf(
			t,
			along > 0 && math.sqrt(off.x * off.x + off.y * off.y + off.z * off.z) < 0.01,
			"%v: %v off the ray",
			p,
			off,
		)
	}
}

// screen_of: where p is in the view's window, in pixels (world_point's arithmetic).
@(private = "file")
screen_of :: proc(v: ^Screen_View, p: [3]f64) -> (at: [2]f32, ok: bool) {
	o := [3]f64{f64(v.camera.chunk.x * 16), f64(v.camera.chunk.y * 16), f64(v.camera.chunk.z * 16)}
	rel := p - o
	clip := v.camera.view_proj * [4]f32{f32(rel.x), f32(rel.y), f32(rel.z), 1}
	if clip.w <= 0.05 {return}
	return {(clip.x / clip.w * 0.5 + 0.5) * v.size.x, (clip.y / clip.w * 0.5 + 0.5) * v.size.y},
		true
}

@(test)
test_screen_move_follows_the_screen :: proc(t: ^testing.T) {
	near :: proc(a, b: [2]f32) -> bool {return abs(a.x - b.x) < 1e-5 && abs(a.y - b.y) < 1e-5}
	// Facing along the camera: the keys are the player's own.
	testing.expect(t, near(screen_move({0, 1}, 0, 0), {0, 1}))
	testing.expect(t, near(screen_move({1, 0}, 0.7, 0.7), {1, 0}))
	// Facing the camera (turned half round): up the screen is backwards.
	testing.expect(t, near(screen_move({0, 1}, 0, math.PI), {0, -1}))
	// Turned a quarter left: up the screen is to its right.
	testing.expect(t, near(screen_move({0, 1}, 0, math.PI / 2), {1, 0}))
	testing.expect(t, near(screen_move({1, 0}, 0, math.PI / 2), {0, -1}))
}
