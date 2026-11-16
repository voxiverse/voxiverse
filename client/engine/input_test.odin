package engine

import "core:testing"

import "client:platform"

// The pointer is the window's middle until it has moved over the window (a script under
// xvfb): it pans no free camera at an edge; once moved, it is where it was moved.
@(test)
test_pointer_starts_in_the_middle :: proc(t: ^testing.T) {
	input: Input_State
	defer input_destroy(&input)
	input_update(&input, {})
	input_pointer_middle(&input, {1280, 720})
	testing.expect_value(t, input.mouse, [2]f32{640, 360})
	input_update(&input, {platform.Mouse_Move_Event{3, 4}})
	input_pointer_middle(&input, {1280, 720})
	testing.expect_value(t, input.mouse, [2]f32{3, 4})
}
