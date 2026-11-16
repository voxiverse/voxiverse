package engine

import "core:math"
import "core:testing"

import "common:game"

// The free camera and the pointer's tools on a bare session: the wheel zooms within the
// game's limits, F5 turns a quarter, the keys and the edges pan along the screen (slower
// zoomed in), and a press over the UI starts no drag while one over the ground does,
// ending in a click or a drag.

@(test)
test_free_camera_zooms_turns_and_pans :: proc(t: ^testing.T) {
	s := new(Session)
	defer free(s)
	s.state = .Playing
	s.game_camera = {
		kind     = .Free,
		distance = 40,
		near     = 10,
		far      = 80,
		angle    = 50,
	}
	s.screen_view = {
		size = {1280, 720},
		set  = true,
	}
	input: Input_State
	actions: Actions
	input.mouse = {640, 360}
	free_camera_update(s, &input, &actions)
	testing.expect_value(t, s.free.distance, 40)
	input.wheel = {0, 40}
	free_camera_update(s, &input, &actions)
	testing.expect_value(t, s.free.distance, 10) // (as near as it goes)
	input.wheel = {0, -100}
	free_camera_update(s, &input, &actions)
	testing.expect_value(t, s.free.distance, 80)
	input.wheel = {}
	actions.pressed += {.Camera}
	free_camera_update(s, &input, &actions)
	testing.expect(t, abs(s.free.heading - math.PI / 2) < 1e-5, "F5 turns it a quarter")
	actions.pressed = {}
	// The keys pan at full speed zoomed out; the pointer at the left edge pans left.
	actions.move = {0, 1}
	free_camera_update(s, &input, &actions)
	testing.expect_value(t, s.free_move, [2]f32{0, 1})
	actions.move = {}
	input.mouse = {2, 360}
	free_camera_update(s, &input, &actions)
	testing.expect_value(t, s.free_move, [2]f32{-1, 0})
	// The input sent: along the camera's heading, nothing else.
	in_ := player_input(&actions, s)
	testing.expect_value(t, in_.yaw, s.free.heading)
	testing.expect_value(t, in_.move, [2]f32{-1, 0})
	// It looks at the focus from its distance, from above.
	s.feet = {5, 10, 5}
	v := camera_free_view(s)
	d := v.position - s.feet
	testing.expect(t, abs(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) - 80) < 1e-3)
	testing.expect(t, d.y > 50)
}

@(test)
test_pointer_tool_clicks_and_drags :: proc(t: ^testing.T) {
	s := new(Session)
	defer free(s)
	input: Input_State
	ground :: proc(s: ^Session, p: game.Block_Pos) {s.aim = game.Ray_Hit {
			block = p,
		}}
	// Over the UI: no press starts.
	s.pointer_over_ui = true
	ground(s, {1, 0, 1})
	input.mouse, input.mouse_pressed, input.mouse_down = {10, 10}, {.Left}, {.Left}
	pointer_tool_update(s, &input)
	testing.expect(t, !s.tool.buttons[.Primary].down)
	// Over the ground: a press, a drag to another block, a release: not a click.
	s.pointer_over_ui = false
	input.mouse_pressed, input.mouse_down = {.Left}, {.Left}
	pointer_tool_update(s, &input)
	b := &s.tool.buttons[.Primary]
	testing.expect(t, b.down && b.pressed)
	testing.expect_value(t, b.from, game.Block_Pos{1, 0, 1})
	input.mouse_pressed = {}
	input.mouse = {200, 10}
	ground(s, {7, 0, 1})
	pointer_tool_update(s, &input)
	testing.expect(t, b.down && !b.pressed)
	testing.expect_value(t, s.tool.ground, game.Block_Pos{7, 0, 1})
	input.mouse_down = {}
	pointer_tool_update(s, &input)
	testing.expect(t, b.released && !b.clicked && !b.down)
	// A press and release in place: a click.
	input.mouse_pressed, input.mouse_down = {.Right}, {.Right}
	pointer_tool_update(s, &input)
	input.mouse_pressed, input.mouse_down = {}, {}
	pointer_tool_update(s, &input)
	testing.expect(t, s.tool.buttons[.Secondary].clicked)
	lo, hi := block_rect({5, 1, -2}, {1, 3, 4})
	testing.expect_value(t, lo, game.Block_Pos{1, 1, -2})
	testing.expect_value(t, hi, game.Block_Pos{5, 3, 4})
}
