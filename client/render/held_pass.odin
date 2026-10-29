package render

import "core:mem"
import vk "vendor:vulkan"

import "../gpu"

// What the hands hold (client/viewmodel*.odin): small meshes, a few hundred
// vertices, transformed on the CPU each frame into a mapped buffer like the
// entity pass's. Two lists, two draws:
//
//	view:  first person's view model, positions in view space (the camera at the
//	       origin, looking down -z); drawn with a scene of its own (a fixed
//	       field of view), after the depth buffer is cleared, so it never clips
//	       into a wall
//	world: the third person's held items, positions near a base in the world;
//	       drawn with the world's scene, depth tested against it
//
// A vertex is a flat colour (a voxel, an arm) or a layer of the block texture
// array (a held block's own faces), lit by the sky and the brightness setting.
//
//	render.held_upload(&pass, &g, &draw, camera)            // before begin_rendering
//	render.held_draw_world(&pass, &g, frame, scene, textures)
//	render.held_draw_view(&pass, &g, frame, view_scene, textures)

HELD_FLAT :: u16(0xFFFF) // Held_Vertex.layer: a flat colour, not a texture

Held_Vertex :: struct {
	pos:   [3]f32,
	uv:    [2]f32, // in blocks (a texture repeats once a block)
	color: [4]u8, // sRGB, for flat vertices
	layer: u16, // texture array layer, or HELD_FLAT
	shade: u8, // 0..255: how much light this face gets
	_:     u8,
}

// Held_Batch: some vertices of the world list, positioned from `base`.
Held_Batch :: struct {
	base:  [3]f64,
	count: int,
}

Held_Draw :: struct {
	view:    [dynamic]Held_Vertex,
	world:   [dynamic]Held_Vertex,
	batches: [dynamic]Held_Batch,
}

Held_Pass :: struct {
	pipeline:   gpu.Pipeline,
	view_bufs:  [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
	world_bufs: [gpu.FRAMES_IN_FLIGHT]gpu.Buffer,
	view_n:     [gpu.FRAMES_IN_FLIGHT]u32,
	world_n:    [gpu.FRAMES_IN_FLIGHT]u32,
	scenes:     Scene_Buffers, // the view model's own scene
}

@(private = "file")
Held_Push :: struct {
	scene:      u64,
	textures:   u32,
	sampler_id: u32,
}

held_draw_init :: proc(d: ^Held_Draw, allocator := context.allocator) {
	d.view = make([dynamic]Held_Vertex, allocator)
	d.world = make([dynamic]Held_Vertex, allocator)
	d.batches = make([dynamic]Held_Batch, allocator)
}

held_draw_destroy :: proc(d: ^Held_Draw) {
	delete(d.view)
	delete(d.world)
	delete(d.batches)
}

// held_draw_clear: for the next frame.
held_draw_clear :: proc(d: ^Held_Draw) {
	clear(&d.view)
	clear(&d.world)
	clear(&d.batches)
}

// held_empty: nothing to draw this frame.
held_empty :: proc(d: ^Held_Draw) -> bool {
	return len(d.view) == 0 && len(d.world) == 0
}

// held_world_begin starts a batch of world vertices near `base`; the vertices
// appended to d.world after it (positions from base) belong to it.
held_world_begin :: proc(d: ^Held_Draw, base: [3]f64) {
	append(&d.batches, Held_Batch{base = base})
}

// held_world_add: one vertex of the current batch.
held_world_add :: proc(d: ^Held_Draw, v: Held_Vertex) {
	append(&d.world, v)
	d.batches[len(d.batches) - 1].count += 1
}

held_init :: proc(p: ^Held_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(g, held_pipeline_desc(g, vertex_spirv, fragment_spirv))
	if !ok {return false}
	return scene_init(&p.scenes, g)
}

@(private = "file", rodata)
HELD_ATTRIBUTES := [4]gpu.Vertex_Attribute {
	{.R32G32B32_SFLOAT, u32(offset_of(Held_Vertex, pos))},
	{.R32G32_SFLOAT, u32(offset_of(Held_Vertex, uv))},
	{.R8G8B8A8_UNORM, u32(offset_of(Held_Vertex, color))},
	{.R32_UINT, u32(offset_of(Held_Vertex, layer))},
}

@(private = "file")
held_pipeline_desc :: proc(
	g: ^gpu.Gpu,
	vertex_spirv, fragment_spirv: []byte,
) -> gpu.Pipeline_Desc {
	return {
		name = "held",
		vertex_spirv = vertex_spirv,
		fragment_spirv = fragment_spirv,
		color_format = gpu.color_format(g),
		vertex_stride = size_of(Held_Vertex),
		attributes = HELD_ATTRIBUTES[:],
		depth = .Test_Write,
	}
}

held_reload :: proc(p: ^Held_Pass, g: ^gpu.Gpu, vertex_spirv, fragment_spirv: []byte) -> bool {
	return gpu.replace_pipeline(
		g,
		&p.pipeline,
		held_pipeline_desc(g, vertex_spirv, fragment_spirv),
	)
}

held_destroy :: proc(p: ^Held_Pass, g: ^gpu.Gpu) {
	for &b in p.view_bufs {gpu.destroy_buffer(g, &b)}
	for &b in p.world_bufs {gpu.destroy_buffer(g, &b)}
	scene_destroy(&p.scenes, g)
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// held_view_scene uploads the view model's scene (its own projection, the
// world's light) and returns its address; call it once a frame.
held_view_scene :: proc(p: ^Held_Pass, g: ^gpu.Gpu, scene: Scene) -> u64 {
	return scene_upload(&p.scenes, g, scene)
}

// held_upload writes this frame's vertices (the world list from the camera's
// chunk's origin) and clears d.
held_upload :: proc(p: ^Held_Pass, g: ^gpu.Gpu, d: ^Held_Draw, camera: Camera) -> bool {
	slot := gpu.frame_slot(g)
	defer held_draw_clear(d)
	p.view_n[slot], p.world_n[slot] = 0, 0
	if len(d.view) > 0 {
		size := len(d.view) * size_of(Held_Vertex)
		ensure_buffer(
			g,
			&p.view_bufs[slot],
			size,
			{.VERTEX_BUFFER},
			"held view vertices",
		) or_return
		mem.copy(p.view_bufs[slot].mapped, raw_data(d.view[:]), size)
		p.view_n[slot] = u32(len(d.view))
	}
	if len(d.world) > 0 {
		size := len(d.world) * size_of(Held_Vertex)
		ensure_buffer(
			g,
			&p.world_bufs[slot],
			size,
			{.VERTEX_BUFFER},
			"held world vertices",
		) or_return
		out := mem.slice_data_cast([]Held_Vertex, p.world_bufs[slot].mapped[:size])
		origin :=
			[3]f64{f64(camera.chunk.x), f64(camera.chunk.y), f64(camera.chunk.z)} * CHUNK_EXTENT
		n := 0
		for b in d.batches {
			at := b.base - origin
			shift := [3]f32{f32(at.x), f32(at.y), f32(at.z)}
			for i in n ..< n + b.count {
				out[i] = d.world[i]
				out[i].pos += shift
			}
			n += b.count
		}
		p.world_n[slot] = u32(len(d.world))
	}
	return true
}

held_draw_world :: proc(p: ^Held_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64, textures: u32) {
	slot := gpu.frame_slot(g)
	if p.world_n[slot] == 0 {return}
	held_record(p, g, frame, scene, textures, &p.world_bufs[slot], p.world_n[slot])
}

// held_draw_view draws the view model over everything: the depth buffer is
// cleared first.
held_draw_view :: proc(p: ^Held_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64, textures: u32) {
	slot := gpu.frame_slot(g)
	if p.view_n[slot] == 0 {return}
	gpu.clear_depth(frame)
	held_record(p, g, frame, scene, textures, &p.view_bufs[slot], p.view_n[slot])
}

@(private = "file")
held_record :: proc(
	p: ^Held_Pass,
	g: ^gpu.Gpu,
	frame: gpu.Frame,
	scene: u64,
	textures: u32,
	buffer: ^gpu.Buffer,
	count: u32,
) {
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "held")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipeline.handle)
	gpu.bind_globals(g, cmd)
	push := Held_Push{scene, textures, u32(gpu.Sampler.Pixel_Art)}
	gpu.push_constants(g, cmd, &push)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &buffer.handle, &offset)
	vk.CmdDraw(cmd, count, 1, 0, 0)
}
