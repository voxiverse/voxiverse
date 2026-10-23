package client

import "core:math"

import "../game"
import "../render"

// The fly camera (M3; M4 replaces it with a player and physics). Position is
// in f64 blocks; rendering works relative to the camera's chunk.

Fly_Camera :: struct {
	position: [3]f64,
	yaw:      f32, // radians, turning left from -z
	pitch:    f32, // radians, up
}

FLY_SPEED :: 20 // blocks per second
FLY_FAST_SPEED :: 120 // with Control held
MOUSE_SENSITIVITY :: 0.0025 // radians per pixel
FOV_Y :: 70 * math.RAD_PER_DEG
NEAR_PLANE :: 0.05

camera_update :: proc(c: ^Fly_Camera, input: ^Input_State, dt: f32) {
	c.yaw -= input.look.x * MOUSE_SENSITIVITY
	c.pitch -= input.look.y * MOUSE_SENSITIVITY
	c.pitch = clamp(c.pitch, -1.55, 1.55)
	c.yaw = math.mod(c.yaw, math.TAU)

	held := input.held
	move: [3]f32
	// Horizontal movement follows the view's heading, not its pitch.
	ahead := [3]f32{-math.sin(c.yaw), 0, -math.cos(c.yaw)}
	right := [3]f32{math.cos(c.yaw), 0, -math.sin(c.yaw)}
	if .W in held {move += ahead}
	if .S in held {move -= ahead}
	if .D in held {move += right}
	if .A in held {move -= right}
	if .Space in held {move.y += 1}
	if held & {.Left_Shift, .Right_Shift} != {} {move.y -= 1}
	if move == {} {return}
	speed: f32 = FLY_FAST_SPEED if held & {.Left_Control, .Right_Control} != {} else FLY_SPEED
	step := normalize(move) * speed * dt
	c.position += {f64(step.x), f64(step.y), f64(step.z)}
	// Stay where the protocol can describe positions.
	limit := f64(game.WORLD_LIMIT - 1024)
	for &v in c.position {v = clamp(v, -limit, limit)}
}

camera_chunk :: proc(c: ^Fly_Camera) -> game.Chunk_Pos {
	return game.chunk_of(block_at(c.position))
}

block_at :: proc(p: [3]f64) -> game.Block_Pos {
	return {i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
}

// camera_render is the camera for the renderer: relative to its chunk.
camera_render :: proc(c: ^Fly_Camera, width, height: i32) -> render.Camera {
	chunk := camera_chunk(c)
	origin := game.chunk_origin(chunk)
	rel := c.position - {f64(origin.x), f64(origin.y), f64(origin.z)}
	position := [3]f32{f32(rel.x), f32(rel.y), f32(rel.z)}
	aspect := f32(max(width, 1)) / f32(max(height, 1))
	proj := render.perspective_reverse_z(FOV_Y, aspect, NEAR_PLANE)
	return {
		chunk = chunk,
		position = position,
		view_proj = proj * render.view_matrix(position, c.yaw, c.pitch),
	}
}

@(private = "file")
normalize :: proc(v: [3]f32) -> [3]f32 {
	l := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	return v / l
}
