package main

import "core:math"
import "core:testing"

import "client:engine"
import "client:testkit"
import "common:game"

// The avatars' poses: derived from the speed and the sneak flag; the limbs'
// phase follows the ground covered, so it is continuous across a change of
// speed; a moving avatar never stands still, a still one always does.

WALK :: f32(4.317)
RUN :: f32(5.612)

@(private = "file")
pose :: proc(
	speed: f32,
	crouched: bool,
	phase: f32,
	hold := engine.Hold.None,
) -> engine.Avatar_Pose {
	return engine.avatar_pose(speed, crouched, phase, hold, WALK, RUN)
}

@(test)
test_avatar_pose_rest_walk_run_sneak :: proc(t: ^testing.T) {
	quarter := f32(math.PI / 2) // the sine at its peak
	rest := pose(0, false, quarter)
	testing.expect_value(t, rest.legs, [2]f32{})
	testing.expect_value(t, rest.arms, [2]f32{})
	testing.expect_value(t, rest.hip, 0.75)
	testing.expect_value(t, rest.neck_y, 1.4)

	walk := pose(WALK, false, quarter)
	run := pose(RUN, false, quarter)
	sneak := pose(1.31, true, quarter)
	// Arms swing against the legs, the legs against each other.
	for p in ([]engine.Avatar_Pose{walk, run, sneak}) {
		testing.expect_value(t, p.legs[0], -p.legs[1])
		testing.expect_value(t, p.arms[0], p.legs[1])
		testing.expect_value(t, p.arms[1], p.legs[0])
	}
	testing.expect_value(t, walk.legs[0], engine.AVATAR_WALK_SWING)
	testing.expect_value(t, run.legs[0], engine.AVATAR_RUN_SWING)
	testing.expect_value(t, sneak.legs[0], engine.AVATAR_SNEAK_SWING)
	// A shorter stride and a lower body when sneaking.
	testing.expect(t, sneak.legs[0] < walk.legs[0] && walk.legs[0] < run.legs[0])
	testing.expect_value(t, sneak.hip, 0.6)
	testing.expect_value(t, sneak.neck_y, 1.1)
	// Holding something: the right arm is raised, forward.
	held := pose(0, false, 0, .Item)
	testing.expect_value(t, held.arms[1], engine.AVATAR_RAISED)
	testing.expect_value(t, held.arms[0], 0)
	testing.expect(t, pose(WALK, false, 0, .Item).arms[1] > 0.9)
}

@(test)
test_avatar_never_glides :: proc(t: ^testing.T) {
	// A moving avatar's limbs are not at rest at any phase but the cycle's
	// crossings; over a cycle they reach the whole swing.
	for speed in ([]f32{engine.AVATAR_MOVING, 0.5, 1.31, WALK, RUN, 9}) {
		for crouched in ([]bool{false, true}) {
			most: f32
			for i in 0 ..< 64 {
				p := pose(speed, crouched, f32(i) / 64 * math.TAU)
				most = max(most, abs(p.legs[0]))
			}
			testing.expectf(
				t,
				most > 0.05,
				"speed %v crouched %v: legs at rest (%v)",
				speed,
				crouched,
				most,
			)
		}
	}
	// Below the threshold: still.
	testing.expect_value(t, pose(engine.AVATAR_MOVING / 2, false, 1).legs, [2]f32{})
}

@(test)
test_avatar_phase_is_continuous :: proc(t: ^testing.T) {
	// Walking, then running, then slowing: the phase only grows by the ground covered
	// (never jumps) and the legs' angle moves a little each frame, even
	// across the changes of speed (a crouch changes the stride's reach at once).
	phase: f32
	last := pose(WALK, false, 0).legs[0]
	biggest: f32
	for frame in 0 ..< 600 {
		// (the replicated speed changes within a few ticks, not at once)
		speed := WALK
		switch {
		case frame >= 400:
			speed = max(2.0, RUN - f32(frame - 400) * 0.05)
		case frame >= 200:
			speed = min(RUN, WALK + f32(frame - 200) * 0.05)
		}
		crouched := false
		before := phase
		phase = engine.avatar_pose_advance(phase, speed / 60, crouched)
		step := phase - before
		if step < 0 {step += math.TAU} 	// (the cycle wrapped)
		testing.expect(t, step < 0.5, "the phase jumped")
		now := pose(speed, crouched, phase).legs[0]
		// (the change of speed changes the reach: a step in the angle is
		// small, never a pop)
		biggest = max(biggest, abs(now - last))
		last = now
	}
	testing.expectf(t, biggest < 0.5, "the leg popped by %v radians in a frame", biggest)
}

@(test)
test_snapshot_speed_from_the_track :: proc(t: ^testing.T) {
	// Replicated positions give the speed: 0.2 blocks a tick is 4 blocks/s.
	o: engine.Other_Player
	for i in 0 ..< 5 {
		engine.other_snapshot(&o, u32(10 + i), game.Player_Motion{position = {f64(i) * 0.2, 0, 0}})
	}
	v, ok := engine.other_view(&o, 12.5)
	testing.expect(t, ok)
	testing.expect(t, abs(v.speed - 0.2 * game.TICK_RATE) < 0.001, "interpolated")
	v, _ = engine.other_view(&o, 99) // (the newest: still going)
	testing.expect(t, abs(v.speed - 0.2 * game.TICK_RATE) < 0.001, "at the end")
	// It stops: the held snapshots say so.
	engine.track_hold(&o.track, 15)
	engine.track_hold(&o.track, 16)
	v, _ = engine.other_view(&o, 99)
	testing.expect_value(t, v.speed, 0)
	// Vertical motion alone is not walking.
	o = {}
	engine.other_snapshot(&o, 1, game.Player_Motion{position = {0, 0, 0}})
	engine.other_snapshot(&o, 2, game.Player_Motion{position = {0, 5, 0}})
	v, _ = engine.other_view(&o, 99)
	testing.expect_value(t, v.speed, 0)
}

// The arm that holds something swings its hand to the front (-z, the way the
// avatar looks), a weapon's level; at rest it hangs (the raised
// arm pointing backwards).
@(test)
test_avatar_arm_raises_forward :: proc(t: ^testing.T) {
	tip :: proc(pitch: f32) -> [3]f32 {
		// The hand's end in the avatar's space about the shoulder, as the entity pass
		// turns a box: pitch about x.
		p := [3]f32{0, -0.65, 0}
		return {
			p.x,
			p.y * math.cos(pitch) - p.z * math.sin(pitch),
			p.y * math.sin(pitch) + p.z * math.cos(pitch),
		}
	}
	rest := tip(pose(0, false, 0).arms[1])
	testing.expect(t, rest.z == 0 && rest.y < -0.6, "at rest the arm hangs")
	item := tip(pose(0, false, 0, .Item).arms[1])
	testing.expect(t, item.z < -0.4, "a raised arm is in front of the shoulder")
	gun := tip(pose(0, false, 0, .Gun).arms[1])
	testing.expect(t, gun.z < item.z, "an aimed arm reaches further forward")
	testing.expect(t, abs(gun.y) < 0.1, "an aimed arm is level")
	moving := tip(pose(WALK, false, 1, .Gun).arms[1])
	testing.expect(t, moving.z < -0.6, "walking with a gun keeps it forward")
	reg := testkit.test_reg()
	named :: proc(reg: ^game.Registry, name: string) -> game.Item {
		i, _ := game.registry_item(reg, name)
		return i
	}
	testing.expect_value(t, engine.hold_of(reg, game.NO_ITEM), engine.Hold.None)
	testing.expect_value(t, engine.hold_of(reg, named(reg, "pistol")), engine.Hold.Gun)
	testing.expect_value(t, engine.hold_of(reg, named(reg, "sniper")), engine.Hold.Gun)
	testing.expect_value(t, engine.hold_of(reg, named(reg, "rocket_launcher")), engine.Hold.Gun)
	testing.expect_value(t, engine.hold_of(reg, named(reg, "stone")), engine.Hold.Item)
	testing.expect_value(t, engine.hold_of(reg, named(reg, "hoe")), engine.Hold.Item)
}

// The attack/use arc: the right arm arcs down and across over
// VM_SWING_SECONDS, the body turns into it; at either end the avatar is at
// rest (or mid walk). Driven by the same events the view model gets.
@(test)
test_avatar_swing_arc :: proc(t: ^testing.T) {
	// At rest before the swing: nothing.
	edge := engine.avatar_pose(0, false, 0, .None, WALK, RUN, 0, 0)
	testing.expect_value(t, edge.arms[1], 0)
	testing.expect_value(t, edge.body_turn, 0)
	// Mid-arc (half of the swing): the arm is well forward and down, the body turns.
	mid := engine.avatar_pose(0, false, 0, .None, WALK, RUN, engine.VM_SWING_SECONDS * 0.5, 0)
	testing.expect(t, mid.arms[1] > 1.1, "the arm arcs forward")
	testing.expect(t, mid.body_turn > 0.08, "the body turns into the swing")
	// The arc is a sinusoid: greatest in the middle, zero at both ends.
	early := engine.avatar_pose(0, false, 0, .None, WALK, RUN, engine.VM_SWING_SECONDS * 0.25, 0)
	late := engine.avatar_pose(0, false, 0, .None, WALK, RUN, engine.VM_SWING_SECONDS * 0.75, 0)
	testing.expect(t, early.arms[1] < mid.arms[1] && late.arms[1] < mid.arms[1])
	// Walking with a gun keeps it forward through the arc.
	mid_held := engine.avatar_pose(
		WALK,
		false,
		0,
		.Gun,
		WALK,
		RUN,
		engine.VM_SWING_SECONDS * 0.5,
		0,
	)
	testing.expect(t, mid_held.arms[1] > engine.AVATAR_AIMED)
	// By the end of the swing the arm is back.
	done := engine.avatar_pose(0, false, 0, .None, WALK, RUN, engine.VM_SWING_SECONDS, 0)
	testing.expect(t, abs(done.body_turn) < 1e-5)
	testing.expect(t, done.arms[1] < 1e-5)
}

// The legs swing against each other while walking; the arms counter the legs;
// the swing's arc stacks on top.
@(test)
test_avatar_swing_while_walking :: proc(t: ^testing.T) {
	phase := f32(1.3)
	pose := engine.avatar_pose(
		WALK,
		false,
		phase,
		.None,
		WALK,
		RUN,
		engine.VM_SWING_SECONDS * 0.5,
		0,
	)
	testing.expect_value(t, pose.legs[0], -pose.legs[1])
	testing.expect_value(t, pose.arms[0], pose.legs[1])
	// The right arm carries both the walk swing and the arc.
	walk := engine.avatar_pose(WALK, false, phase, .None, WALK, RUN, 0, 0)
	testing.expect(t, pose.arms[1] > walk.arms[1])
}
