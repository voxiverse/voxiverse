package render

import "core:mem"
import vk "vendor:vulkan"

import "../gpu"
import "../ui"

// Draws a ui.Output. Per frame slot it owns a vertex, an index and a
// staging buffer (grown as needed: begin_frame has waited for the slot's
// previous use, so they are free to rewrite). Changed glyph-atlas rows are
// copied in the frame's own command buffer.
//
//	render.ui_upload(&pass, &g, frame, &ui_ctx.output) // before begin_rendering
//	... begin_rendering ...
//	render.ui_draw(&pass, &g, frame, &ui_ctx.output)

Ui_Pass :: struct {
	pipeline:       gpu.Pipeline,
	atlas:          gpu.Image,
	atlas_id:       gpu.Texture_Id,
	atlas_uploaded: bool,
	images:         [8]gpu.Texture_Id, // by ui.Image (0 unused: the atlas); set by the owner of each picture
	frames:         [gpu.FRAMES_IN_FLIGHT]Ui_Frame,
}

@(private)
Ui_Frame :: struct {
	vertices, indices, staging: gpu.Buffer,
}

@(private)
Ui_Push :: struct {
	screen_size: [2]f32,
	atlas:       u32,
	sampler_id:  u32,
	linear:      u32, // 1: the texels are already linear light (a rendered picture)
}

ui_init :: proc(p: ^Ui_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(g, ui_pipeline_desc(g, vertex_spirv, fragment_spirv))
	if !ok {return false}
	size := u32(ui.GLYPH_ATLAS_SIZE)
	p.atlas = gpu.create_image(
		g,
		size,
		size,
		.R8G8B8A8_UNORM,
		{.SAMPLED, .TRANSFER_DST},
		"ui atlas",
	) or_return
	p.atlas_id = gpu.register_texture(g, p.atlas.view) or_return
	return true
}

@(private = "file", rodata)
UI_ATTRIBUTES := [3]gpu.Vertex_Attribute {
	{.R32G32_SFLOAT, u32(offset_of(ui.Vertex, pos))},
	{.R32G32_SFLOAT, u32(offset_of(ui.Vertex, uv))},
	{.R8G8B8A8_UNORM, u32(offset_of(ui.Vertex, color))},
}

@(private = "file")
ui_pipeline_desc :: proc(g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> gpu.Pipeline_Desc {
	return {
		name = "ui",
		vertex_spirv = vertex_spirv,
		fragment_spirv = fragment_spirv,
		color_format = gpu.color_format(g),
		vertex_stride = size_of(ui.Vertex),
		attributes = UI_ATTRIBUTES[:],
		alpha_blend = true,
	}
}

// ui_reload swaps in new shaders (hot reload); false keeps the old ones.
ui_reload :: proc(p: ^Ui_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	return gpu.replace_pipeline(g, &p.pipeline, ui_pipeline_desc(g, vertex_spirv, fragment_spirv))
}

// ui_destroy releases everything; call after gpu.wait_idle.
ui_destroy :: proc(p: ^Ui_Pass, g: ^gpu.Gpu) {
	for &f in p.frames {
		gpu.destroy_buffer(g, &f.vertices)
		gpu.destroy_buffer(g, &f.indices)
		gpu.destroy_buffer(g, &f.staging)
	}
	if p.atlas.handle != 0 {gpu.unregister_texture(g, p.atlas_id)}
	gpu.destroy_image(g, &p.atlas)
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// ui_upload copies this frame's vertices and indices and any changed atlas
// rows. Record before begin_rendering.
ui_upload :: proc(p: ^Ui_Pass, g: ^gpu.Gpu, frame: gpu.Frame, out: ^ui.Output) -> bool {
	f := &p.frames[gpu.frame_slot(g)]
	rows := out.atlas_dirty_rows
	if !p.atlas_uploaded {rows = {0, out.atlas_size}}
	if rows[1] > rows[0] {
		start, end := rows[0] * out.atlas_size * 4, rows[1] * out.atlas_size * 4
		ensure_buffer(g, &f.staging, end - start, {.TRANSFER_SRC}, "ui atlas staging") or_return
		copy(f.staging.mapped[:end - start], out.atlas_pixels[start:end])
		from: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL if p.atlas_uploaded else .UNDEFINED
		gpu.copy_to_image(frame.cmd, f.staging, p.atlas, u32(rows[0]), u32(rows[1]), from)
		p.atlas_uploaded = true
	}
	if len(out.indices) == 0 {return true}
	vertex_bytes := len(out.vertices) * size_of(ui.Vertex)
	index_bytes := len(out.indices) * size_of(u32)
	ensure_buffer(g, &f.vertices, vertex_bytes, {.VERTEX_BUFFER}, "ui vertices") or_return
	ensure_buffer(g, &f.indices, index_bytes, {.INDEX_BUFFER}, "ui indices") or_return
	mem.copy(f.vertices.mapped, raw_data(out.vertices), vertex_bytes)
	mem.copy(f.indices.mapped, raw_data(out.indices), index_bytes)
	return true
}

// ui_draw records the draw commands. Call inside rendering, after ui_upload.
ui_draw :: proc(p: ^Ui_Pass, g: ^gpu.Gpu, frame: gpu.Frame, out: ^ui.Output) {
	if len(out.commands) == 0 || !p.atlas_uploaded {return}
	f := &p.frames[gpu.frame_slot(g)]
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "ui")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipeline.handle)
	gpu.bind_globals(g, cmd)
	push := Ui_Push {
		screen_size = {f32(frame.extent.width), f32(frame.extent.height)},
		atlas       = u32(p.atlas_id),
		sampler_id  = u32(gpu.Sampler.Nearest),
	}
	gpu.push_constants(g, cmd, &push)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &f.vertices.handle, &offset)
	vk.CmdBindIndexBuffer(cmd, f.indices.handle, 0, .UINT32)
	for c in out.commands {
		// Scissor must lie within the framebuffer.
		x0 := clamp(c.scissor[0], 0, i32(frame.extent.width))
		y0 := clamp(c.scissor[1], 0, i32(frame.extent.height))
		x1 := clamp(c.scissor[0] + c.scissor[2], 0, i32(frame.extent.width))
		y1 := clamp(c.scissor[1] + c.scissor[3], 0, i32(frame.extent.height))
		if x1 <= x0 || y1 <= y0 {continue}
		scissor := vk.Rect2D{{x0, y0}, {u32(x1 - x0), u32(y1 - y0)}}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		atlas, linear := u32(p.atlas_id), u32(0)
		if c.image != 0 && int(c.image) < len(p.images) && p.images[c.image] != 0 {
			atlas, linear = u32(p.images[c.image]), 1
		}
		if atlas != push.atlas || linear != push.linear {
			push.atlas, push.linear = atlas, linear
			gpu.push_constants(g, cmd, &push)
		}
		sampler := gpu.Sampler.Linear if c.smooth else gpu.Sampler.Nearest
		if u32(sampler) != push.sampler_id {
			push.sampler_id = u32(sampler)
			gpu.push_constants(g, cmd, &push)
		}
		vk.CmdDrawIndexed(cmd, c.index_count, 1, c.first_index, 0, 0)
	}
	full := vk.Rect2D {
		extent = frame.extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &full) // leave state as begin_rendering set it
}

// ensure_buffer grows a host-visible buffer to at least size bytes.
@(private)
ensure_buffer :: proc(
	g: ^gpu.Gpu,
	b: ^gpu.Buffer,
	size: int,
	usage: vk.BufferUsageFlags,
	name: string,
) -> bool {
	if b.size >= size {return true}
	gpu.destroy_buffer(g, b)
	new_size := max(size + size / 2, 64 * 1024)
	ok: bool
	b^, ok = gpu.create_buffer(g, new_size, usage, true, name)
	return ok
}
