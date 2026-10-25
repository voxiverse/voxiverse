package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "../audio"
import "../base"
import "../font"
import "../game"
import "../gpu"
import "../netcode"
import "../platform"
import "../render"
import "../ui"
import "mesh"

// App is everything that lives for the whole process: window, GPU, UI, the
// console, settings. Created and destroyed in one place (app_init /
// app_destroy, in reverse order). A world visit is a Session, with its own
// lifetime inside the App's.

FONT_DATA :: #load("../assets/fonts/jetbrains_mono_regular.ttf")
// SYMBOL_FONT_DATA: the addresses' symbols (Old Turkic), which the UI font
// lacks (game/address.odin).
SYMBOL_FONT_DATA :: #load("../assets/fonts/noto_sans_old_turkic_regular.ttf")

Screen :: enum u8 {
	Title,
	Options,
	Worlds,
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
	mixer:            audio.Mixer, // fed to the sound card by audio_device
	audio_device:     audio.Device,
	sounds:           Sound_Bank,
	volume:           f32, // as last told to the mixer
	shader_watch:     Shader_Watch,
	worlds:           Worlds_Screen,
	multiplayer:      Multiplayer_Screen,
	session:          ^Session, // nil outside a world
	debug:            Debug_Switches,
	settings_dirty:   bool, // changed since loaded or saved
	scripted:         bool, // running --exec commands: settings changes are not saved
	benchmark:        bool, // --benchmark: BENCHMARK_SETTINGS, no sound device, nothing saved
	bench:            Bench, // the scenario running (benchmark.odin)
	stars:            Starfield, // the menus' background (starfield.odin)
	failed:           Failed, // the Failed screen's (loading.odin)
	options:          Options_View, // the Options screen's tab and state (options.odin)
	fixed_view:       [2]i32, // view radius, height: a benchmark's or check's (else view_size)
	checking:         bool, // --check: BENCHMARK_SETTINGS (with the check's view), nothing saved
	screenshot_names: [dynamic]string, // requested, not yet saved (oldest first)
	message:          string, // shown on the title screen (why a session ended)
	fly_test:         Fly_Test,
	blast_test:       Blast_Test,
	tour_test:        Tour_Test,
	server_failed:    bool, // a session's server stopped on an error (fails the run)
	script_failed:    bool, // an --exec script could not go on (fails the run)
	console:          Console,
	input:            Input_State,
	settings:         Settings,
	screen:           Screen,
	overlays:         Overlays, // what is open over the screen (overlays.odin)
	account:          game.Account_Key, // who we are to servers (account.odin)
	new_character:    [dynamic]u8, // the name typed on the characters screen
	chat:             Line_Editor, // the chat's line (chat.odin)
	chat_scroll:      f32, // lines scrolled up in the open chat
	inventory_view:   Inventory_View, // the inventory overlay's (inventory_ui.odin)
	dial:             Dial_View, // the dial overlay's (dial.odin)
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
	shader_watch_init(&app.shader_watch)

	if !platform.window_open(&app.window, "Voxiverse", 1280, 720) {return false}
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
	render.debug_draw_init(&app.debug_draw)
	render.entity_draw_init(&app.entity_draw)
	if !render.scene_init(&app.scenes, g) {return false}
	if !app.benchmark {audio_init(app)} 	// (a benchmark has no sound device: its mixer would vary the work)
	return passes_init(app)
}

// audio_init makes the sounds and opens the sound card; without one the
// game runs silent.
@(private = "file")
audio_init :: proc(app: ^App) {
	audio.mixer_init(&app.mixer, audio.DEVICE_RATE)
	sounds_init(&app.sounds, &app.mixer)
	audio.set_volume(&app.mixer, app.settings.volume)
	app.volume = app.settings.volume
	audio.device_open(&app.audio_device, &app.mixer)
}

// world_pass_init sets up chunk rendering with the generated block textures.
world_pass_init :: proc(app: ^App, vert, frag: []u8) -> bool {
	pixels := make([dynamic]u8, context.temp_allocator)
	level := make([]mesh.Rgba, mesh.TEXTURE_SIZE * mesh.TEXTURE_SIZE, context.temp_allocator)
	for t in mesh.Texture {
		mesh.generate_texture(t, level)
		size := mesh.TEXTURE_SIZE
		current := level
		for _ in 0 ..< mesh.TEXTURE_MIPS {
			append(&pixels, ..slice.to_bytes(current))
			if size == 1 {break}
			next := make([]mesh.Rgba, (size / 2) * (size / 2), context.temp_allocator)
			mesh.generate_mip(current, size, next)
			current, size = next, size / 2
		}
	}
	#assert(size_of(mesh.Vertex) == render.WORLD_VERTEX_SIZE)
	shaders := world_shaders(vert, frag) or_return
	return render.world_init(
		&app.world_pass,
		&app.g,
		{vertex_capacity = CHUNK_VERTEX_CAPACITY, staging_size = 8 * 1024 * 1024},
		shaders,
		pixels[:],
		mesh.TEXTURE_SIZE,
		mesh.TEXTURE_MIPS,
		len(mesh.Texture),
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
		passes_destroy(app)
		render.scene_destroy(&app.scenes, &app.g)
	}
	a := audio.stats(&app.mixer)
	log.infof(
		"audio device=%v played=%d mixed_seconds=%.1f dropped=%d",
		app.audio_device.open,
		a.played,
		f64(a.frames) / f64(max(app.mixer.rate, 1)),
		app.mixer.dropped,
	)
	audio.device_close(&app.audio_device) // before the sounds it plays go
	sounds_destroy(&app.sounds)
	if app.settings_dirty {settings_save(app)}
	console_history_save(&app.console)
	ui.destroy(&app.ui)
	render.debug_draw_destroy(&app.debug_draw)
	render.entity_draw_destroy(&app.entity_draw)
	shader_watch_destroy(&app.shader_watch)
	worlds_destroy(&app.worlds)
	multiplayer_destroy(&app.multiplayer)
	delete(app.message)
	for n in app.screenshot_names {delete(n)}
	delete(app.screenshot_names)
	delete(app.new_character)
	validation_issues = gpu.destroy(&app.g)
	platform.window_close(&app.window)
	input_destroy(&app.input)
	console_destroy(&app.console)
	line_editor_destroy(&app.chat)
	return
}

// app_frame runs one frame: input, UI, render. Returns false to stop.
app_frame :: proc(app: ^App, capture_this_frame: bool) -> bool {
	base.profile_scope("frame")
	w := &app.window
	{
		base.profile_scope("events")
		minimized := w.width <= 0 || w.height <= 0
		events := platform.wait_events(w) if minimized else platform.poll_events(w)
		input_update(&app.input, events)
	}
	if w.close_requested || app.quit {return false}

	shader_watch_update(app, app.last_frame_ms / 1000)
	scale := ui_scale(app)
	input := ui_input(&app.input, scale)
	handle_global_keys(app, &input)
	if app.settings.fullscreen !=
	   w.fullscreen {platform.set_fullscreen(w, app.settings.fullscreen)}
	// Playing (not in a menu, not paused): no screensaver, no display sleep.
	playing := app.session != nil && app.session.state == .Playing && !world_paused(app)
	platform.set_keep_awake(w, playing)
	gpu.set_vsync(&app.g, app.settings.vsync)
	if app.settings.volume != app.volume {
		audio.set_volume(&app.mixer, app.settings.volume)
		app.volume = app.settings.volume
	}
	if app.session != nil {
		// Paused alone in our own world, it stands still; anyone else could
		// be playing (a remote server, the LAN open), so it runs on.
		session_freeze(app.session, world_paused(app))
		platform.set_mouse_captured(w, game_controls(app) && w.focused)
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
			app.settings,
			conditions,
			app.last_frame_ms / 1000,
			w.mouse_captured,
		)
		fly_test_update(app)
		blast_test_update(app)
		tour_test_update(app)
		if !app.benchmark {sounds_play(&app.sounds, &app.mixer, app.session.sounds[:], app.session.camera)} 	// (a benchmark has no mixer)
		clear(&app.session.sounds)
		for n in app.session.notices {
			console_print(&app.console, n)
			delete(n)
		}
		clear(&app.session.notices)
		loading_update(app.session)
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
		base.profile_scope("ui")
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
		base.profile_scope("begin_frame")
		frame, ok = gpu.begin_frame(&app.g, w.width, w.height)
	}
	screenshots_save(app)
	if !ok {return true}
	{
		base.profile_scope("record")
		base.metric_scope(.Frame_Record)
		g := &app.g
		app.world_pass.occlusion = app.debug.occlusion_stats
		render.world_begin(&app.world_pass, g)
		if app.session != nil {session_apply(app.session, &app.world_pass, g)}
		render.world_upload(&app.world_pass, g, frame)
		render.ui_upload(&app.ui_pass, g, frame, &app.ui.output)
		in_world :=
			app.session != nil && app.session.state == .Playing && app.session.loading == nil
		camera: render.Camera
		scene: u64
		if in_world {
			s := app.session
			width, height := render_size(app)
			camera = camera_render(&s.camera, width, height, app.settings.fov)
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
			avatars_draw(s, &app.entity_draw)
			entities_draw(s, &app.entity_draw, app.last_frame_ms / 1000)
		}
		render.debug_upload(&app.debug_pass, g, &app.debug_draw, camera)
		render.entity_upload(&app.entity_pass, g, &app.entity_draw, camera)
		gpu.begin_rendering(frame, {0, 0, 0, 1})
		if in_world {
			render.world_draw(&app.world_pass, g, frame, camera, scene)
			render.entity_draw(&app.entity_pass, g, frame, scene)
			render.sky_draw(&app.sky_pass, g, frame, scene)
			render.world_draw_translucent(&app.world_pass, g, frame, camera, scene, app.seconds)
			render.debug_draw(&app.debug_pass, g, frame, camera)
		}
		render.ui_draw(&app.ui_pass, g, frame, &app.ui.output)
		gpu.end_rendering(frame)
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
	benchmark := false, // the same work every run: no critters, still clouds
) {
	view_radius, view_height := view_size(app)
	start_session(
		app,
		{
			no_critters = benchmark,
			still_clouds = benchmark,
			name = player_name(&app.settings),
			key = app.account,
			seed = seed,
			save_dir = save_dir,
			spawn = spawn,
			view_radius = view_radius,
			view_height = view_height,
			trace = app.debug.net_trace,
		},
	)
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
	if !session_start(app.session, config) {
		app.message = fmt.aprintf("Could not start: %s", app.session.failure)
		leave_world(app)
		return
	}
	app.screen = .Game
	overlays_leave_game(&app.overlays)
}

// leave_world ends the session and returns to the title screen.
leave_world :: proc(app: ^App) {
	if app.session == nil {return}
	gpu.wait_idle(&app.g) // its meshes may be in use
	if !session_end(app.session, &app.world_pass, &app.g) {
		log.error("the server stopped with an error (see above)")
		app.server_failed = true
		delete(app.message)
		app.message = strings.clone("The world could not be saved (see the log)")
	}
	free(app.session)
	app.session = nil
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

// read_shader loads compiled SPIR-V from the shaders/ folder next to the
// executable (build/shaders in a dev build).
read_shader :: proc(name: string) -> ([]byte, bool) {
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
