package engine

import "core:math"
import "core:math/linalg"

import "client:render"
import "common:game"

// The view: where the eyes are (the predicted player's, see session.odin)
// and where they look. Looking turns every frame, for responsiveness;
// movement is per tick, through inputs. Positions are f64 blocks;
// rendering works relative to the view's chunk.

View :: struct {
	position:   [3]f64, // the eyes
	yaw, pitch: f32, // radians: yaw turns left from -z, pitch up
	roll:       f32, // radians, the drawn view's sway (view_camera.odin)
	cut:        Maybe(i32), // nothing of the world at this y or above is drawn (the top-down camera's roof cut)
}

MOUSE_RADIANS_PER_PIXEL :: 0.0025 // at mouse_sensitivity 1
NEAR_PLANE :: 0.05
DOUBLE_TAP_SECONDS :: 0.3 // two jump presses this close toggle flying

// look_update turns the view by this frame's mouse motion and the pad's
// right stick.
look_update :: proc(
	v: ^View,
	input: ^Input_State,
	a: ^Actions,
	settings: Settings,
	dt: f32,
	scale := f32(1), // the field of view's factor: a zoom turns slower
) {
	turn := MOUSE_RADIANS_PER_PIXEL * settings.mouse_sensitivity * scale
	v.yaw -= input.look.x * turn
	v.pitch -= input.look.y * turn * (-1 if settings.invert_mouse else 1)
	v.yaw += a.look.x * dt * scale
	v.pitch += a.look.y * dt * scale
	v.pitch = clamp(v.pitch, -game.PITCH_LIMIT, game.PITCH_LIMIT)
	v.yaw = math.mod(v.yaw, math.TAU)
}

// player_input reads the controls for one tick (sneak and sprint held, or
// toggled on: session_update). The move is analog (length at most 1).
player_input :: proc(a: ^Actions, s: ^Session) -> game.Player_Input {
	in_ := game.Player_Input {
		yaw   = s.camera.yaw,
		pitch = s.camera.pitch,
		move  = a.move,
	}
	if s.game_camera.kind == .Top_Down {
		in_.move = screen_move(a.move, s.game_camera.heading, s.camera.yaw)
	}
	if s.game_camera.kind == .Free {
		// (the focus moves along the screen: its yaw is the camera's heading)
		in_.yaw, in_.pitch, in_.move = s.free.heading, 0, s.free_move
		in_.buttons = {}
		if action_down(a, .Sprint) {in_.buttons += {.Sprint}}
		return in_
	}
	if action_down(a, .Jump) {in_.buttons += {.Jump}}
	if action_down(a, .Sneak) || s.sneak_on {in_.buttons += {.Sneak}}
	if action_down(a, .Sprint) || s.sprint_on {in_.buttons += {.Sprint}}
	if grapple_button(s, a) {in_.buttons += {.Grapple}}
	return in_
}

camera_chunk :: proc(c: ^View) -> game.Chunk_Pos {
	return game.chunk_of(block_at(c.position))
}

block_at :: proc(p: [3]f64) -> game.Block_Pos {
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

// camera_render is the camera for the renderer: relative to its chunk.
camera_render :: proc(c: ^View, width, height: i32, fov_degrees: f32) -> render.Camera {
	chunk := camera_chunk(c)
	origin := game.chunk_origin(chunk)
	rel := c.position - {f64(origin.x), f64(origin.y), f64(origin.z)}
	position := [3]f32{f32(rel.x), f32(rel.y), f32(rel.z)}
	aspect := f32(max(width, 1)) / f32(max(height, 1))
	proj := render.perspective_reverse_z(fov_degrees * math.RAD_PER_DEG, aspect, NEAR_PLANE)
	return {
		chunk = chunk,
		position = position,
		cut = c.cut,
		view_proj = proj *
		linalg.matrix4_rotate_f32(c.roll, {0, 0, 1}) *
		render.view_matrix(position, c.yaw, c.pitch),
	}
}


// world_debug_lines adds this frame's world-space debug drawing.
world_debug_lines :: proc(app: ^App) {
	dd := &app.debug_draw
	if hit, ok := app.session.aim.?; ok && !world_paused(app) {
		// The aimed-at block: a thin outline just outside its faces.
		b := [3]f64{f64(hit.block.x), f64(hit.block.y), f64(hit.block.z)}
		state, _ := world_block(&app.session.world, hit.block)
		t := &app.session.reg.blocks
		for box in game.shape_boxes(t, t.selection[state]) {
			lo := [3]f64{f64(box.lo.x), f64(box.lo.y), f64(box.lo.z)} / 16
			hi := [3]f64{f64(box.hi.x), f64(box.hi.y), f64(box.hi.z)} / 16
			render.debug_box(dd, b + lo - 0.004, b + hi + 0.004, {16, 16, 20, 220})
		}
	}
	// The selection (pos1, pos2): its box, or the one corner set.
	sel := app.session.selection
	if a, ok := sel[0].?; ok {
		b := sel[1].? or_else a
		lo := [3]f64{f64(min(a.x, b.x)), f64(min(a.y, b.y)), f64(min(a.z, b.z))}
		hi := [3]f64{f64(max(a.x, b.x)), f64(max(a.y, b.y)), f64(max(a.z, b.z))} + 1
		render.debug_box(dd, lo - 0.01, hi + 0.01, {255, 150, 40, 255})
	} else if b, ok2 := sel[1].?; ok2 {
		p := [3]f64{f64(b.x), f64(b.y), f64(b.z)}
		render.debug_box(dd, p - 0.01, p + 1.01, {255, 150, 40, 255})
	}
	break_cracks(app.session, dd)
	world_boxes_draw(app.session, dd)
	if app.debug.chunk_borders {
		c := game.chunk_origin(camera_chunk(&app.session.camera))
		lo := [3]f64{f64(c.x), f64(c.y), f64(c.z)}
		render.debug_box(dd, lo, lo + game.CHUNK_SIZE, render.YELLOW)
		// The neighbours' vertical edges, two chunks up and down.
		for dz in -1 ..= 2 {
			for dx in -1 ..= 2 {
				x, z := lo.x + f64(dx * game.CHUNK_SIZE), lo.z + f64(dz * game.CHUNK_SIZE)
				render.debug_line(
					dd,
					{x, lo.y - 2 * game.CHUNK_SIZE, z},
					{x, lo.y + 3 * game.CHUNK_SIZE, z},
					render.BLUE,
				)
			}
		}
	}
}

// CRACKS: the crack drawn on each face of a block being broken, as segments in the face's
// own square (0..1 each way), in the order they show: from a point off its middle, three
// branches that fork as the hold goes on.
@(rodata)
CRACKS := [?][2][2]f32 {
	{{0.46, 0.54}, {0.30, 0.34}},
	{{0.46, 0.54}, {0.72, 0.44}},
	{{0.46, 0.54}, {0.52, 0.80}},
	{{0.30, 0.34}, {0.14, 0.26}},
	{{0.72, 0.44}, {0.88, 0.22}},
	{{0.52, 0.80}, {0.38, 0.95}},
	{{0.30, 0.34}, {0.34, 0.08}},
	{{0.72, 0.44}, {0.96, 0.58}},
	{{0.52, 0.80}, {0.78, 0.90}},
	{{0.14, 0.26}, {0.04, 0.42}},
	{{0.88, 0.22}, {0.80, 0.04}},
	{{0.38, 0.95}, {0.12, 0.84}},
}

// break_cracks: the block being broken (Break_Hold) cracks on every face, a few more
// segments of CRACKS the further the hold has gone, just outside its faces.
break_cracks :: proc(s: ^Session, dd: ^render.Debug_Draw) {
	f := break_progress(s)
	if f <= 0 {return}
	shown := clamp(int(f * f32(len(CRACKS))) + 1, 1, len(CRACKS))
	b := [3]f64{f64(s.breaking.pos.x), f64(s.breaking.pos.y), f64(s.breaking.pos.z)}
	OUT :: 0.006
	// Each face: its corner, then the two edges its square runs along.
	faces := [6][3][3]f64 {
		{{1 + OUT, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{-OUT, 0, 0}, {0, 0, 1}, {0, 1, 0}},
		{{0, 1 + OUT, 0}, {1, 0, 0}, {0, 0, 1}},
		{{0, -OUT, 0}, {1, 0, 0}, {0, 0, 1}},
		{{0, 0, 1 + OUT}, {1, 0, 0}, {0, 1, 0}},
		{{0, 0, -OUT}, {1, 0, 0}, {0, 1, 0}},
	}
	for face in faces {
		for seg in CRACKS[:shown] {
			a := b + face[0] + face[1] * f64(seg[0].x) + face[2] * f64(seg[0].y)
			c := b + face[0] + face[1] * f64(seg[1].x) + face[2] * f64(seg[1].y)
			render.debug_line(dd, a, c, {12, 10, 8, 235})
		}
	}
}
