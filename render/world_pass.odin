package render

import "core:log"
import "core:mem"
import vk "vendor:vulkan"

import "../base"
import "../gpu"

// Draws chunk meshes. Meshes are retained: each lives in a range of one
// device-local vertex buffer until removed, uploaded once through this frame
// slot's staging buffer. All quads share one static index buffer (0 1 2 0 2 3
// per quad). Removed ranges are reused only after the frames that might
// still draw them have finished.
//
// Per frame, after gpu.begin_frame:
//
//	render.world_begin(&pass, &g)
//	render.world_add_mesh(...) / world_remove_mesh(...)  // add returns .Busy when staging is full
//	render.world_upload(&pass, &g, frame)                // before begin_rendering
//	... begin_rendering ...
//	render.world_draw(&pass, &g, frame, camera)
//
// Vertices are 8 bytes (client/mesh.Vertex): positions relative to the
// chunk, which is drawn relative to the camera's chunk, so precision does
// not degrade far from the world origin.

WORLD_VERTEX_SIZE :: 8
MAX_QUADS_PER_MESH :: 16 * 16 * 16 / 2 * 6 // a 3D checkerboard: the most faces a chunk can have
CHUNK_EXTENT :: 16

Mesh_Handle :: distinct u32

Camera :: struct {
	chunk:     [3]i32, // the camera's chunk; everything below is relative to its origin
	position:  [3]f32,
	view_proj: matrix[4, 4]f32,
}

World_Settings :: struct {
	vertex_capacity: u32, // vertices in the shared buffer
	staging_size:    int, // bytes per frame slot
	fog_color:       [3]f32, // linear
	fog_distance:    f32, // blocks: fully fogged from here
}

Upload_Result :: enum {
	Ok,
	Busy, // staging full this frame: try again next frame
	Full, // vertex buffer full (logged)
}

World_Pass :: struct {
	settings:       World_Settings,
	pipeline:       gpu.Pipeline,
	vertices:       gpu.Buffer,
	ranges:         base.Range_Allocator, // in vertices
	indices:        gpu.Buffer,
	textures:       gpu.Image,
	textures_id:    gpu.Texture_Id,
	meshes:         base.Pool(Mesh, Mesh_Handle),
	frames:         [gpu.FRAMES_IN_FLIGHT]World_Frame,
	setup_pending:  []u8, // index and texture data for the first frame
	texture_layers: u32,
	stats:          World_Stats,
	full_reported:  bool,
}

World_Stats :: struct {
	meshes, drawn:  int,
	vertices_used:  u32,
	uploaded_bytes: int, // this frame
}

@(private)
Mesh :: struct {
	chunk: [3]i32,
	range: base.Range,
}

@(private)
World_Frame :: struct {
	staging:      gpu.Buffer,
	staging_used: int,
	copies:       [dynamic]vk.BufferCopy,
	freed:        [dynamic]base.Range, // reusable once this slot comes round again
}

@(private)
World_Push :: struct {
	view_proj:    matrix[4, 4]f32,
	chunk_offset: [3]f32,
	textures:     u32,
	camera:       [3]f32,
	sampler_id:   u32,
	fog:          [4]f32,
}

// world_init creates the pipeline and buffers. texture_pixels holds every
// layer's RGBA8 sRGB mip chain (layer 0 mips 0..n, layer 1 ...), from
// texture_size pixels square down to 1.
world_init :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	settings: World_Settings,
	vertex_spirv, fragment_spirv: []byte,
	texture_pixels: []u8,
	texture_size, texture_mips, texture_layers: u32,
	max_meshes: int,
	allocator := context.allocator,
) -> bool {
	p^ = {
		settings       = settings,
		texture_layers = texture_layers,
	}
	attributes := [2]gpu.Vertex_Attribute{{.R32_UINT, 0}, {.R32_UINT, 4}}
	ok: bool
	p.pipeline, ok = gpu.create_pipeline(
		g,
		{
			name = "world",
			vertex_spirv = vertex_spirv,
			fragment_spirv = fragment_spirv,
			color_format = gpu.color_format(g),
			vertex_stride = WORLD_VERTEX_SIZE,
			attributes = attributes[:],
			depth_test = true,
			cull_back = true,
		},
	)
	if !ok {return false}
	p.vertices = gpu.create_buffer(
		g,
		int(settings.vertex_capacity) * WORLD_VERTEX_SIZE,
		{.VERTEX_BUFFER, .TRANSFER_DST},
		false,
		"chunk vertices",
	) or_return
	base.range_init(&p.ranges, settings.vertex_capacity, allocator)
	p.indices = gpu.create_buffer(
		g,
		MAX_QUADS_PER_MESH * 6 * size_of(u16),
		{.INDEX_BUFFER, .TRANSFER_DST},
		false,
		"quad indices",
	) or_return
	p.textures = gpu.create_image(
		g,
		texture_size,
		texture_size,
		.R8G8B8A8_SRGB,
		{.SAMPLED, .TRANSFER_DST},
		"block textures",
		mips = texture_mips,
		layers = texture_layers,
		view_type = .D2_ARRAY,
	) or_return
	p.textures_id = gpu.register_texture(g, p.textures.view) or_return
	if base.pool_init(&p.meshes, max_meshes, allocator) != nil {return false}
	for &f, i in p.frames {
		f.staging = gpu.create_buffer(
			g,
			settings.staging_size,
			{.TRANSFER_SRC},
			true,
			i == 0 ? "world staging 0" : "world staging 1",
		) or_return
		f.copies = make([dynamic]vk.BufferCopy, allocator)
		f.freed = make([dynamic]base.Range, allocator)
	}

	// Indices and textures go up with the first frame.
	index_bytes := MAX_QUADS_PER_MESH * 6 * size_of(u16)
	p.setup_pending = make([]u8, index_bytes + len(texture_pixels), allocator)
	indices := mem.slice_data_cast([]u16, p.setup_pending[:index_bytes])
	for q in 0 ..< MAX_QUADS_PER_MESH {
		v := u16(q * 4)
		copy(indices[q * 6:], []u16{v, v + 1, v + 2, v, v + 2, v + 3})
	}
	copy(p.setup_pending[index_bytes:], texture_pixels)
	return true
}

// world_destroy releases everything; call after gpu.wait_idle.
world_destroy :: proc(p: ^World_Pass, g: ^gpu.Gpu) {
	for &f in p.frames {
		gpu.destroy_buffer(g, &f.staging)
		delete(f.copies)
		delete(f.freed)
	}
	delete(p.setup_pending)
	base.pool_destroy(&p.meshes)
	base.range_destroy(&p.ranges)
	if p.textures.handle != 0 {gpu.unregister_texture(g, p.textures_id)}
	gpu.destroy_image(g, &p.textures)
	gpu.destroy_buffer(g, &p.indices)
	gpu.destroy_buffer(g, &p.vertices)
	gpu.destroy_pipeline(g, &p.pipeline)
	p^ = {}
}

// world_begin starts this frame slot's uploads: its staging buffer is free
// again, and ranges removed when the slot was last used can be reused.
world_begin :: proc(p: ^World_Pass, g: ^gpu.Gpu) {
	f := &p.frames[gpu.frame_slot(g)]
	f.staging_used = 0
	clear(&f.copies)
	for r in f.freed {base.range_free(&p.ranges, r)}
	clear(&f.freed)
	p.stats.uploaded_bytes = 0
}

// world_add_mesh uploads a chunk's vertices (a multiple of 4, at most
// MAX_QUADS_PER_MESH quads) and returns its handle.
world_add_mesh :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	chunk: [3]i32,
	vertices: []u8,
) -> (
	handle: Mesh_Handle,
	result: Upload_Result,
) {
	count := u32(len(vertices) / WORLD_VERTEX_SIZE)
	assert(
		len(vertices) % (4 * WORLD_VERTEX_SIZE) == 0 &&
		count > 0 &&
		count / 4 <= MAX_QUADS_PER_MESH,
	)
	f := &p.frames[gpu.frame_slot(g)]
	if f.staging_used + len(vertices) > f.staging.size {return 0, .Busy}
	r, ok := base.range_alloc(&p.ranges, count)
	if !ok {
		if !p.full_reported {
			log.errorf(
				"render: chunk vertex buffer full (%d of %d vertices used); raise vertex_capacity",
				p.ranges.used,
				p.ranges.capacity,
			)
			p.full_reported = true
		}
		return 0, .Full
	}
	h, _, added := base.pool_add(&p.meshes, Mesh{chunk, r})
	if !added {
		base.range_free(&p.ranges, r)
		log.error("render: too many chunk meshes")
		return 0, .Full
	}
	copy(f.staging.mapped[f.staging_used:][:len(vertices)], vertices)
	append(
		&f.copies,
		vk.BufferCopy {
			srcOffset = vk.DeviceSize(f.staging_used),
			dstOffset = vk.DeviceSize(r.offset) * WORLD_VERTEX_SIZE,
			size = vk.DeviceSize(len(vertices)),
		},
	)
	f.staging_used += len(vertices)
	p.stats.uploaded_bytes += len(vertices)
	return h, .Ok
}

// world_remove_mesh stops drawing the mesh; its memory is reused once the
// GPU is done with it.
world_remove_mesh :: proc(p: ^World_Pass, g: ^gpu.Gpu, h: Mesh_Handle) {
	m := base.pool_get(&p.meshes, h)
	if m == nil {return}
	append(&p.frames[gpu.frame_slot(g)].freed, m.range)
	base.pool_remove(&p.meshes, h)
}

// world_upload records this frame's copies. Call before begin_rendering.
world_upload :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame) -> bool {
	f := &p.frames[gpu.frame_slot(g)]
	cmd := frame.cmd
	if p.setup_pending != nil {
		upload_setup(p, f, cmd) or_return
	}
	if len(f.copies) == 0 {return true}
	gpu.begin_label(g, cmd, "upload chunk meshes")
	defer gpu.end_label(g, cmd)
	// Ranges being written were last drawn by finished frames; still order
	// the copies after vertex fetches, for the validation layer's sake.
	before := vk.MemoryBarrier2 {
		sType        = .MEMORY_BARRIER_2,
		srcStageMask = {.VERTEX_ATTRIBUTE_INPUT},
		dstStageMask = {.COPY},
	}
	after := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.VERTEX_ATTRIBUTE_INPUT},
		dstAccessMask = {.VERTEX_ATTRIBUTE_READ},
	}
	dep := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &before,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
	vk.CmdCopyBuffer(
		cmd,
		f.staging.handle,
		p.vertices.handle,
		u32(len(f.copies)),
		raw_data(f.copies),
	)
	dep.pMemoryBarriers = &after
	vk.CmdPipelineBarrier2(cmd, &dep)
	return true
}

@(private = "file")
upload_setup :: proc(p: ^World_Pass, f: ^World_Frame, cmd: vk.CommandBuffer) -> bool {
	data := p.setup_pending
	if f.staging_used + len(data) > f.staging.size {
		log.errorf(
			"render: world staging (%d bytes) too small for setup data (%d)",
			f.staging.size,
			len(data),
		)
		return false
	}
	base_offset := f.staging_used
	copy(f.staging.mapped[base_offset:][:len(data)], data)
	f.staging_used += len(data)

	index_bytes := MAX_QUADS_PER_MESH * 6 * size_of(u16)
	index_copy := vk.BufferCopy {
		srcOffset = vk.DeviceSize(base_offset),
		size      = vk.DeviceSize(index_bytes),
	}
	vk.CmdCopyBuffer(cmd, f.staging.handle, p.indices.handle, 1, &index_copy)
	index_barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.INDEX_INPUT},
		dstAccessMask = {.INDEX_READ},
	}
	dep := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &index_barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)

	regions := make([dynamic]vk.BufferImageCopy, context.temp_allocator)
	offset := base_offset + index_bytes
	for layer in 0 ..< p.texture_layers {
		size := p.textures.width
		for mip in 0 ..< p.textures.mips {
			append(
				&regions,
				vk.BufferImageCopy {
					bufferOffset = vk.DeviceSize(offset),
					imageSubresource = {
						aspectMask = {.COLOR},
						mipLevel = mip,
						baseArrayLayer = layer,
						layerCount = 1,
					},
					imageExtent = {size, size, 1},
				},
			)
			offset += int(size * size * 4)
			size = max(size / 2, 1)
		}
	}
	assert(
		offset == base_offset + len(data),
		"texture data size does not match its mips and layers",
	)
	gpu.upload_image(cmd, f.staging, p.textures, regions[:])
	delete(p.setup_pending)
	p.setup_pending = nil
	return true
}

// world_draw draws every mesh in the camera's view. Call inside rendering.
world_draw :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame, camera: Camera) {
	p.stats.meshes = p.meshes.count
	p.stats.vertices_used = p.ranges.used
	p.stats.drawn = 0
	if p.meshes.count == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "world")
	defer gpu.end_label(g, cmd)
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipeline.handle)
	gpu.bind_globals(g, cmd)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &p.vertices.handle, &offset)
	vk.CmdBindIndexBuffer(cmd, p.indices.handle, 0, .UINT16)
	planes := frustum_planes(camera.view_proj)
	push := World_Push {
		view_proj  = camera.view_proj,
		textures   = u32(p.textures_id),
		camera     = camera.position,
		sampler_id = u32(gpu.Sampler.Pixel_Art),
		fog        = {
			p.settings.fog_color.r,
			p.settings.fog_color.g,
			p.settings.fog_color.b,
			p.settings.fog_distance,
		},
	}
	it: base.Pool_Iterator
	for m in base.pool_next(&p.meshes, &it) {
		origin := (m.chunk - camera.chunk) * CHUNK_EXTENT
		lo := [3]f32{f32(origin.x), f32(origin.y), f32(origin.z)}
		if !box_visible(&planes, lo, lo + CHUNK_EXTENT) {continue}
		push.chunk_offset = lo
		gpu.push_constants(g, cmd, &push)
		vk.CmdDrawIndexed(cmd, m.range.size / 4 * 6, 1, 0, i32(m.range.offset), 0)
		p.stats.drawn += 1
	}
}

// Frustum planes (a, b, c, d) with a·x + b·y + c·z + d >= 0 inside: left,
// right, bottom, top, near (Vulkan clip space, reverse Z with an infinite
// far plane, so there is no far plane).
@(private)
Planes :: [5][4]f32

@(private)
frustum_planes :: proc(m: matrix[4, 4]f32) -> (planes: Planes) {
	row :: proc(m: matrix[4, 4]f32, i: int) -> [4]f32 {
		return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}
	}
	r0, r1, r2, r3 := row(m, 0), row(m, 1), row(m, 2), row(m, 3)
	planes = {r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 - r2}
	return
}

// box_visible: the box is not entirely outside any plane.
@(private)
box_visible :: proc(planes: ^Planes, lo, hi: [3]f32) -> bool {
	for pl in planes {
		// The box corner furthest along the plane's normal.
		far := [3]f32{pl.x >= 0 ? hi.x : lo.x, pl.y >= 0 ? hi.y : lo.y, pl.z >= 0 ? hi.z : lo.z}
		if pl.x * far.x + pl.y * far.y + pl.z * far.z + pl.w < 0 {return false}
	}
	return true
}
