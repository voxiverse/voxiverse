package render

import "core:mem"
import vk "vendor:vulkan"

import "../gpu"

// Debug drawing: lines and boxes in world space, collected during the frame
// from anywhere on the main thread and drawn over the world (hidden behind
// geometry, never hiding it). Cleared after every frame.
//
//	render.debug_box(&dd, lo, hi, render.YELLOW)
//	...
//	render.debug_upload(&pass, &g, &dd, camera)       // before begin_rendering
//	render.debug_draw(&pass, &g, frame, camera)       // after world_draw

Debug_Draw :: struct {
	vertices: [dynamic]Debug_Point, // world positions, pairs make lines
}

Debug_Point :: struct {
	pos:   [3]f64,
	color: [4]u8, // sRGB
}

BLUE :: [4]u8{70, 130, 240, 255}
YELLOW :: [4]u8{250, 220, 60, 255}

debug_draw_init :: proc(d: ^Debug_Draw, allocator := context.allocator) {
	d.vertices = make([dynamic]Debug_Point, allocator)
}

debug_draw_destroy :: proc(d: ^Debug_Draw) {
	delete(d.vertices)
}

debug_line :: proc(d: ^Debug_Draw, a, b: [3]f64, color: [4]u8) {
	append(&d.vertices, Debug_Point{a, color}, Debug_Point{b, color})
}

// debug_box outlines the box from lo to hi (12 edges).
debug_box :: proc(d: ^Debug_Draw, lo, hi: [3]f64, color: [4]u8) {
	c := [8][3]f64 {
		{lo.x, lo.y, lo.z},
		{hi.x, lo.y, lo.z},
		{hi.x, lo.y, hi.z},
		{lo.x, lo.y, hi.z},
		{lo.x, hi.y, lo.z},
		{hi.x, hi.y, lo.z},
		{hi.x, hi.y, hi.z},
		{lo.x, hi.y, hi.z},
	}
	for i in 0 ..< 4 {
		debug_line(d, c[i], c[(i + 1) % 4], color) // bottom
		debug_line(d, c[4 + i], c[4 + (i + 1) % 4], color) // top
		debug_line(d, c[i], c[4 + i], color) // sides
	}
}

Debug_Pass :: struct {
	pipeline: gpu.Pipeline,
	frames:   [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
	counts:   [gpu.FRAMES_IN_FLIGHT]u32,
}

@(private)
Debug_Vertex :: struct {
	pos:   [3]f32, // relative to the camera's chunk
	color: [4]u8,
}

debug_init :: proc(p: ^Debug_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(g, debug_pipeline_desc(g, vertex_spirv, fragment_spirv))
	return ok
}

@(private = "file", rodata)
DEBUG_ATTRIBUTES := [2]gpu.Vertex_Attribute {
	{.R32G32B32_SFLOAT, u32(offset_of(Debug_Vertex, pos))},
	{.R8G8B8A8_UNORM, u32(offset_of(Debug_Vertex, color))},
}

@(private = "file")
debug_pipeline_desc :: proc(
	g: ^gpu.Gpu,
	vertex_spirv, fragment_spirv: []byte,
) -> gpu.Pipeline_Desc {
	return {
		name = "debug lines",
		vertex_spirv = vertex_spirv,
		fragment_spirv = fragment_spirv,
		color_format = gpu.color_format(g),
		vertex_stride = size_of(Debug_Vertex),
		attributes = DEBUG_ATTRIBUTES[:],
		alpha_blend = true,
		depth = .Test,
		lines = true,
	}
}

// debug_reload swaps in new shaders (hot reload); false keeps the old ones.
debug_reload :: proc(p: ^Debug_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	return gpu.replace_pipeline(
		g,
		&p.pipeline,
		debug_pipeline_desc(g, vertex_spirv, fragment_spirv),
	)
}

// debug_destroy releases everything; call after gpu.wait_idle.
debug_destroy :: proc(p: ^Debug_Pass, g: ^gpu.Gpu) {
	for &b in p.frames {gpu.destroy_buffer(g, &b)}
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// debug_upload copies this frame's lines (relative to the camera's chunk)
// and clears d for the next frame.
debug_upload :: proc(p: ^Debug_Pass, g: ^gpu.Gpu, d: ^Debug_Draw, camera: Camera) -> bool {
	slot := gpu.frame_slot(g)
	defer clear(&d.vertices)
	p.counts[slot] = 0
	if len(d.vertices) == 0 {return true}
	size := len(d.vertices) * size_of(Debug_Vertex)
	ensure_buffer(g, &p.frames[slot], size, {.VERTEX_BUFFER}, "debug lines") or_return
	out := mem.slice_data_cast([]Debug_Vertex, p.frames[slot].mapped[:size])
	origin := [3]f64{f64(camera.chunk.x), f64(camera.chunk.y), f64(camera.chunk.z)} * CHUNK_EXTENT
	for v, i in d.vertices {
		rel := v.pos - origin
		out[i] = {{f32(rel.x), f32(rel.y), f32(rel.z)}, v.color}
	}
	p.counts[slot] = u32(len(d.vertices))
	return true
}

// debug_draw draws the uploaded lines; inside rendering, after the world.
debug_draw :: proc(p: ^Debug_Pass, g: ^gpu.Gpu, frame: gpu.Frame, camera: Camera) {
	slot := gpu.frame_slot(g)
	if p.counts[slot] == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "debug lines")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipeline.handle)
	gpu.bind_globals(g, cmd)
	view_proj := camera.view_proj
	gpu.push_constants(g, cmd, &view_proj)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &p.frames[slot].handle, &offset)
	gpu.draw(g, cmd, p.counts[slot], lines = true)
}
