package engine

import "core:testing"

// Frame dt was once frozen whenever the scene's phase was not .Done. That
// froze normal play (no scene: the starfield stood still) and every world
// scene (the held item's name never faded, so 18 baselines drew 28 triangles
// too many). Only a menu's scene stands still.
@(test)
test_scene_freezes_frame_dt :: proc(t: ^testing.T) {
	testing.expect(t, !scene_freezes_frame_dt(Scene_Run{}))
	for phase in Scene_Phase {
		testing.expect(t, !scene_freezes_frame_dt(Scene_Run{phase = phase}))
		testing.expect(t, scene_freezes_frame_dt(Scene_Run{phase = phase, menu = true}))
	}
}
