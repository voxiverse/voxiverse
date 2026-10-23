package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"

import "../base"
import "../font"
import "../game"
import "../gpu"
import "../platform"
import "../render"
import "../ui"
import "mesh"

// App is everything that lives for the whole process: window, GPU, UI, the
// console, settings. Created and destroyed in one place (app_init /
// app_destroy, in reverse order). A world visit is a Session, with its own
// lifetime inside the App's.

FONT_DATA :: #load("../assets/fonts/jetbrains_mono_regular.ttf")

Screen :: enum u8 {
	Title,
	Options,
	Game, // a session exists
}

// The sky, linear (the swapchain encodes sRGB); fog fades to it.
SKY_COLOR :: [3]f32{0.30, 0.52, 0.85}

// CHUNK_VERTEX_CAPACITY: vertices of all chunk meshes together (8 bytes
// each: 128 MiB).
CHUNK_VERTEX_CAPACITY :: 16 * 1024 * 1024

App :: struct {
	window:           platform.Window,
	g:                gpu.Gpu,
	renderdoc:        gpu.Renderdoc,
	font:             font.Font,
	ui:               ui.Context,
	ui_pass:          render.Ui_Pass,
	world_pass:       render.World_Pass,
	debug_pass:       render.Debug_Pass,
	debug_draw:       render.Debug_Draw, // this frame's debug lines
	session:          ^Session, // nil outside a world
	paused:           bool, // the pause menu is open (in a world)
	debug:            Debug_Switches,
	settings_dirty:   bool, // changed since loaded or saved
	scripted:         bool, // running --exec commands: settings changes are not saved
	tuning:           bool, // the tuning panel is open
	screenshot_names: [dynamic]string, // requested, not yet saved (oldest first)
	message:          string, // shown on the title screen (why a session ended)
	fly_test:         Fly_Test,
	server_failed:    bool, // a session's server stopped on an error (fails the run)
	console:          Console,
	input:            Input_State,
	settings:         Settings,
	screen:           Screen,
	quit_dialog:      bool,
	quit:             bool,
	frame_stats:      base.Frame_Stats,
	last_frame_ms:    f32,
}

// app_init brings everything up; on failure the caller still calls
// app_destroy, which handles partially initialised apps.
app_init :: proc(app: ^App) -> bool {
	console_init(&app.console)
	register_builtin_commands(&app.console)
	settings_load(app)

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
	if !ui.init(&app.ui, &app.font) {return false}
	vert, vert_ok := read_shader("ui.vert.spv")
	frag, frag_ok := read_shader("ui.frag.spv")
	if !vert_ok || !frag_ok {return false}
	if !render.ui_init(&app.ui_pass, g, vert, frag) {return false}
	render.debug_draw_init(&app.debug_draw)
	debug_vert, debug_vert_ok := read_shader("debug.vert.spv")
	debug_frag, debug_frag_ok := read_shader("debug.frag.spv")
	if !debug_vert_ok || !debug_frag_ok {return false}
	if !render.debug_init(&app.debug_pass, g, debug_vert, debug_frag) {return false}
	return world_pass_init(app)
}

// world_pass_init sets up chunk rendering with the generated block textures.
@(private = "file")
world_pass_init :: proc(app: ^App) -> bool {
	vert, vert_ok := read_shader("world.vert.spv")
	frag, frag_ok := read_shader("world.frag.spv")
	if !vert_ok || !frag_ok {return false}
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
	return render.world_init(
		&app.world_pass,
		&app.g,
		{
			vertex_capacity = CHUNK_VERTEX_CAPACITY,
			staging_size = 8 * 1024 * 1024,
			fog_color = SKY_COLOR,
			fog_distance = f32(app.settings.view_radius * game.CHUNK_SIZE),
		},
		vert,
		frag,
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
		render.world_destroy(&app.world_pass, &app.g)
		render.debug_destroy(&app.debug_pass, &app.g)
		render.ui_destroy(&app.ui_pass, &app.g)
	}
	if app.settings_dirty {settings_save(app)}
	ui.destroy(&app.ui)
	render.debug_draw_destroy(&app.debug_draw)
	delete(app.message)
	for n in app.screenshot_names {delete(n)}
	delete(app.screenshot_names)
	validation_issues = gpu.destroy(&app.g)
	platform.window_close(&app.window)
	input_destroy(&app.input)
	console_destroy(&app.console)
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

	scale := ui_scale(app)
	input := ui_input(&app.input, scale)
	handle_global_keys(app, &input)
	if app.session != nil {
		// The world keeps running behind menus (the server would anyway).
		playing := !app.paused && !app.console.open && !app.tuning
		platform.set_mouse_captured(w, playing && w.focused)
		session_update(
			app.session,
			&app.input,
			app.settings,
			app.last_frame_ms / 1000,
			w.mouse_captured,
		)
		fly_test_update(app)
		if app.session.state == .Failed {
			app.message = fmt.aprintf("Disconnected: %s", app.session.failure)
			leave_world(app)
		}
	} else {
		platform.set_mouse_captured(w, false)
	}
	{
		base.profile_scope("ui")
		ui.begin_frame(&app.ui, input, {f32(w.width), f32(w.height)}, scale)
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
		g := &app.g
		render.world_begin(&app.world_pass, g)
		if app.session != nil {session_apply(app.session, &app.world_pass, g)}
		render.world_upload(&app.world_pass, g, frame)
		render.ui_upload(&app.ui_pass, g, frame, &app.ui.output)
		in_world := app.session != nil && app.session.state == .Playing
		camera: render.Camera
		if in_world {
			camera = camera_render(&app.session.camera, w.width, w.height, app.settings.fov)
			world_debug_lines(app)
		}
		render.debug_upload(&app.debug_pass, g, &app.debug_draw, camera)
		clear_color :=
			[4]f32{SKY_COLOR.r, SKY_COLOR.g, SKY_COLOR.b, 1} if in_world else {0, 0, 0, 1}
		gpu.begin_rendering(frame, clear_color)
		if in_world {
			render.world_draw(&app.world_pass, g, frame, camera)
			render.debug_draw(&app.debug_pass, g, frame, camera)
		}
		render.ui_draw(&app.ui_pass, g, frame, &app.ui.output)
		gpu.end_rendering(frame)
		gpu.end_frame(g, frame)
	}
	return true
}

// enter_world starts a singleplayer session.
enter_world :: proc(app: ^App) {
	if app.session != nil {return}
	delete(app.message)
	app.message = ""
	app.session = new(Session)
	app.world_pass.settings.fog_distance = f32(app.settings.view_radius * game.CHUNK_SIZE)
	config := Session_Config {
		seed        = 0x5eed,
		view_radius = app.settings.view_radius,
		view_height = app.settings.view_height,
	}
	if !session_start(app.session, config) {
		app.message = fmt.aprintf("Could not start the world: %s", app.session.failure)
		leave_world(app)
		return
	}
	app.screen = .Game
	app.paused = false
}

// leave_world ends the session and returns to the title screen.
leave_world :: proc(app: ^App) {
	if app.session == nil {return}
	gpu.wait_idle(&app.g) // its meshes may be in use
	if !session_end(app.session, &app.world_pass, &app.g) {
		log.error("the server stopped with an error (see above)")
		app.server_failed = true
	}
	free(app.session)
	app.session = nil
	app.screen = .Title
	app.paused = false
	platform.set_mouse_captured(&app.window, false)
}

// ui_scale: the user's setting, or one derived from the window height
// (1.0 at 720 px, in quarter steps) so the UI keeps its proportions.
ui_scale :: proc(app: ^App) -> f32 {
	if app.settings.ui_scale > 0 {return app.settings.ui_scale}
	h := f32(max(app.window.height, 1))
	return clamp(math.round(h / 720 * 4) / 4, 1, 3)
}

// validation_options reads VX_VALIDATION: unset = on in debug builds only,
// "0" = off, otherwise a comma list of "1"/"on", "best" (best-practices
// advice) and "gpu" (GPU-assisted shader checks).
validation_options :: proc() -> gpu.Validation {
	value, set := os.lookup_env("VX_VALIDATION", context.temp_allocator)
	if !set {return {enabled = ODIN_DEBUG}}
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

parse_f32 :: proc(s: string) -> (f32, bool) {
	v, ok := strconv.parse_f32(s)
	return v, ok
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
