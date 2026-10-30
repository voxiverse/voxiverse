package render

import vk "vendor:vulkan"

import "../gpu"

// Draws the sky (assets/shaders/sky.*): one screen-covering triangle after
// the world, at the far plane, so it only fills pixels the world left
// empty (it writes no depth; clouds in front of terrain are the world
// shader's).

Sky_Pass :: struct {
	pipeline: gpu.Pipeline,
}

@(private = "file")
Sky_Push :: struct {
	scene: u64,
}

sky_init :: proc(p: ^Sky_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(g, sky_pipeline_desc(g, vertex_spirv, fragment_spirv))
	return ok
}

@(private = "file")
sky_pipeline_desc :: proc(g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> gpu.Pipeline_Desc {
	return {
		name = "sky",
		vertex_spirv = vertex_spirv,
		fragment_spirv = fragment_spirv,
		color_format = gpu.color_format(g),
		depth = .Background,
	}
}

// sky_reload swaps in new shaders (hot reload); false keeps the old ones.
sky_reload :: proc(p: ^Sky_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	return gpu.replace_pipeline(g, &p.pipeline, sky_pipeline_desc(g, vertex_spirv, fragment_spirv))
}

// sky_destroy releases everything; call after gpu.wait_idle.
sky_destroy :: proc(p: ^Sky_Pass, g: ^gpu.Gpu) {
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// sky_draw draws the sky; inside rendering, after the world. scene: this
// frame's scene_upload.
sky_draw :: proc(p: ^Sky_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64) {
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "sky")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipeline.handle)
	gpu.bind_globals(g, cmd)
	push := Sky_Push{scene}
	gpu.push_constants(g, cmd, &push)
	gpu.draw(g, cmd, 3)
}
