package client

import "core:flags"
import "core:log"
import "core:os"
import "core:path/filepath"
import vk "vendor:vulkan"

import "../gpu"
import "../platform"

// M1 bring-up: open a window, start Vulkan, clear and draw a triangle until
// the window closes. Resizing and minimizing must work and validation (in
// debug builds) must stay silent; `--frames N` exits after N frames and
// fails the run if validation reported anything, for automated checks.

Options :: struct {
	frames: int `usage:"exit after this many frames (0: run until closed)"`,
}

main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)

	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)
	ok := run(opts)
	log.destroy_console_logger(context.logger)
	os.exit(0 if ok else 1)
}

run :: proc(opts: Options) -> bool {
	window: platform.Window
	if !platform.window_open(&window, "Voxiverse", 1280, 720) {return false}
	defer platform.window_close(&window)

	g: gpu.Gpu
	defer gpu.destroy(&g)
	validation := ODIN_DEBUG || os.get_env("VX_VALIDATION", context.temp_allocator) == "1"
	if !gpu.create_instance(
		&g,
		platform.vulkan_loader_name(),
		platform.vulkan_instance_extensions(),
		validation,
	) {
		return false
	}
	surface, surface_ok := platform.vulkan_create_surface(&window, g.instance)
	if !surface_ok {
		log.error("could not create a Vulkan surface for the window")
		return false
	}
	if !gpu.init_device(&g, surface) {return false}

	triangle, pipeline_ok := create_triangle_pipeline(&g, gpu.color_format(&g))
	if !pipeline_ok {return false}
	defer {
		gpu.wait_idle(&g)
		gpu.destroy_pipeline(&g, &triangle)
	}
	frames := 0

	for !window.close_requested {
		if opts.frames > 0 && frames >= opts.frames {break}
		free_all(context.temp_allocator)

		// Minimized: sleep until something happens instead of spinning.
		events :=
			platform.poll_events(&window) if window.width > 0 && window.height > 0 else platform.wait_events(&window)
		for e in events {
			if k, is_key := e.(platform.Key_Event); is_key && k.pressed && k.key == .Escape {
				window.close_requested = true
			}
		}
		frame, ok := gpu.begin_frame(&g, window.width, window.height)
		if !ok {continue}
		draw(&g, frame, triangle)
		frames += 1
	}

	if g.validation_issues > 0 {
		log.errorf("%d validation message(s) during this run", g.validation_issues)
		return false
	}
	return true
}

draw :: proc(g: ^gpu.Gpu, frame: gpu.Frame, triangle: gpu.Pipeline) {
	gpu.begin_rendering(frame, {0.02, 0.02, 0.03, 1})
	vk.CmdBindPipeline(frame.cmd, .GRAPHICS, triangle.handle)
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	gpu.end_rendering(frame)
	gpu.end_frame(g, frame)
}

create_triangle_pipeline :: proc(g: ^gpu.Gpu, color_format: vk.Format) -> (gpu.Pipeline, bool) {
	vert, vert_ok := read_shader("triangle.vert.spv")
	frag, frag_ok := read_shader("triangle.frag.spv")
	if !vert_ok || !frag_ok {return {}, false}
	return gpu.create_pipeline(
		g,
		{vertex_spirv = vert, fragment_spirv = frag, color_format = color_format},
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
