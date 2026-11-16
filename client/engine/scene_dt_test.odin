package engine

import "common:game"
import "core:testing"

// Frame dt was once frozen whenever the scene's phase was not .Done. That
// froze normal play (no scene: the starfield stood still) and every world
// scene (the held item's name never faded, so 18 baselines drew 28 triangles
// too many). Then world scenes ran on measured frame times, and walk_third
// failed now and then: its avatar's breath (a sine of the time the frames had
// taken) put the arms elsewhere. A world scene's step is now 0 while its
// script runs and one tick a frame after it; only normal play measures.
@(test)
test_scene_frame_ms :: proc(t: ^testing.T) {
	testing.expect_value(t, scene_frame_ms(Scene_Run{}, 41), 41)
	testing.expect_value(t, scene_frame_ms(Scene_Run{phase = .Done}, 41), 41)
	testing.expect_value(t, scene_frame_ms(Scene_Run{phase = .Script}, 41), 0)
	for phase in ([]Scene_Phase{.Settling, .Clearing, .Shooting}) {
		testing.expect_value(t, scene_frame_ms(Scene_Run{phase = phase}, 41), SCENE_STEP_MS)
		testing.expect_value(t, scene_frame_ms(Scene_Run{phase = phase, menu = true}, 41), 0)
	}
	testing.expect_value(t, scene_frame_ms(Scene_Run{phase = .Script, menu = true}, 41), 0)
}

// The settling frames outlast the held item's name (the HUD's popup: held
// 1.5 s, then fading 0.5 s), and the session runs one tick for each.
@(test)
test_scene_settles_in_whole_ticks :: proc(t: ^testing.T) {
	testing.expect(t, f32(SCENE_SETTLE_FRAMES) * SCENE_STEP_MS / 1000 > 2)
	tick_time: f32
	ticks := 0
	for _ in 0 ..< SCENE_SETTLE_FRAMES {
		tick_time += SCENE_STEP_MS / 1000
		for tick_time >= game.TICK_SECONDS {
			tick_time -= game.TICK_SECONDS
			ticks += 1
		}
	}
	testing.expect_value(t, ticks, SCENE_SETTLE_FRAMES)
}
