package client

import "core:math"

import "../common/game"
import "render"

// The camera's modes and comforts (docs/plan.md M48e): F5 cycles first person, third person behind and third person
// facing you; third person pulls in against walls; sprinting widens the field
// of view a little; walking bobs the first-person view. The View the
// session keeps (s.camera) stays the eyes: this makes the View the renderer
// draws (s.view) from it every frame.

Camera_Mode :: enum u8 {
	First,
	Third_Behind,
	Third_Facing,
}

THIRD_DISTANCE :: 4.0 // blocks from the head
THIRD_MARGIN :: 0.2 // blocks kept between the camera and a block it pulled in against
THIRD_EASE_SECONDS :: 0.2 // to come back out after a pull-in
SPRINT_FOV_KICK :: 0.08 // the field of view widens by this much while sprinting
SPRINT_FOV_SECONDS :: 0.15 // ... over this long (and back)
BOB_HEIGHT :: 0.03 // blocks
BOB_ROLL :: 0.3 * math.RAD_PER_DEG
BOB_PER_BLOCK :: 1.8 // radians of the sway's phase for each block walked

camera_mode_next :: proc(m: Camera_Mode) -> Camera_Mode {
	return Camera_Mode((int(m) + 1) % len(Camera_Mode))
}

// camera_third_person: where the camera is in a third person mode: the
// head's eyes, behind or in front by `distance`, pulled in to the first
// block in the way (with the margin) so it is never inside one. Facing
// you looks back at the head: the yaw turned half a circle, the pitch
// mirrored. The distance returned is the one used.
camera_third_person :: proc(
	query: game.Block_Query,
	eyes: [3]f64,
	yaw, pitch: f32,
	mode: Camera_Mode,
	distance: f64,
) -> (
	view: View,
	used: f64,
) {
	f := render.forward(yaw, pitch)
	dir := [3]f64{f64(f.x), f64(f.y), f64(f.z)}
	if mode == .Third_Behind {dir = -dir}
	used = distance
	if hit, ok := game.raycast(query, eyes, dir, distance + THIRD_MARGIN); ok {
		used = max(hit.distance - THIRD_MARGIN, 0)
	}
	view.position = eyes + dir * used
	view.yaw, view.pitch = yaw, pitch
	if mode == .Third_Facing {
		view.yaw = math.mod(yaw + math.PI, math.TAU)
		view.pitch = -pitch
	}
	return
}

// camera_update makes s.view from s.camera for this frame (session_update,
// after the eyes are placed): the mode, the pull-in, the bobbing, the
// sprint's widening.
camera_update :: proc(
	s: ^Session,
	actions: ^Actions,
	settings: Settings,
	query: game.Block_Query,
	dt: f32,
	look: bool, // the controls are for the world (no menu open)
) {
	if look && action_pressed(actions, .Camera) {s.camera_mode = camera_mode_next(s.camera_mode)}
	still := settings.reduce_motion
	// Sprinting: a held (or toggled) sprint key while moving.
	moving := look && actions.move != {}
	sprinting := (look && action_down(actions, .Sprint) || s.sprint_on) && moving
	target: f32 = 1 if sprinting && settings.sprint_fov_kick && !still else 0
	step := dt / SPRINT_FOV_SECONDS
	s.fov_kick += clamp(target - s.fov_kick, -step, step)

	s.view = s.camera
	s.view.roll = 0
	if s.camera_mode == .First {
		s.pull = THIRD_DISTANCE
		// Bobbing: on the ground, walking: the phase follows the distance walked.
		vel := s.prediction.state.velocity
		speed := f32(math.sqrt(vel.x * vel.x + vel.z * vel.z))
		walking := s.prediction.state.on_ground && speed > 0.1 && !s.prediction.state.flying
		amp_target: f32 = 1 if walking && settings.view_bobbing && !still else 0
		s.bob_amp += clamp(amp_target - s.bob_amp, -dt / 0.1, dt / 0.1)
		if walking {s.bob_phase += speed * dt * BOB_PER_BLOCK}
		s.bob_phase = math.mod(s.bob_phase, 4 * math.PI)
		s.view.position.y += f64(BOB_HEIGHT * s.bob_amp * math.sin(s.bob_phase * 2))
		s.view.roll = BOB_ROLL * s.bob_amp * math.sin(s.bob_phase)
	} else {
		view, used := camera_third_person(
			query,
			s.camera.position,
			s.camera.yaw + s.orbit,
			s.camera.pitch,
			s.camera_mode,
			THIRD_DISTANCE,
		)
		// In at once, back out over a moment.
		if used < s.pull {s.pull = used} else {
			s.pull = min(used, s.pull + THIRD_DISTANCE / THIRD_EASE_SECONDS * f64(dt))
		}
		view, _ = camera_third_person(
			query,
			s.camera.position,
			s.camera.yaw + s.orbit,
			s.camera.pitch,
			s.camera_mode,
			s.pull,
		)
		s.view = view
	}
	// Aiming: a held item that aims, with the use button held.
	info, _ := game.item_info(s.reg, held(s).item)
	tool, is_tool := info.tool.?
	s.aiming = look && is_tool && tool == .Launcher && action_down(actions, .Use)
	weapon_tick(s, actions, look, dt)
	if s.camera_mode == .First {s.view.pitch = min(s.view.pitch + s.recoil, game.PITCH_LIMIT)}
}

// camera_fov: the field of view to draw with, in degrees.
camera_fov :: proc(s: ^Session, settings: Settings) -> f32 {
	// (a zoomed weapon turns the sprint's widening off)
	return settings.fov * (1 + SPRINT_FOV_KICK * s.fov_kick * (1 - s.zoom)) * zoom_factor(s)
}

// crosshair_shown: first person always; third person only while aiming.
crosshair_shown :: proc(s: ^Session) -> bool {
	return s.camera_mode == .First || s.aiming
}
