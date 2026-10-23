package client

import "core:flags"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"

import "../base"
import "../gpu"
import "../platform"

// M1 bring-up: open a window, start Vulkan, clear and draw a triangle until
// the window closes. Resizing and minimizing must work and validation (in
// debug builds) must stay silent; `--frames N` exits after N frames and
// fails the run if validation reported anything or memory leaked, for
// automated checks.

Options :: struct {
	frames:        int `usage:"exit after this many frames (0: run until closed)"`,
	capture_frame: int `usage:"when started from RenderDoc, capture this frame (1 = first)"`,
}

main :: proc() {
	dbg: base.Debug
	context = base.debug_begin(&dbg, "voxiverse.log")

	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)
	if base.PROFILE {
		path := path_next_to_exe("voxiverse.spall")
		if base.profile_start(path) {
			log.infof("profiling to %s (open with Spall: https://gravitymoth.com/spall/)", path)
		}
	}
	ok := run(opts)
	base.profile_stop()
	ok = base.debug_end(&dbg) && ok
	os.exit(0 if ok else 1)
}

// validation_options reads VX_VALIDATION: unset = on in debug builds only,
// "0" = off, otherwise a comma list of "1"/"on", "best" (best-practices
// advice) and "gpu" (GPU-assisted shader checks).
validation_options :: proc() -> gpu.Validation {
	value, set := os.lookup_env("VX_VALIDATION", context.temp_allocator)
	if !set {return {enabled = ODIN_DEBUG}}
	v: gpu.Validation
	for word in strings.split(value, ",", context.temp_allocator) {
		switch strings.trim_space(word) {
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

run :: proc(opts: Options) -> bool {
	window: platform.Window
	if !platform.window_open(&window, "Voxiverse", 1280, 720) {return false}
	defer platform.window_close(&window)

	g: gpu.Gpu
	ok := run_with_gpu(&g, &window, opts)
	if issues := gpu.destroy(&g); issues > 0 {
		log.errorf("%d validation finding(s) during this run", issues)
		return false
	}
	return ok
}

run_with_gpu :: proc(g: ^gpu.Gpu, window: ^platform.Window, opts: Options) -> bool {
	extensions := platform.vulkan_instance_extensions()
	if !gpu.create_instance(g, platform.vulkan_loader_name(), extensions, validation_options()) {
		return false
	}
	surface, surface_ok := platform.vulkan_create_surface(window, g.instance)
	if !surface_ok {
		log.error("could not create a Vulkan surface for the window")
		return false
	}
	if !gpu.init_device(g, surface) {return false}

	renderdoc: gpu.Renderdoc
	if exe_dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		capture_dir, _ := filepath.join({exe_dir, "captures"}, context.temp_allocator)
		if gpu.renderdoc_attach(&renderdoc, capture_dir, "voxiverse") {
			os.make_directory_all(capture_dir)
		}
	}
	defer gpu.renderdoc_log_captures(&renderdoc)

	triangle, pipeline_ok := create_triangle_pipeline(g, gpu.color_format(g))
	if !pipeline_ok {return false}
	defer {
		gpu.wait_idle(g)
		gpu.destroy_pipeline(g, &triangle)
	}

	frame_stats := new(base.Frame_Stats)
	defer {
		log_frame_stats(frame_stats)
		free(frame_stats)
	}
	frames := 0
	last := time.tick_now()
	for !window.close_requested {
		if opts.frames > 0 && frames >= opts.frames {break}
		free_all(context.temp_allocator)
		base.profile_scope("frame")

		{
			base.profile_scope("events")
			// Minimized: sleep until something happens instead of spinning.
			minimized := window.width <= 0 || window.height <= 0
			events := platform.wait_events(window) if minimized else platform.poll_events(window)
			for e in events {
				if k, is_key := e.(platform.Key_Event); is_key && k.pressed && k.key == .Escape {
					window.close_requested = true
				}
			}
		}
		if opts.capture_frame > 0 && frames + 1 == opts.capture_frame {
			gpu.renderdoc_capture(&renderdoc, "voxiverse")
		}
		frame: gpu.Frame
		ok: bool
		{
			// Waits for this frame slot's previous GPU work and the next image.
			base.profile_scope("begin_frame")
			frame, ok = gpu.begin_frame(g, window.width, window.height)
		}
		if !ok {continue}
		{
			base.profile_scope("draw")
			draw(g, frame, triangle)
		}
		frames += 1
		now := time.tick_now()
		base.frame_stats_add(
			frame_stats,
			f32(time.duration_milliseconds(time.tick_diff(last, now))),
		)
		last = now
	}
	return true
}

// log_frame_stats prints the run's frame times: wall clock per frame, vsync
// included. (GPU times are logged by gpu.destroy, once all are in.)
log_frame_stats :: proc(cpu: ^base.Frame_Stats) {
	s := base.frame_stats_summary(cpu)
	if s.count == 0 {return}
	log.infof(
		"frame time: %d frames, avg %.2f ms, p50 %.2f, p99 %.2f, max %.2f",
		s.count,
		s.avg,
		s.p50,
		s.p99,
		s.max,
	)
}

// path_next_to_exe places an output file beside the executable (build/ in dev).
path_next_to_exe :: proc(name: string) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return name}
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

draw :: proc(g: ^gpu.Gpu, frame: gpu.Frame, triangle: gpu.Pipeline) {
	gpu.begin_label(g, frame.cmd, "triangle")
	gpu.begin_rendering(frame, {0.02, 0.02, 0.03, 1})
	vk.CmdBindPipeline(frame.cmd, .GRAPHICS, triangle.handle)
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	gpu.end_rendering(frame)
	gpu.end_label(g, frame.cmd)
	gpu.end_frame(g, frame)
}

create_triangle_pipeline :: proc(g: ^gpu.Gpu, color_format: vk.Format) -> (gpu.Pipeline, bool) {
	vert, vert_ok := read_shader("triangle.vert.spv")
	frag, frag_ok := read_shader("triangle.frag.spv")
	if !vert_ok || !frag_ok {return {}, false}
	return gpu.create_pipeline(
		g,
		{
			name = "triangle",
			vertex_spirv = vert,
			fragment_spirv = frag,
			color_format = color_format,
		},
	)
}

// read_shader loads compiled SPIR-V from the shaders/ folder next to the
// executable (build/shaders in a dev build).
read_shader :: proc(name: string) -> ([]byte, bool) {
	exe_dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		log.errorf("cannot locate the executable: %v", err)
		return nil, false
	}
	path, _ := filepath.join({exe_dir, "shaders", name}, context.temp_allocator)
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.errorf("cannot read shader %s: %v (run `build shaders`)", path, read_err)
		return nil, false
	}
	return data, true
}
