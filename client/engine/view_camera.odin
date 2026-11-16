package engine

import "core:math"
import "core:math/linalg"

import "client:render"
import "common:game"

// The camera's modes and comforts: F5 cycles first person, third person behind and third person
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

// Game_Camera_Kind: which camera a game's client part chooses (Game.camera).
Game_Camera_Kind :: enum u8 {
	Player, // the player's own choice (F5 cycles it)
	First, // the eyes
	Third, // behind the head, pulled in against walls
	Top_Down, // above the head looking down, the pointer free: it aims (pointer_update)
}

// Game_Camera: the camera a game wants this frame. A top-down camera follows the head
// from `distance` blocks away, looking `angle` degrees below the horizon along
// `heading` (radians, a yaw: 0 looks down -z); the mouse is not captured, the pointer
// says where the avatar faces and what it aims at, and the movement keys move along
// the screen. `cut`: nothing of the world from that many blocks above the feet up is
// drawn (0: all of it), so a roof or a ceiling does not hide the avatar.
Game_Camera :: struct {
	kind:     Game_Camera_Kind,
	distance: f32,
	angle:    f32, // degrees
	heading:  f32,
	cut:      f32, // blocks above the feet
}

// TOP_DOWN_AIM: how far (blocks) the pointer's ray looks for a block or an entity.
TOP_DOWN_AIM :: 96

// camera_game: the game's camera this frame (game_camera; the player's own when the
// game has no camera hook): the F5 mode follows it, so the rest (the avatar drawn or
// not, the hand, the crosshair) is as for that mode.
camera_game :: proc(s: ^Session) {
	s.game_camera = {}
	if s.game.camera != nil {s.game_camera = s.game.camera(s)}
	switch s.game_camera.kind {
	case .Player:
	case .First:
		s.camera_mode = .First
	case .Third, .Top_Down:
		s.camera_mode = .Third_Behind
	}
}

// camera_pointer: the camera leaves the pointer free (a top-down camera): the mouse is
// not captured, and it aims.
camera_pointer :: proc(s: ^Session) -> bool {
	return s != nil && s.state == .Playing && s.game_camera.kind == .Top_Down
}

// camera_top_down: the view of a top-down camera over the eyes.
camera_top_down :: proc(eyes: [3]f64, c: Game_Camera) -> (view: View) {
	pitch := -clamp(c.angle, 1, 89.9) * math.RAD_PER_DEG
	f := render.forward(c.heading, pitch)
	view.position = eyes - [3]f64{f64(f.x), f64(f.y), f64(f.z)} * f64(max(c.distance, 1))
	view.yaw, view.pitch = c.heading, pitch
	return
}

// pointer_ray: the ray through the pointer (pixels in the window) of the frame's view
// (Screen_View: the last frame's), from the near plane; false with no view yet.
pointer_ray :: proc(v: ^Screen_View, pointer: [2]f32) -> (origin, dir: [3]f64, ok: bool) {
	if !v.set || v.size.x <= 0 || v.size.y <= 0 {return}
	inverse := linalg.inverse(v.camera.view_proj)
	ndc := pointer / v.size * 2 - 1
	unproject :: proc(m: matrix[4, 4]f32, ndc: [2]f32, depth: f32) -> [3]f64 {
		p := m * [4]f32{ndc.x, ndc.y, depth, 1}
		return {f64(p.x / p.w), f64(p.y / p.w), f64(p.z / p.w)}
	}
	// (reverse Z: depth 1 is the near plane, smaller is further)
	near := unproject(inverse, ndc, 1)
	far := unproject(inverse, ndc, 0.01)
	d := far - near
	l := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	if l < 1e-9 {return}
	o := game.chunk_origin(v.camera.chunk)
	return near + {f64(o.x), f64(o.y), f64(o.z)}, d / l, true
}

// pointer_update: under a top-down camera, what the pointer is over: the block the
// session aims at (s.aim, any distance: the server judges reach), the entity
// (s.aim_entity) and the point (s.pointer); the avatar faces it: the eyes' yaw turn to
// the point and their pitch to it at chest height (a hitscan shot flies level over
// the floor), or to an entity's middle.
pointer_update :: proc(s: ^Session, pointer: [2]f32, query: game.Block_Query) {
	s.aim, s.aim_entity, s.pointer = nil, nil, nil
	origin, dir, seen := pointer_ray(&s.screen_view, pointer)
	if !seen {return}
	distance := f64(TOP_DOWN_AIM)
	if hit, ok := game.raycast(query, origin, dir, distance); ok {
		s.aim, distance = hit, hit.distance
	}
	target := origin + dir * distance
	if id, d, ok := entity_aimed(s, origin, dir, distance); ok {
		s.aim_entity = id
		target = origin + dir * d
		if at, there := entity_place(s, id); there {
			info := game.kind_info(s.reg, s.entities[id].kind)
			target = at + {0, f64(info.box[1]) / 2, 0}
		}
	} else if s.aim == nil {
		// Nothing under it: where the ray meets the level of the feet.
		if abs(dir.y) < 1e-6 {return}
		target = origin + dir * ((s.feet.y - origin.y) / dir.y)
	} else {
		target.y = s.camera.position.y - 0.4
	}
	s.pointer = target
	d := target - s.camera.position
	flat := math.sqrt(d.x * d.x + d.z * d.z)
	if flat > 0.05 {s.camera.yaw = f32(math.atan2(-d.x, -d.z))}
	s.camera.pitch = clamp(
		f32(math.atan2(d.y, max(flat, 0.05))),
		-game.PITCH_LIMIT,
		game.PITCH_LIMIT,
	)
}

// screen_move: a move along the screen (x right, y up it) under a camera looking along
// heading, as the move of a player facing yaw (what Player_Input.move is: x to its
// right, y ahead), so the keys move the avatar across the screen whichever way it
// faces.
screen_move :: proc(move: [2]f32, heading, yaw: f32) -> [2]f32 {
	right :: proc(yaw: f32) -> [2]f32 {return {math.cos(yaw), -math.sin(yaw)}}
	ahead :: proc(yaw: f32) -> [2]f32 {return {-math.sin(yaw), -math.cos(yaw)}}
	wish := right(heading) * move.x + ahead(heading) * move.y
	return {linalg.dot(wish, right(yaw)), linalg.dot(wish, ahead(yaw))}
}

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
	if look && action_pressed(actions, .Camera) && s.game_camera.kind == .Player {
		s.camera_mode = camera_mode_next(s.camera_mode)
	}
	still := settings.reduce_motion
	// Sprinting: a held (or toggled) sprint key while moving.
	moving := look && actions.move != {}
	sprinting := (look && action_down(actions, .Sprint) || s.sprint_on) && moving
	target: f32 = 1 if sprinting && settings.sprint_fov_kick && !still else 0
	step := dt / SPRINT_FOV_SECONDS
	s.fov_kick += clamp(target - s.fov_kick, -step, step)

	s.view = s.camera
	s.view.roll = 0
	if s.game_camera.kind == .Top_Down {
		s.view = camera_top_down(s.camera.position, s.game_camera)
		if s.game_camera.cut > 0 {
			s.view.cut = i32(math.floor(s.feet.y + f64(s.game_camera.cut)))
		}
	} else if s.camera_mode == .First {
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
	grapple_rope(s)
	if s.camera_mode == .First {s.view.pitch = min(s.view.pitch + s.recoil, game.PITCH_LIMIT)}
}

// camera_fov: the field of view to draw with, in degrees.
camera_fov :: proc(s: ^Session, settings: Settings) -> f32 {
	// (a zoomed weapon turns the sprint's widening off)
	return settings.fov * (1 + SPRINT_FOV_KICK * s.fov_kick * (1 - s.zoom)) * zoom_factor(s)
}

// crosshair_shown: first person always; third person only while aiming.
crosshair_shown :: proc(s: ^Session) -> bool {
	if s.game_camera.kind == .Top_Down {return false} 	// (the pointer is the crosshair)
	return s.camera_mode == .First || s.aiming
}
