package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "client:audio"
import "client:font"
import "client:gpu"
import "client:mesh"
import "client:platform"
import "client:render"
import "client:ui"
import "common:base"
import "common:game"
import "common:netcode"
import "server:."

// App is everything that lives for the whole process: window, GPU, UI, the
// console, settings. Created and destroyed in one place (app_init /
// app_destroy, in reverse order). A world visit is a Session, with its own
// lifetime inside the App's.

FONT_DATA :: #load("../assets/fonts/jetbrains_mono_regular.ttf")
// SYMBOL_FONT_DATA: the addresses' symbols (Old Turkic), which the UI font
// lacks (common/game/address.odin).
SYMBOL_FONT_DATA :: #load("../assets/fonts/noto_sans_old_turkic_regular.ttf")

Screen :: enum u8 {
	Title,
	Options,
	Credits,
	Universes,
	Creation,
	Multiplayer,
	Game, // a session exists
	Failed, // the session ended against our will: why (app.failed)
}

// CHUNK_VERTEX_CAPACITY: vertices of all chunk meshes together (8 bytes
// each: 128 MiB).
CHUNK_VERTEX_CAPACITY :: 16 * 1024 * 1024

App :: struct {
	window:           platform.Window,
	g:                gpu.Gpu,
	renderdoc:        gpu.Renderdoc,
	symbol_font:      font.Font, // (SYMBOL_FONT_DATA)
	font:             font.Font,
	ui:               ui.Context,
	ui_pass:          render.Ui_Pass,
	world_pass:       render.World_Pass,
	sky_pass:         render.Sky_Pass,
	scenes:           render.Scene_Buffers,
	debug_pass:       render.Debug_Pass,
	debug_draw:       render.Debug_Draw, // this frame's debug lines
	entity_pass:      render.Entity_Pass,
	entity_draw:      render.Entity_Draw, // this frame's boxes (players, entities, particles)
	held_pass:        render.Held_Pass, // what the hands hold (viewmodel.odin)
	held_draw:        render.Held_Draw, // this frame's held meshes: the view model, third person items
	held_cache:       Held_Cache, // every item's mesh in a hand
	held_arm:         Held_Mesh, // our right arm, in our shirt
	held_arm_shirt:   [4]u8,
	mixer:            ^audio.Mixer, // heap (it is large); fed to the sound card by audio_device
	audio_device:     audio.Device,
	null_audio:       bool, // mix into the null device, whatever the sound card (--null-audio, --check audio)
	audio_debug:      Audio_Debug,
	sounds:           Sound_Bank,
	music:            Music_App, // the director and its voices (music_app.odin)
	snapshots:        Snapshots, // what the mixer's snapshot holds (snapshots.odin)
	volumes:          [audio.Bus]f32, // as last told to the mixer
	listener:         audio.Listener, // ... and the listener's options
	shader_watch:     Shader_Watch,
	universes:        Universes_Screen,
	creation:         Creation_Screen,
	ignite:           Ignite,
	cues:             [dynamic]string, // UI sound events fired (ui_cue)
	multiplayer:      Multiplayer_Screen,
	session:          ^Session, // nil outside a world
	debug:            Debug_Switches,
	telemetry:        Telemetry_Switches,
	settings_dirty:   bool, // changed since loaded or saved
	scripted:         bool, // running --exec commands: settings changes are not saved
	benchmark:        bool, // --benchmark: BENCHMARK_SETTINGS, no sound device, nothing saved
	bench:            Bench, // the scenario running (benchmark.odin)
	stars:            Starfield, // the menus' background (starfield.odin)
	failed:           Failed, // the Failed screen's (screen_loading.odin)
	credits:          Credits_View, // the Credits screen's scroll (screen_credits.odin)
	options:          Options_View, // the Options screen's tab and state (screen_options.odin)
	fixed_view:       [2]i32, // view radius, height: a benchmark's or check's (else view_size)
	checking:         bool, // --check or --scene: BENCHMARK_SETTINGS (with the check's view), nothing saved
	scene:            Scene_Run, // --scene: a visual baseline's (scenes.odin)
	screenshot_names: [dynamic]string, // requested, not yet saved (oldest first)
	screenshot_dir:   string, // where they go, next to the executable ("": screenshots)
	message:          string, // shown on the title screen (why a session ended)
	fly_test:         Fly_Test,
	blast_test:       Blast_Test,
	audio_check:      Audio_Check,
	cull_check:       Exit_Check, // `--check cull` (cull_check_run)
	tour_test:        Tour_Test,
	server_failed:    bool, // a session's server stopped on an error (fails the run)
	script_failed:    bool, // an --exec script could not go on (fails the run)
	console:          Console,
	input:            Input_State,
	actions:          Actions, // this frame's actions (actions.odin)
	injected:         [dynamic]platform.Event, // events the pad command and checks add
	settings:         Settings,
	screen:           Screen,
	overlays:         Overlays, // what is open over the screen (overlay.odin)
	account:          game.Account_Key, // who we are to servers (account.odin)
	new_character:    [dynamic]u8, // the name typed on the characters screen
	chat:             Line_Editor, // the chat's line (overlay_chat.odin)
	chat_scroll:      f32, // lines scrolled up in the open chat
	chat_osk:         bool, // the chat was opened by a pad: its line opens the on-screen keyboard
	splash:           string, // the title screen's, chosen once (screen_title.odin)
	started:          time.Tick, // when the app began (the splash's pulse)
	toasts:           Toasts, // the notices at the top right (overlay_toasts.odin)
	hud_hidden:       bool, // F1: the HUD is hidden (not saved)
	popup:            Item_Popup, // the held item's name above the hotbar (hud_popup.odin)
	lan:              Lan_Dialog, // the Open to LAN dialog's choices (overlay_lan.odin)
	player_menu:      Player_Menu, // the section shown and the one shown last (menu_player.odin)
	inventory_view:   Inventory_View, // the inventory overlay's (menu_inventory.odin)
	reporter:         Reporter, // what the client tells the server about itself (telemetry.odin)
	launched:         time.Tick, // when the program started
	clock:            App_Clock, // the OS's unless a test fixed it (clock.odin)
	stats_view:       Stats_View, // the statistics overlay's (menu_statistics.odin)
	preview:          Preview, // the player in the inventory (preview.odin)
	inventory_search: [dynamic]u8, // the Creative tab's search text
	prompt_icons:     Prompt_Icons, // the button glyphs (hud_prompts.odin)
	prompts_shown:    [PROMPTS_SHOWN_MAX]Prompt_Glyph, // this frame's, for tests (prompts_seen)
	prompts_count:    int,
	shown:            ^game.Registry, // the registry the texture array, sound bank and icons were last made for (nil: none of a session)
	registry:         ^game.Registry, // the game's own (the base pack); sessions use it unless they play a universe with packs
	item_icons:       Item_Icons, // every item's icon, in the UI's atlas (icons.odin)
	dial:             Dial_View, // the dial overlay's (overlay_dial.odin)
	quit:             bool,
	frame_stats:      base.Frame_Stats,
	triangle_stats:   base.Frame_Stats, // thousands drawn a frame, in a world
	last_frame_ms:    f32,
	seconds:          f32, // since start, wrapped every 1000 (moving water)
	fps:              Fps,
}

// app_init brings everything up; on failure the caller still calls
// app_destroy, which handles partially initialised apps.
app_init :: proc(app: ^App) -> bool {
	app.started = time.tick_now()
	app.launched = time.tick_now()
	app.registry = game.registry_base()
	console_init(&app.console)
	line_editor_init(&app.chat)
	register_builtin_commands(&app.console)
	if app.benchmark || app.checking {
		app.settings = BENCHMARK_SETTINGS // (the player's are not read)
	} else {
		settings_load(app)
	}
	account_load(app)
	console_history_load(&app.console)
	app.debug = DEBUG_DEFAULTS
	app.telemetry = TELEMETRY_DEFAULTS
	shader_watch_init(&app.shader_watch)

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
		validation_options(),
	) {return false}
	surface, ok := platform.vulkan_create_surface(&app.window, g.instance)
	if !ok {
		log.error("could not create a Vulkan surface for the window")
		return false
	}
	if !gpu.init_device(g, surface) {return false}
	gpu.pipeline_cache_open(g, path_next_to_exe("pipeline-cache.bin"))
	capture_dir := path_next_to_exe("captures")
	if gpu.renderdoc_attach(&app.renderdoc, capture_dir, "voxiverse") {
		os.make_directory_all(capture_dir)
	}

	if app.font, ok = font.load(FONT_DATA); !ok {
		log.error("could not load the UI font")
		return false
	}
	if app.symbol_font, ok = font.load(SYMBOL_FONT_DATA); !ok {
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
	if !item_icons_init(app.registry, &app.item_icons, &app.ui) {return false}
	if !prompt_icons_init(&app.prompt_icons, &app.ui) {return false}
	render.debug_draw_init(&app.debug_draw)
	render.entity_draw_init(&app.entity_draw)
	render.held_draw_init(&app.held_draw)
	if !render.scene_init(&app.scenes, g) {return false}
	app.mixer = new(audio.Mixer)
	audio.mixer_init(app.mixer, audio.DEVICE_RATE)
	if !app.benchmark {audio_init(app)} 	// (a benchmark has no sound device: its mixer would vary the work)
	if !passes_init(app) {return false}
	return preview_init(app)
}

// audio_init makes the sounds and opens the sound card; without one the
// game runs silent.
@(private = "file")
audio_init :: proc(app: ^App) {
	sounds_init(&app.sounds, app.mixer)
	music_init(app)
	// Explosions and the like duck the music (duck 1 is M58's).
	audio.set_duck(
		app.mixer,
		0,
		{
			active = true,
			trigger = .Effects,
			target = .Music,
			threshold = 0.25,
			amount = 0.6,
			attack = 0.02,
			release = 1,
		},
	)
	audio_volumes(app, true)
	audio_listener(app, true)
	if app.null_audio {
		audio.device_open_null(&app.audio_device, app.mixer)
	} else {
		audio.device_open(&app.audio_device, app.mixer)
	}
	audio_ring_start(app)
}

// audio_volumes tells the mixer the volume sliders that changed (all, first).
audio_volumes :: proc(app: ^App, all: bool) {
	s := &app.settings
	want := #partial [audio.Bus]f32 {
		.Master   = s.volume,
		.Music    = s.music_volume,
		.Ambience = s.ambience_volume,
		.Effects  = s.effects_volume,
	}
	for b in ([]audio.Bus{.Master, .Music, .Ambience, .Effects}) {
		if all || want[b] != app.volumes[b] {
			audio.set_bus_gain(app.mixer, b, want[b])
			app.volumes[b] = want[b]
		}
	}
}

// audio_listener tells the mixer the listener's options when they changed
// (all: whatever they are, first).
audio_listener :: proc(app: ^App, all: bool) {
	s := &app.settings
	want := audio.Listener {
		mono       = s.mono_audio,
		swap       = s.swap_channels,
		night      = s.night_mode,
		crossfeed  = clamp(s.crossfeed, 0, 0.6),
		ceiling_db = clamp(s.ceiling_db, -24, -0.1) if s.ceiling_db != 0 else 0,
	}
	if all || want != app.listener {
		audio.set_listener(app.mixer, want)
		app.listener = want
	}
}

// apply_registry makes what depends on a registry: the texture array, the
// sound files of its packs and its items' icons. Nothing is made again for the
// registry shown already.
apply_registry :: proc(app: ^App, reg: ^game.Registry) {
	if app.shown == reg {return}
	app.shown = reg
	if app.world_pass.textures.handle != 0 {
		layers := u32(game.registry_texture_layers(reg))
		render.world_set_textures(&app.world_pass, &app.g, mesh.texture_array(reg), layers)
	}
	if !app.benchmark {sounds_load_pack(&app.sounds, app.mixer, reg)}
	item_icons_init(reg, &app.item_icons, &app.ui)
}

// world_pass_init sets up chunk rendering with the generated block textures.
world_pass_init :: proc(app: ^App, vert, frag: []u8) -> bool {
	pixels := mesh.texture_array(app.registry)
	#assert(size_of(mesh.Vertex) == render.WORLD_VERTEX_SIZE)
	shaders := world_shaders(vert, frag) or_return
	app.shown = app.registry
	return render.world_init(
		&app.world_pass,
		&app.g,
		{vertex_capacity = CHUNK_VERTEX_CAPACITY, staging_size = 8 * 1024 * 1024},
		shaders,
		pixels,
		mesh.TEXTURE_SIZE,
		mesh.TEXTURE_MIPS,
		u32(game.registry_texture_layers(app.registry)),
		max_meshes = 1 << 16,
	)
}

// app_destroy tears down in reverse and returns the Vulkan validation
// findings count (read after the GPU is gone; see gpu.destroy).
app_destroy :: proc(app: ^App) -> (validation_issues: int) {
	if app.g.device != nil {
		gpu.wait_idle(&app.g)
		if app.session != nil {leave_world(app)}
		screenshots_save(app) // the last frames' screenshots are done now
		gpu.renderdoc_log_captures(&app.renderdoc)
		preview_destroy(app)
		passes_destroy(app)
		render.scene_destroy(&app.scenes, &app.g)
	}
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
	audio.device_close(&app.audio_device) // before the sounds it plays go
	audio_ring_stop(app)
	audio.streams_close(app.mixer)
	sounds_destroy(&app.sounds)
	music_destroy(app)
	free(app.mixer)
	if app.settings_dirty {settings_save(app)}
	console_history_save(&app.console)
	delete(app.item_icons)
	game.registry_destroy(app.registry)
	delete(app.inventory_search)
	stats_view_destroy(&app.stats_view)
	reporter_destroy(&app.reporter)
	ui.destroy(&app.ui)
	render.debug_draw_destroy(&app.debug_draw)
	render.entity_draw_destroy(&app.entity_draw)
	render.held_draw_destroy(&app.held_draw)
	held_cache_destroy(&app.held_cache)
	held_mesh_destroy(&app.held_arm)
	shader_watch_destroy(&app.shader_watch)
	universes_destroy(&app.universes)
	creation_destroy(&app.creation)
	delete(app.cues)
	toasts_destroy(&app.toasts)
	multiplayer_destroy(&app.multiplayer)
	delete(app.failed.reason)
	delete(app.message)
	for n in app.screenshot_names {delete(n)}
	delete(app.screenshot_names)
	delete(app.new_character)
	validation_issues = gpu.destroy(&app.g)
	platform.window_close(&app.window)
	input_destroy(&app.input)
	delete(app.injected)
	console_destroy(&app.console)
	line_editor_destroy(&app.chat)
	return
}

// app_frame runs one frame: input, UI, render. Returns false to stop.
// keep_awake_update: no screensaver and no display sleep for the whole run
// (the title, the menus and a paused game included; the window's close lets
// them be).
keep_awake_update :: proc(app: ^App) {
	platform.set_keep_awake(&app.window, true)
}

// app_frame draws frame number (counted from 1, as --capture-frame counts).
app_frame :: proc(app: ^App, capture_this_frame: bool, number: int) -> bool {
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
		input_update(&app.input, events)
		actions_sync(app, app.last_frame_ms / 1000)
	}
	if w.close_requested || app.quit {return false}

	{
		base.profile_scope("shader watch and telemetry")
		shader_watch_update(app, app.last_frame_ms / 1000)
		telemetry_update(app)
	}
	scale := ui_scale(app)
	input := ui_input(&app.input, scale)
	handle_global_keys(app, &input)
	if app.settings.fullscreen !=
	   w.fullscreen {platform.set_fullscreen(w, app.settings.fullscreen)}
	keep_awake_update(app)
	gpu.set_vsync(&app.g, app.settings.vsync)
	{
		base.profile_scope("audio and music")
		audio_volumes(app, false)
		audio_listener(app, false)
		audio.drain(app.mixer)
		if !app.benchmark {
			music_update(app, app.last_frame_ms / 1000)
			snapshots_update(app, app.last_frame_ms / 1000)
		}
		audio_debug_update(app)
	}
	if app.session != nil {
		// Paused alone in our own world, it stands still; anyone else could
		// be playing (a remote server, the LAN open), so it runs on.
		session_freeze(app.session, world_paused(app))
		// (The pad flight check runs on whatever desktop: focus is given.)
		platform.set_mouse_captured(w, game_controls(app) && (w.focused || app.fly_test.pad))
		conditions := game.Conditions {
			latency_ms     = app.debug.net_latency_ms,
			jitter_ms      = app.debug.net_jitter_ms,
			bandwidth_kbps = app.debug.net_bandwidth_kbps,
			loss_percent   = app.debug.net_loss,
			dup_percent    = app.debug.net_duplicate,
		}
		session_update(
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
			apply_registry(app, app.session.reg)
			app.session.reg_swapped = false
		}
		if s := app.session; s.reg_fresh != nil && world_mesh_idle(&s.world) { 	// (the server reloaded its packs)
			game.registry_swap(s.reg, s.reg_fresh)
			s.reg_fresh = nil
			session_texels(s)
			app.shown = nil
			apply_registry(app, s.reg)
			world_remesh_all(&s.world)
		}
		fly_test_update(app)
		blast_test_update(app)
		audio_check_update(app)
		tour_test_update(app)
		if !app.benchmark {sounds_play(&app.sounds, app.mixer, app.session.reg, app.session.sounds[:], app.session.camera)} 	// (a benchmark has no mixer)
		clear(&app.session.sounds)
		for n in app.session.notices {
			console_print(&app.console, n)
			delete(n)
		}
		clear(&app.session.notices)
		loading_update(app.session)
		base.profile_end()
		if s := app.session; s.state == .Failed {
			// Why, on a screen of its own; Back to where we came from.
			title := "Connection Lost" if s.welcome.view_radius != 0 else "Could Not Join"
			failed := Failed{title, sentence(s.failure), .Multiplayer if s.remote else .Title}
			leave_world(app)
			app.failed = failed
			app.screen = .Failed
		}
	} else {
		platform.set_mouse_captured(w, false)
	}
	{
		base.profile_scope("ui layout")
		width, height := render_size(app)
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
	screenshots_save(app)
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
			if app.session != nil {session_apply(app.session, &app.world_pass, g)}
		}
		{
			base.profile_scope("world and ui uploads")
			render.world_upload(&app.world_pass, g, frame)
			render.ui_upload(&app.ui_pass, g, frame, &app.ui.output)
			preview_record(app, frame)
		}
		in_world :=
			app.session != nil && app.session.state == .Playing && app.session.loading == nil
		camera: render.Camera
		scene, view_scene: u64
		if in_world {
			base.profile_scope("scene (avatars, entities, view model)")
			s := app.session
			width, height := render_size(app)
			camera = camera_render(&s.view, width, height, camera_fov(s, app.settings))
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
					eye_in_water(s),
					app.settings.brightness,
					app.settings.clouds,
				),
			)
			world_debug_lines(app)
			avatars_draw(s, &app.entity_draw, &app.held_draw, &app.held_cache)
			entities_draw(s, &app.entity_draw, app.last_frame_ms / 1000)
			bench_avatars_draw(app, s)
			view_scene = view_model_frame(app, s, width, height)
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
	}
	return true
}

// render_size: what frames are drawn at: a benchmark's fixed offscreen
// size (gpu.set_offscreen), else the window's.
render_size :: proc(app: ^App) -> (width, height: i32) {
	if s := app.g.offscreen.size; s != {} {return i32(s.x), i32(s.y)}
	return app.window.width, app.window.height
}

// MENU_FPS: frames per second at most where nothing in a world moves (the
// title, menus, the game menu): drawing them thousands of times a second
// with vsync off only heats the machine (and can make it whine).
MENU_FPS :: 120

// frame_cap: the shortest a frame may take now (0: no limit).
frame_cap :: proc(app: ^App) -> time.Duration {
	in_world := app.screen == .Game && !world_paused(app)
	if in_world ||
	   app.fly_test.phase != .Off ||
	   app.blast_test.phase != .Off ||
	   app.audio_check.phase != .Off ||
	   app.tour_test.phase != .Off {
		if app.settings.max_fps > 0 &&
		   !app.benchmark {return time.Second / time.Duration(app.settings.max_fps)}
		return 0
	}
	return time.Second / MENU_FPS
}

// SCRATCH_SPAWN: where exit checks start in the scratch world: fixed, so
// their budgets keep meaning the same ground (the generator's spawn there
// before M13 kept spawns off trees and the shore).
SCRATCH_SPAWN :: [3]f64{24.5, 11, 8.5}

// SCRATCH_SEED: the seed of the scratch world (singleplayer, exit checks).
SCRATCH_SEED :: 0x5eed

// enter_world starts a session in the world saved at save_dir (created if
// new, with seed), or with save_dir "" a scratch world nothing is saved of
// (scripts and tests). The world runs here; others can join once it is
// opened to the LAN.
enter_world :: proc(
	app: ^App,
	save_dir: string,
	seed: i64,
	spawn: Maybe([3]f64) = nil,
	benchmark := false, // the same work every run: no sheep, still clouds
	mode := "creative", // a new universe's default game mode
) {
	view_radius, view_height := view_size(app)
	start_session(
		app,
		{
			no_sheep = benchmark,
			still_clouds = benchmark,
			name = player_name(&app.settings),
			key = app.account,
			seed = seed,
			mode = mode,
			save_dir = save_dir,
			spawn = spawn,
			view_radius = view_radius,
			view_height = view_height,
			trace = app.debug.net_trace,
			upload = upload_target(app),
		},
	)
}

// upload_target: where this world's events go: the collector, if the player
// said yes (and the world is saved: a scratch world keeps no log); else nowhere.
upload_target :: proc(app: ^App) -> Maybe(server.Upload) {
	if !app.settings.share_data {return nil}
	address := base.var_text(&app.settings.collector)
	if address == "" {address = DEFAULT_COLLECTOR}
	ep, err := net.resolve_ip4(address)
	if err != nil {return nil}
	if ep.port == 0 {ep.port = netcode.DEFAULT_PORT}
	return server.Upload{ep, app.account, 0}
}

// join_server plays on the server at address ("host" or "host:port"; the
// default port if none).
join_server :: proc(app: ^App, address: string, password: string, choose := false) {
	ep, err := net.resolve_ip4(address)
	if err != nil {
		delete(app.message)
		app.message = fmt.aprintf("Cannot find %s (%v)", address, err)
		app.screen = .Title
		return
	}
	if ep.port == 0 {ep.port = netcode.DEFAULT_PORT}
	view_radius, view_height := view_size(app)
	start_session(
		app,
		{
			name        = "" if choose else player_name(&app.settings), // "": the server's list
			key         = app.account,
			join        = Join{ep, password},
			capture     = app.debug.net_capture,
			view_radius = view_radius,
			view_height = view_height,
		},
	)
}

@(private = "file")
start_session :: proc(app: ^App, config: Session_Config) {
	if app.session != nil {return}
	delete(app.message)
	app.message = ""
	app.session = new(Session)
	config := config
	config.registry = app.registry
	if !session_start(app.session, config) {
		app.message = fmt.aprintf("Could not start: %s", app.session.failure)
		leave_world(app)
		return
	}
	apply_registry(app, app.session.reg) // (a universe with packs: its textures, sounds and items)
	app.screen = .Game
	overlays_leave_game(&app.overlays)
}

// leave_world ends the session and returns to the title screen.
leave_world :: proc(app: ^App) {
	if app.session == nil {return}
	app.shown = nil // (its registry goes with it)
	gpu.wait_idle(&app.g) // its meshes may be in use
	if !session_end(app.session, &app.world_pass, &app.g) {
		log.error("the server stopped with an error (see above)")
		app.server_failed = true
		delete(app.message)
		app.message = strings.clone("The world could not be saved (see the log)")
	}
	free(app.session)
	app.session = nil
	popup_reset(&app.popup)
	app.screen = .Title
	overlays_leave_game(&app.overlays)
	platform.set_mouse_captured(&app.window, false)
}

// view_size: the view to join a world with: the render distance around
// and half of it up and down, or the fixed view of a benchmark or a check.
view_size :: proc(app: ^App) -> (radius, height: i32) {
	if app.fixed_view != {} {return app.fixed_view.x, app.fixed_view.y}
	r := app.settings.render_distance
	return r, clamp(r / 2, 2, 16)
}

// ui_scale: the user's setting, or one derived from the window height
// (1.0 at 720 px, in quarter steps) so the UI keeps its proportions.
ui_scale :: proc(app: ^App) -> f32 {
	if app.settings.gui_scale > 0 {return f32(app.settings.gui_scale)}
	h := f32(max(app.window.height, 1))
	return clamp(math.round(h / 720 * 4) / 4, 1, 3)
}

// validation_options reads VX_VALIDATION: unset = on in development builds only,
// "0" = off, otherwise a comma list of "1"/"on", "best" (best-practices
// advice) and "gpu" (GPU-assisted shader checks).
validation_options :: proc() -> gpu.Validation {
	value, set := os.lookup_env("VX_VALIDATION", context.temp_allocator)
	if !set {return {enabled = base.DEV}}
	v: gpu.Validation
	for word in split_commas(value) {
		switch word {
		case "1", "on":
			v.enabled = true
		case "best":
			v.enabled, v.best_practices = true, true
		case "gpu":
			v.enabled, v.gpu_assisted = true, true
		case "0", "off", "":
		case:
			log.warnf("VX_VALIDATION: unknown option '%s' (use 0, 1, best, gpu)", word)
		}
	}
	return v
}

// EMBED_SHADERS: the compiled shaders are carried in the executable (a
// release package: one file, nothing beside it); otherwise they are read
// from the shaders/ folder beside it, so hot reload can replace them.
EMBED_SHADERS :: #config(VX_EMBED_SHADERS, false)
when EMBED_SHADERS {
	SHADERS := #load_directory("../build/shaders")
}

// read_shader loads compiled SPIR-V: carried in the executable, or from the
// shaders/ folder next to it (build/shaders in a dev build).
read_shader :: proc(name: string) -> ([]byte, bool) {
	when EMBED_SHADERS {
		for f in SHADERS {
			if f.name == name {return f.data, true}
		}
		log.errorf("shader %s is not in this build", name)
		return nil, false
	}
	path := path_next_to_exe(filepath.join({"shaders", name}, context.temp_allocator) or_else name)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		log.errorf("cannot read shader %s: %v (run `build shaders`)", path, err)
		return nil, false
	}
	return data, true
}

// path_next_to_exe places a file beside the executable (build/ in dev).
path_next_to_exe :: proc(name: string) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return name}
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

@(private)
split_commas :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == ',' {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	return out[:]
}

// eye_in_water: the camera is inside water.
@(private = "file")
eye_in_water :: proc(s: ^Session) -> bool {
	e := s.camera.position
	b, _ := world_block(
		&s.world,
		{i32(math.floor(e.x)), i32(math.floor(e.y)), i32(math.floor(e.z))},
	)
	_, water := game.water_level(b)
	return water
}
