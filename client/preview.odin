package client

import "core:math"

import "../common/game"
import "gpu"
import "render"

// The player's preview in the inventory: the real avatar (avatar_draw, as
// the others see it, with what it wears) drawn by the entity pass into a
// render target of its own, seen from the front, turned toward the mouse
// (inventory_ui.odin sets the target angles); the UI shows the target as an
// image. Drawn only while the inventory shows it.

PREVIEW_WIDTH :: 256
PREVIEW_HEIGHT :: 440

Preview :: struct {
	active:       bool, // asked for this frame (the overlay is showing it)
	target_yaw:   f32,
	target_pitch: f32,
	yaw, pitch:   f32, // eased toward the targets
	target:       gpu.Target,
	pass:         render.Entity_Pass, // its own vertex buffers, the world's pipeline
	draw:         render.Entity_Draw,
	scenes:       render.Scene_Buffers,
}

preview_init :: proc(app: ^App) -> bool {
	p := &app.preview
	render.entity_draw_init(&p.draw)
	render.scene_init(&p.scenes, &app.g) or_return
	p.target = gpu.target_create(&app.g, PREVIEW_WIDTH, PREVIEW_HEIGHT, "player preview") or_return
	app.ui_pass.images[PREVIEW_IMAGE] = p.target.id
	return true
}

// preview_destroy: after wait_idle.
preview_destroy :: proc(app: ^App) {
	p := &app.preview
	gpu.target_destroy(&app.g, &p.target)
	render.entity_destroy(&p.pass, &app.g)
	render.entity_draw_destroy(&p.draw)
	render.scene_destroy(&p.scenes, &app.g)
	p^ = {}
}

// preview_record draws the preview if it was asked for this frame. Record
// it outside rendering, before the frame's own begin_rendering.
preview_record :: proc(app: ^App, frame: gpu.Frame) {
	p := &app.preview
	defer p.active = false
	s := app.session
	if !p.active ||
	   s == nil ||
	   p.target.color.handle == 0 ||
	   app.entity_pass.pipeline.handle == 0 {return}
	g := &app.g
	ease := 1 - math.exp(-12 * app.last_frame_ms / 1000)
	p.yaw += (p.target_yaw - p.yaw) * ease
	p.pitch += (p.target_pitch - p.pitch) * ease
	avatar_draw(
		&p.draw,
		{0, 0, 0},
		p.yaw,
		p.pitch,
		false,
		shirt_of(s.config.name),
		game.worn_of(&s.inventory),
	)
	// In front of it: the camera at -z looking back along +z (its front is -z).
	position := [3]f32{0, 0.95, -3.8}
	proj := render.perspective_reverse_z(
		33 * math.RAD_PER_DEG,
		f32(PREVIEW_WIDTH) / f32(PREVIEW_HEIGHT),
		0.1,
	)
	camera := render.Camera {
		position  = position,
		view_proj = proj * render.view_matrix(position, math.PI, 0),
	}
	scene := render.scene_upload(
		&p.scenes,
		g,
		render.scene_make(camera, render.sky_at(0.5), 1000, 0, false, 0, false),
	)
	render.entity_upload(&p.pass, g, &p.draw, camera)
	target := gpu.target_begin(g, frame.cmd, &p.target, {0.02, 0.025, 0.04, 1})
	render.entity_draw(&p.pass, g, target, scene, &app.entity_pass)
	gpu.target_end(&p.target, target)
}
