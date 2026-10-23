package client

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"

import "../base"
import "../font"
import "../gpu"
import "../platform"
import "../render"
import "../ui"

// App is everything that lives for the whole process: window, GPU, UI, the
// console, settings. Created and destroyed in one place (app_init /
// app_destroy, in reverse order). A world session will be a separate object
// with its own lifetime (M3).

FONT_DATA :: #load("../assets/fonts/jetbrains_mono_regular.ttf")

Screen :: enum u8 {
	Title,
	Options,
}

Settings :: struct {
	ui_scale:         f32, // 0 = automatic
	show_frame_times: bool,
}

App :: struct {
	window:        platform.Window,
	g:             gpu.Gpu,
	renderdoc:     gpu.Renderdoc,
	font:          font.Font,
	ui:            ui.Context,
	ui_pass:       render.Ui_Pass,
	console:       Console,
	input:         Input_State,
	settings:      Settings,
	screen:        Screen,
	quit_dialog:   bool,
	quit:          bool,
	frame_stats:   base.Frame_Stats,
	last_frame_ms: f32,
}

// app_init brings everything up; on failure the caller still calls
// app_destroy, which handles partially initialised apps.
app_init :: proc(app: ^App) -> bool {
	console_init(&app.console)
	register_builtin_commands(&app.console)

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
	return render.ui_init(&app.ui_pass, g, vert, frag)
}

// app_destroy tears down in reverse and returns the Vulkan validation
// findings count (read after the GPU is gone; see gpu.destroy).
app_destroy :: proc(app: ^App) -> (validation_issues: int) {
	if app.g.device != nil {
		gpu.wait_idle(&app.g)
		gpu.renderdoc_log_captures(&app.renderdoc)
		render.ui_destroy(&app.ui_pass, &app.g)
	}
	ui.destroy(&app.ui)
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
	if !ok {return true}
	{
		base.profile_scope("record")
		g := &app.g
		render.ui_upload(&app.ui_pass, g, frame, &app.ui.output)
		gpu.begin_rendering(frame, {0, 0, 0, 1})
		render.ui_draw(&app.ui_pass, g, frame, &app.ui.output)
		gpu.end_rendering(frame)
		gpu.end_frame(g, frame)
	}
	return true
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
