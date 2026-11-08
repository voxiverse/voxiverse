package main

import "client:audio"
import "client:autopilot"
import "client:console"
import "client:dev"
import "client:engine"
import "client:font"
import "client:gpu"
import "client:menu"
import "client:overlay"
import "client:platform"
import "client:prompt"
import "client:render"
import "client:screen"
import "client:ui"
import "common:base"
import "common:game"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

// app_init brings everything up; on failure the caller still calls
// app_destroy, which handles partially initialised apps.
app_init :: proc(app: ^engine.App) -> bool {
	app.started = time.tick_now()
	app.launched = time.tick_now()
	app.registry = game.registry_base()
	console.console_init(&app.console)
	engine.line_editor_init(&app.chat)
	engine.line_editor_init(&app.devchat_line)
	app.devchat_attach = true
	console.register_builtin_commands(&app.console)
	if app.benchmark || app.checking {
		app.settings = autopilot.BENCHMARK_SETTINGS // (the player's are not read)
	} else {
		engine.settings_load(app)
		if dir, found := engine.crashes_dir(); found {engine.crash_offer_root(app, dir)}
	}
	engine.account_load(app)
	engine.steam_start(app)
	console.console_history_load(&app.console)
	app.debug = engine.DEBUG_DEFAULTS
	app.telemetry = engine.TELEMETRY_DEFAULTS
	engine.shader_watch_init(&app.shader_watch)

	// A benchmark's window has a title of its own, so a desktop can keep it out of the
	// way (a window rule) without touching the game's.
	title := "Voxiverse benchmark" if app.benchmark else "Voxiverse"
	if !platform.window_open(&app.window, title, 1280, 720) {return false}
	g := &app.g
	extensions := platform.vulkan_instance_extensions()
	if !gpu.create_instance(
		g,
		platform.vulkan_loader_name(),
		extensions,
		engine.validation_options(),
	) {return false}
	surface, ok := platform.vulkan_create_surface(&app.window, g.instance)
	if !ok {
		log.error("could not create a Vulkan surface for the window")
		return false
	}
	if !gpu.init_device(g, surface) {return false}
	cache_path := engine.path_next_to_exe("pipeline-cache.bin")
	if dir, set := base.state_dir_override(); set {
		cache_path = strings.concatenate({dir, "/pipeline-cache.bin"}, context.temp_allocator)
	}
	gpu.pipeline_cache_open(g, cache_path)
	capture_dir := engine.path_next_to_exe("captures")
	if gpu.renderdoc_attach(&app.renderdoc, capture_dir, "voxiverse") {
		os.make_directory_all(capture_dir)
	}

	if app.font, ok = font.load(engine.FONT_DATA); !ok {
		log.error("could not load the UI font")
		return false
	}
	if app.symbol_font, ok = font.load(engine.SYMBOL_FONT_DATA); !ok {
		log.error("could not load the symbol font")
		return false
	}
	if !ui.init(&app.ui, &app.font, fallback = &app.symbol_font) {return false}
	{
		sizes := [?]int{16, 32, 48, 64, 128}
		images: [len(sizes)]platform.Icon_Image
		for size, i in sizes {
			images[i] = {size, ui.app_icon(&app.font, size, context.temp_allocator)}
		}
		platform.set_window_icon(&app.window, images[:])
	}
	if !engine.item_icons_init(app.registry, &app.item_icons, &app.ui) {return false}
	if !prompt.prompt_icons_init(&app.prompt_icons, &app.ui) {return false}
	render.debug_draw_init(&app.debug_draw)
	render.entity_draw_init(&app.entity_draw)
	render.held_draw_init(&app.held_draw)
	if !render.scene_init(&app.scenes, g) {return false}
	app.mixer = new(audio.Mixer)
	audio.mixer_init(app.mixer, audio.DEVICE_RATE)
	if !app.benchmark {engine.audio_init(app)} 	// (a benchmark has no sound device: its mixer would vary the work)
	if !engine.passes_init(app) {return false}
	return engine.preview_init(app)
}

// app_destroy tears down in reverse and returns the Vulkan validation
// findings count (read after the GPU is gone; see gpu.destroy).
app_destroy :: proc(app: ^engine.App) -> (validation_issues: int) {
	if app.g.device != nil {
		gpu.wait_idle(&app.g)
		if app.session != nil {engine.leave_world(app)}
		engine.screenshots_save(app) // the last frames' screenshots are done now
		gpu.renderdoc_log_captures(&app.renderdoc)
		engine.preview_destroy(app)
		engine.passes_destroy(app)
		render.scene_destroy(&app.scenes, &app.g)
	}
	if app.mixer != nil { 	// (nil when init failed before it: no usable GPU)
		a := audio.stats(app.mixer)
		log.infof(
			"audio device=%v played=%d mixed_seconds=%.1f dropped=%d underruns=%d late=%d callback_max_us=%d drift_ppm=%.1f",
			app.audio_device.open,
			a.played,
			f64(a.frames) / f64(max(app.mixer.rate, 1)),
			app.mixer.dropped,
			a.underruns,
			a.late,
			a.cb_max_ns / 1000,
			a.drift_ppm,
		)
	}
	audio.device_close(&app.audio_device) // before the sounds it plays go
	dev.audio_ring_stop(app)
	if app.mixer != nil {audio.streams_close(app.mixer)}
	engine.sounds_destroy(&app.sounds)
	engine.music_destroy(app)
	free(app.mixer)
	engine.devchat_stop(app)
	engine.steam_stop(app)
	if app.settings_dirty {engine.settings_save(app)}
	console.console_history_save(&app.console)
	delete(app.item_icons)
	game.registry_destroy(app.registry)
	delete(app.inventory_search)
	menu.stats_view_destroy(&app.stats_view)
	engine.reporter_destroy(&app.reporter)
	ui.destroy(&app.ui)
	render.debug_draw_destroy(&app.debug_draw)
	render.entity_draw_destroy(&app.entity_draw)
	render.held_draw_destroy(&app.held_draw)
	engine.held_cache_destroy(&app.held_cache)
	engine.held_mesh_destroy(&app.held_arm)
	engine.shader_watch_destroy(&app.shader_watch)
	screen.universes_destroy(&app.universes)
	screen.creation_destroy(&app.creation)
	delete(app.cues)
	overlay.toasts_destroy(&app.toasts)
	screen.multiplayer_destroy(&app.multiplayer)
	delete(app.failed.reason)
	delete(app.message)
	for n in app.screenshot_names {delete(n)}
	delete(app.screenshot_names)
	delete(app.new_character)
	validation_issues = gpu.destroy(&app.g)
	platform.window_close(&app.window)
	engine.input_destroy(&app.input)
	delete(app.injected)
	console.console_destroy(&app.console)
	engine.line_editor_destroy(&app.chat)
	return
}

// app_frame draws frame number (counted from 1, as --capture-frame counts).
app_frame :: proc(app: ^engine.App, capture_this_frame: bool, number: int) -> bool {
	base.profile_scope_number("frame", u64(number))
	w := &app.window
	{
		base.profile_scope("input")
		minimized := w.width <= 0 || w.height <= 0
		events := platform.wait_events(w) if minimized else platform.poll_events(w)
		if len(app.injected) > 0 {
			// Injected events come before the frame's own.
			all := make(
				[dynamic]platform.Event,
				0,
				len(app.injected) + len(events),
				context.temp_allocator,
			)
			append(&all, ..app.injected[:])
			append(&all, ..events)
			clear(&app.injected)
			events = all[:]
		}
		for e in events {
			// (the window's own full screen, from its green button: the setting follows)
			if f, ok := e.(platform.Fullscreen_Event); ok {app.settings.fullscreen = f.fullscreen}
		}
		engine.input_update(&app.input, events)
		engine.actions_sync(app, app.last_frame_ms / 1000)
		engine.crash_track(app)
	}
	if w.close_requested || app.quit {return false}

	{
		base.profile_scope("shader watch and telemetry")
		engine.shader_watch_update(app, app.last_frame_ms / 1000)
		engine.telemetry_update(app)
	}
	scale := engine.ui_scale(app)
	input := engine.ui_input(&app.input, scale)
	handle_global_keys(app, &input)
	if app.settings.fullscreen !=
	   w.fullscreen {platform.set_fullscreen(w, app.settings.fullscreen)}
	engine.keep_awake_update(app)
	engine.devchat_sync(app)
	engine.steam_update(app)
	gpu.set_vsync(&app.g, app.settings.vsync)
	{
		base.profile_scope("audio and music")
		engine.audio_volumes(app, false)
		engine.audio_listener(app, false)
		audio.drain(app.mixer)
		if !app.benchmark {
			engine.music_update(app, app.last_frame_ms / 1000)
			engine.snapshots_update(app, app.last_frame_ms / 1000)
		}
		dev.audio_debug_update(app)
	}
	if app.session != nil {
		// Paused alone in our own world, it stands still; anyone else could
		// be playing (a remote server, the LAN open), so it runs on.
		engine.session_freeze(app.session, engine.world_paused(app))
		// (The pad flight check runs on whatever desktop: focus is given.)
		platform.set_mouse_captured(
			w,
			engine.game_controls(app) && (w.focused || app.fly_test.pad),
		)
		conditions := game.Conditions {
			latency_ms     = app.debug.net_latency_ms,
			jitter_ms      = app.debug.net_jitter_ms,
			bandwidth_kbps = app.debug.net_bandwidth_kbps,
			loss_percent   = app.debug.net_loss,
			dup_percent    = app.debug.net_duplicate,
		}
		engine.session_update(
			app.session,
			&app.input,
			&app.actions,
			app.settings,
			conditions,
			app.last_frame_ms / 1000,
			w.mouse_captured,
		)
		base.profile_begin("after session (packs, checks, sounds, loading)") // (no return before its end)
		if app.session.reg_swapped { 	// (joined a server with packs: its textures, sounds and items)
			engine.apply_registry(app, app.session.reg)
			app.session.reg_swapped = false
		}
		if s := app.session; s.reg_fresh != nil && engine.world_mesh_idle(&s.world) { 	// (the server reloaded its packs)
			game.registry_swap(s.reg, s.reg_fresh)
			s.reg_fresh = nil
			engine.session_texels(s)
			app.shown = nil
			engine.apply_registry(app, s.reg)
			engine.world_remesh_all(&s.world)
		}
		autopilot.fly_test_update(app)
		autopilot.blast_test_update(app)
		autopilot.audio_check_update(app)
		autopilot.tour_test_update(app)
		if !app.benchmark {engine.sounds_play(&app.sounds, app.mixer, app.session.reg, app.session.sounds[:], app.session.camera, &app.session.world)} 	// (a benchmark has no mixer)
		clear(&app.session.sounds)
		for n in app.session.notices {
			engine.console_print(&app.console, n)
			delete(n)
		}
		clear(&app.session.notices)
		screen.loading_update(app.session)
		base.profile_end()
		if s := app.session; s.state == .Failed {
			// Why, on a screen of its own; Back to where we came from.
			title := "Connection Lost" if s.welcome.view_radius != 0 else "Could Not Join"
			failed := engine.Failed {
				title,
				screen.sentence(s.failure),
				.Multiplayer if s.remote else .Title,
			}
			engine.leave_world(app)
			app.failed = failed
			app.screen = .Failed
		}
	} else {
		platform.set_mouse_captured(w, false)
	}
	{
		base.profile_scope("ui layout")
		width, height := engine.render_size(app)
		ui.begin_frame(&app.ui, input, {f32(width), f32(height)}, scale)
		app_ui(app, &app.ui)
		ui.end_frame(&app.ui)
	}
	if capture_this_frame {gpu.renderdoc_capture(&app.renderdoc, "voxiverse")}

	frame: gpu.Frame
	ok: bool
	{
		// Waits for this frame slot's previous GPU work and the next image.
		base.profile_scope("wait for GPU")
		frame, ok = gpu.begin_frame(&app.g, w.width, w.height)
	}
	engine.screenshots_save(app)
	if !ok {return true}
	{
		// The CPU's side of drawing: uploads, the scene, the command buffer, submit.
		base.profile_scope("render")
		base.metric_scope(.Frame_Record)
		g := &app.g
		app.world_pass.occlusion = app.debug.occlusion_stats
		{
			base.profile_scope("chunk meshes in")
			render.world_begin(&app.world_pass, g)
			if app.session != nil {engine.session_apply(app.session, &app.world_pass, g)}
		}
		{
			base.profile_scope("world and ui uploads")
			render.world_upload(&app.world_pass, g, frame)
			render.ui_upload(&app.ui_pass, g, frame, &app.ui.output)
			engine.preview_record(app, frame)
		}
		in_world :=
			app.session != nil && app.session.state == .Playing && app.session.loading == nil
		camera: render.Camera
		scene, view_scene: u64
		if in_world {
			base.profile_scope("scene (avatars, entities, view model)")
			s := app.session
			width, height := engine.render_size(app)
			camera = engine.camera_render(
				&s.view,
				width,
				height,
				engine.camera_fov(s, app.settings),
			)
			fog := f32(s.welcome.view_radius * game.CHUNK_SIZE)
			sky := render.sky_at(game.time_of_day(s.clock))
			scene = render.scene_upload(
				&app.scenes,
				g,
				render.scene_make(
					camera,
					sky,
					fog,
					s.cloud_drift,
					engine.eye_in_water(s),
					app.settings.brightness,
					app.settings.clouds,
				),
			)
			engine.world_debug_lines(app)
			engine.avatars_draw(s, &app.entity_draw, &app.held_draw, &app.held_cache)
			engine.entities_draw(s, &app.entity_draw, app.last_frame_ms / 1000)
			autopilot.bench_avatars_draw(app, s)
			view_scene = engine.view_model_frame(app, s, width, height)
		}
		entity_uploads: {
			base.profile_scope("entity uploads")
			render.debug_upload(&app.debug_pass, g, &app.debug_draw, camera)
			render.entity_upload(&app.entity_pass, g, &app.entity_draw, camera)
			render.held_upload(&app.held_pass, g, &app.held_draw, camera)
		}
		if in_world {
			base.profile_scope("world cull")
			render.world_cull(&app.world_pass, g, frame, scene, camera)
		}
		textures := u32(app.world_pass.textures_id)
		base.profile_begin("record commands") // (no return before its end)
		gpu.begin_rendering(frame, {0, 0, 0, 1})
		if in_world {
			render.world_draw(&app.world_pass, g, frame, scene)
			// The depth pyramid from the world's opaque and cutout depth alone
			// (render/hiz.odin): the frame's rendering is split round it.
			gpu.end_rendering(frame)
			render.hiz_frame(&app.world_pass.hiz, g, frame)
			gpu.begin_rendering(frame, {0, 0, 0, 1}, load = true)
			render.entity_draw(&app.entity_pass, g, frame, scene)
			render.held_draw_world(&app.held_pass, g, frame, scene, textures)
			render.sky_draw(&app.sky_pass, g, frame, scene)
			render.world_draw_translucent(&app.world_pass, g, frame, scene, app.seconds)
			render.debug_draw(&app.debug_pass, g, frame, camera)
			render.held_draw_view(&app.held_pass, g, frame, view_scene, textures)
		}
		render.ui_draw(&app.ui_pass, g, frame, &app.ui.output)
		gpu.end_rendering(frame)
		base.profile_end()
		gpu.end_frame(g, frame)
		engine.scene_count(app)
	}
	return true
}
