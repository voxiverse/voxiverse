package engine

import "core:testing"

// Inkling froze last_frame_ms whenever phase != .Done, which includes .Off
// (normal play) and killed the starfield. Only a running scene freezes dt.
@(test)
test_scene_freezes_frame_dt :: proc(t: ^testing.T) {
	testing.expect(t, !scene_freezes_frame_dt(.Off))
	testing.expect(t, !scene_freezes_frame_dt(.Done))
	testing.expect(t, scene_freezes_frame_dt(.Script))
	testing.expect(t, scene_freezes_frame_dt(.Clearing))
	testing.expect(t, scene_freezes_frame_dt(.Shooting))
}
