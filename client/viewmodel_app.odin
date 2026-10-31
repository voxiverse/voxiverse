package client


import "client:render"
import "common:game"

// The view model's frame (docs/milestones/M48k.md): step the animations, make
// the arm's and the item's vertices in view space and the scene they are drawn
// with. The session's events (swings, shots, reloads) arrive through
// vm_event on s.vm.

// vm_comfort: the sway and the bob play only with "View bobbing" on and Reduce
// motion off (a swing, a place, a recoil or a reload is an action's feedback and
// always plays).
vm_comfort :: proc(settings: Settings) -> bool {
	return settings.view_bobbing && !settings.reduce_motion
}

// view_model_frame returns the address of the view model's scene, or 0 when
// nothing is drawn (third person, F1, a zoomed sniper).
view_model_frame :: proc(app: ^App, s: ^Session, width, height: i32) -> u64 {
	item := held(s).item
	if item != s.vm_item {
		vm_reset(&s.vm)
		s.vm_item = item
	}
	_, w, is_weapon := weapon_in_hand(s)
	pose := vm_update(
		&s.vm,
		{
			dt = app.last_frame_ms / 1000,
			comfort = vm_comfort(app.settings),
			bob_phase = s.bob_phase,
			bob_amp = s.bob_amp,
			zoom = s.zoom,
			zooms = is_weapon && w.zoom > 0,
		},
	)
	if !view_model_shown(s.camera_mode, app.hud_hidden, pose) {return 0}
	entry := held_entry(&app.held_cache, s.reg, item)
	shirt := shirt_of(s.config.name)
	if app.held_arm.vertices == nil || app.held_arm_shirt != shirt {
		held_mesh_destroy(&app.held_arm)
		app.held_arm = held_mesh_arm(shirt)
		app.held_arm_shirt = shirt
	}
	view_model_add(&app.held_draw, entry.kind, &entry.mesh, &app.held_arm, pose)
	aspect := f32(max(width, 1)) / f32(max(height, 1))
	camera := render.Camera {
		view_proj = view_model_projection(aspect),
	}
	return render.held_view_scene(
		&app.held_pass,
		&app.g,
		render.scene_make(
			camera,
			render.sky_at(game.time_of_day(s.clock)),
			1e9,
			0,
			false,
			app.settings.brightness,
			false,
		),
	)
}
