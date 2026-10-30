package render

import "core:log"
import "core:mem"
import vk "vendor:vulkan"

import "../../base"
import "../gpu"

// Draws chunk meshes. Meshes are retained: each lives in a range of one
// device-local vertex buffer until removed, uploaded once through this frame
// slot's staging buffer. All quads share one static index buffer (0 1 2 0 2 3
// per quad). Removed ranges are reused only after the frames that might
// still draw them have finished.
//
// A mesh holds three layers one after another in its range, each drawn by
// its own pipeline: opaque, cutout (alpha-tested: leaves, plants) and
// translucent (water: blended, without writing depth, after everything
// else, the farthest chunks first).
//
// Per frame, after gpu.begin_frame:
//
//	render.world_begin(&pass, &g)
//	render.world_add_mesh(...) / world_remove_mesh(...)  // add returns .Busy when staging is full
//	render.world_upload(&pass, &g, frame)                // before begin_rendering
//	render.world_cull(&pass, &g, camera)                 // the draw commands
//	... begin_rendering ...
//	render.world_draw(&pass, &g, frame, scene)           // opaque, cutout
//	... entities, sky ...
//	render.world_draw_translucent(&pass, &g, frame, scene, time)
//
// Vertices are 8 bytes (client/mesh.Vertex): positions relative to the
// chunk, which is drawn relative to the camera's chunk, so precision does
// not degrade far from the world origin.
//
// Drawing is indirect. The chunk draw table holds one Chunk_Draw per mesh,
// at its pool slot; world.vert reads it as a per-instance attribute, so a
// command's firstInstance (the mesh's slot) picks its chunk. world_cull
// culls on the CPU and writes one vk.DrawIndexedIndirectCommand per run of
// visible face groups into this frame slot's indirect buffer; each layer is
// then one vkCmdDrawIndexedIndirect. (Vertices come through vertex input,
// not pulled by address: on the development machine's GPU pulling cost the
// world pass 5-10%; R8's quad records bring pulling, with their own check.)

WORLD_VERTEX_SIZE :: 8
// The most quads one layer of a chunk can have: every face of every block
// (a chunk full of leaves, whose faces show through each other).
MAX_QUADS_PER_LAYER :: 16 * 16 * 16 * 6
CHUNK_EXTENT :: 16

Mesh_Handle :: distinct u32

// Chunk_Draw: a mesh's record in the chunk draw table (world.vert's
// in_chunk): the chunk, and its mesh's first vertex (what GPU culling will
// need to write commands).
Chunk_Draw :: struct {
	chunk:        [3]i32,
	first_vertex: u32,
}

// Indirect commands a mesh can take in a frame, at most: runs of visible
// face groups in the opaque and cutout layers (three at most in the group
// order; four bounds it), one translucent.
COMMANDS_PER_MESH :: 4 + 4 + 1

Camera :: struct {
	chunk:     [3]i32, // the camera's chunk; everything below is relative to its origin
	position:  [3]f32,
	view_proj: matrix[4, 4]f32,
}

World_Settings :: struct {
	vertex_capacity: u32, // vertices in the shared buffer
	staging_size:    int, // bytes per frame slot
}

Mesh_Layer :: enum u8 {
	Opaque,
	Cutout,
	Translucent,
}

// World_Shaders: the world's SPIR-V, one vertex shader for every layer.
World_Shaders :: struct {
	vertex:   []byte,
	fragment: [Mesh_Layer][]byte,
}

Upload_Result :: enum {
	Ok,
	Busy, // staging full this frame: try again next frame
	Full, // vertex buffer full (logged)
}

World_Pass :: struct {
	settings:         World_Settings,
	pipelines:        [Mesh_Layer]gpu.Pipeline,
	vertices:         gpu.Buffer,
	chunk_draws:      gpu.Buffer, // one Chunk_Draw per mesh pool slot
	ranges:           base.Range_Allocator, // in vertices
	indices:          gpu.Buffer,
	textures:         gpu.Image,
	textures_id:      gpu.Texture_Id,
	meshes:           base.Pool(Mesh, Mesh_Handle),
	frames:           [gpu.FRAMES_IN_FLIGHT]World_Frame,
	setup_pending:    []u8, // index and texture data for the first frame
	texture_layers:   u32,
	stats:            World_Stats,
	full_reported:    bool,
	// Occlusion statistics (a debug switch: a query a chunk costs): how many
	// chunks drawn passed no pixel, hidden behind nearer ones (drawn first):
	// what occlusion culling could leave out.
	occlusion:        bool,
	occlusion_stats:  Occlusion_Stats,
	// This frame's meshes in view (world_draw), and keys into it sorted
	// nearest first: those with opaque or cutout faces, those with water.
	// Every mesh's chunk, densely (what culling walks: a mesh is larger,
	// and the pool has gaps), and each pool slot's place in it.
	live:             [dynamic]Live_Mesh,
	live_at:          []u32,
	visible:          [dynamic]Visible,
	near_first:       [dynamic]u64,
	water_near_first: [dynamic]u64,
	sort_scratch:     [dynamic]u64,
}

Occlusion_Stats :: struct {
	frames, queried, hidden: int, // summed over the frames read
}

OCCLUSION_QUERIES :: 4096 // chunks queried a frame, at most

World_Stats :: struct {
	meshes, drawn:  int,
	triangles:      int, // drawn this frame, every layer
	api_draws:      int, // vkCmdDraw* calls this frame, every layer
	vertices_used:  u32,
	uploaded_bytes: int, // this frame
}

// Within a layer a mesh's quads come by face group (client/mesh): +x, +y,
// +z, both ways (plants), -z, -y, -x. Opaque and cutout layers draw only
// the groups that can face the camera.
FACE_GROUPS :: 7

// Mesh_Counts: vertices of each layer's face groups, in order in a range.
Mesh_Counts :: [Mesh_Layer][FACE_GROUPS]u32

@(private)
Mesh :: struct {
	chunk:  [3]i32,
	range:  base.Range,
	counts: Mesh_Counts,
	layers: [Mesh_Layer]u32, // each layer's vertices (the sums)
	hidden: bool, // uploaded, not drawn yet (world_show_mesh)
}

@(private)
World_Frame :: struct {
	staging:      gpu.Buffer,
	staging_used: int,
	copies:       [dynamic]vk.BufferCopy, // into the vertices
	draw_copies:  [dynamic]vk.BufferCopy, // into the chunk draw table
	// This frame's draw commands, written by world_cull (grown there).
	indirect:     gpu.Buffer,
	commands:     int, // written this frame
	spans:        [Mesh_Layer][dynamic]Span, // what each layer's draws are
	freed:        [dynamic]base.Range, // reusable once this slot comes round again
	queries:      vk.QueryPool, // occlusion (made when first wanted)
	queried:      u32, // queries recorded in this slot's last frame
}

// World_Push matches world.glsl's push constants: the same for every
// world draw.
@(private)
World_Push :: struct {
	scene:      u64, // the scene's address (scene.odin)
	textures:   u32,
	sampler_id: u32,
	time:       f32, // seconds, for moving water
}

// world_init creates the pipeline and buffers. texture_pixels holds every
// layer's RGBA8 sRGB mip chain (layer 0 mips 0..n, layer 1 ...), from
// texture_size pixels square down to 1.
world_init :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	settings: World_Settings,
	shaders: World_Shaders,
	texture_pixels: []u8,
	texture_size, texture_mips, texture_layers: u32,
	max_meshes: int,
	allocator := context.allocator,
) -> bool {
	p^ = {
		settings       = settings,
		texture_layers = texture_layers,
	}
	for &pipeline, layer in p.pipelines {
		pipeline = gpu.create_pipeline(g, world_pipeline_desc(g, shaders, layer)) or_return
	}
	p.vertices = gpu.create_buffer(
		g,
		int(settings.vertex_capacity) * WORLD_VERTEX_SIZE,
		{.VERTEX_BUFFER, .TRANSFER_DST},
		false,
		"chunk vertices",
	) or_return
	p.chunk_draws = gpu.create_buffer(
		g,
		(max_meshes + 1) * size_of(Chunk_Draw), // slot 0 is never used
		{.VERTEX_BUFFER, .TRANSFER_DST},
		false,
		"chunk draws",
	) or_return
	base.range_init(&p.ranges, settings.vertex_capacity, allocator)
	p.indices = gpu.create_buffer(
		g,
		MAX_QUADS_PER_LAYER * 6 * size_of(u32),
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
	p.live = make([dynamic]Live_Mesh, 0, max_meshes, allocator)
	p.live_at = make([]u32, max_meshes + 1, allocator)
	p.visible = make([dynamic]Visible, allocator)
	p.near_first = make([dynamic]u64, allocator)
	p.water_near_first = make([dynamic]u64, allocator)
	p.sort_scratch = make([dynamic]u64, allocator)
	for &f, i in p.frames {
		f.staging = gpu.create_buffer(
			g,
			settings.staging_size,
			{.TRANSFER_SRC},
			true,
			i == 0 ? "world staging 0" : "world staging 1",
		) or_return
		f.copies = make([dynamic]vk.BufferCopy, allocator)
		f.draw_copies = make([dynamic]vk.BufferCopy, allocator)
		for &spans in f.spans {spans = make([dynamic]Span, allocator)}
		f.freed = make([dynamic]base.Range, allocator)
	}

	// Indices and textures go up with the first frame.
	set_setup(p, texture_pixels, allocator)
	return true
}

@(private = "file")
set_setup :: proc(p: ^World_Pass, texture_pixels: []u8, allocator := context.allocator) {
	index_bytes := MAX_QUADS_PER_LAYER * 6 * size_of(u32)
	delete(p.setup_pending)
	p.setup_pending = make([]u8, index_bytes + len(texture_pixels), allocator)
	indices := mem.slice_data_cast([]u32, p.setup_pending[:index_bytes])
	for q in 0 ..< MAX_QUADS_PER_LAYER {
		v := u32(q * 4)
		copy(indices[q * 6:], []u32{v, v + 1, v + 2, v, v + 2, v + 3})
	}
	copy(p.setup_pending[index_bytes:], texture_pixels)
}

// world_set_textures replaces the texture array (a pack's images: the layers
// grow or shrink with the registry): the GPU is idled, the new array goes up
// with the next frame. Meshes name layers by number, so the caller re-meshes.
world_set_textures :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	texture_pixels: []u8,
	texture_layers: u32,
) -> bool {
	gpu.wait_idle(g)
	if p.textures.handle != 0 {gpu.unregister_texture(g, p.textures_id)}
	size, mips := p.textures.width, p.textures.mips
	gpu.destroy_image(g, &p.textures)
	p.texture_layers = texture_layers
	p.textures = gpu.create_image(
		g,
		size,
		size,
		.R8G8B8A8_SRGB,
		{.SAMPLED, .TRANSFER_DST},
		"block textures",
		mips = mips,
		layers = texture_layers,
		view_type = .D2_ARRAY,
	) or_return
	p.textures_id = gpu.register_texture(g, p.textures.view) or_return
	set_setup(p, texture_pixels)
	return true
}

@(private = "file", rodata)
WORLD_ATTRIBUTES := [2]gpu.Vertex_Attribute{{.R32_UINT, 0}, {.R32_UINT, 4}}

@(private = "file", rodata)
CHUNK_DRAW_ATTRIBUTES := [1]gpu.Vertex_Attribute{{.R32G32B32A32_SINT, 0}}

@(private = "file", rodata)
LAYER_NAMES := [Mesh_Layer]string {
	.Opaque      = "world",
	.Cutout      = "world cutout",
	.Translucent = "water",
}

@(private = "file")
world_pipeline_desc :: proc(
	g: ^gpu.Gpu,
	shaders: World_Shaders,
	layer: Mesh_Layer,
) -> gpu.Pipeline_Desc {
	desc := gpu.Pipeline_Desc {
		name                = LAYER_NAMES[layer],
		vertex_spirv        = shaders.vertex,
		fragment_spirv      = shaders.fragment[layer],
		color_format        = gpu.color_format(g),
		vertex_stride       = WORLD_VERTEX_SIZE,
		attributes          = WORLD_ATTRIBUTES[:],
		instance_stride     = size_of(Chunk_Draw),
		instance_attributes = CHUNK_DRAW_ATTRIBUTES[:],
		depth               = .Test_Write,
		cull_back           = true,
	}
	if layer == .Translucent {
		// Seen from above and below (the surface's top only, from outside),
		// blended over what is behind, never hiding the rest of the water.
		desc.depth, desc.cull_back, desc.alpha_blend = .Test, false, true
	}
	return desc
}

// world_reload swaps in new shaders (hot reload); false keeps the old ones
// (any that failed: those already replaced stay new).
world_reload :: proc(p: ^World_Pass, g: ^gpu.Gpu, shaders: World_Shaders) -> bool {
	ok := true
	for &pipeline, layer in p.pipelines {
		if !gpu.replace_pipeline(g, &pipeline, world_pipeline_desc(g, shaders, layer)) {ok = false}
	}
	return ok
}

// world_destroy releases everything; call after gpu.wait_idle.
world_destroy :: proc(p: ^World_Pass, g: ^gpu.Gpu) {
	for &f in p.frames {
		if f.queries != 0 {vk.DestroyQueryPool(g.device, f.queries, nil)}
		gpu.destroy_buffer(g, &f.staging)
		gpu.destroy_buffer(g, &f.indirect)
		for spans in f.spans {delete(spans)}
		delete(f.copies)
		delete(f.draw_copies)
		delete(f.freed)
	}
	delete(p.setup_pending)
	delete(p.live)
	delete(p.live_at)
	delete(p.visible)
	delete(p.near_first)
	delete(p.water_near_first)
	delete(p.sort_scratch)
	base.pool_destroy(&p.meshes)
	base.range_destroy(&p.ranges)
	if p.textures.handle != 0 {gpu.unregister_texture(g, p.textures_id)}
	gpu.destroy_image(g, &p.textures)
	gpu.destroy_buffer(g, &p.indices)
	gpu.destroy_buffer(g, &p.chunk_draws)
	gpu.destroy_buffer(g, &p.vertices)
	for &pipeline in p.pipelines {gpu.destroy_pipeline(g, &pipeline)}
	p^ = {}
}

// world_begin starts this frame slot's uploads: its staging buffer is free
// again, and ranges removed when the slot was last used can be reused.
world_begin :: proc(p: ^World_Pass, g: ^gpu.Gpu) {
	f := &p.frames[gpu.frame_slot(g)]
	f.staging_used = 0
	f.commands = 0
	for &spans in f.spans {clear(&spans)}
	clear(&f.copies)
	clear(&f.draw_copies)
	for r in f.freed {base.range_free(&p.ranges, r)}
	clear(&f.freed)
	p.stats.uploaded_bytes = 0
	// This slot's last occlusion queries are done (its fence was waited on).
	if f.queried > 0 {
		results: [OCCLUSION_QUERIES]u64
		if vk.GetQueryPoolResults(
			   g.device,
			   f.queries,
			   0,
			   f.queried,
			   int(f.queried) * size_of(u64),
			   &results[0],
			   size_of(u64),
			   {._64},
		   ) ==
		   .SUCCESS {
			o := &p.occlusion_stats
			o.frames += 1
			o.queried += int(f.queried)
			for r in results[:f.queried] {if r == 0 {o.hidden += 1}}
		}
		f.queried = 0
	}
}

// world_add_mesh uploads a chunk's vertices, counts[layer] of each layer in
// order (multiples of 4, at most MAX_QUADS_PER_LAYER quads each), and
// returns its handle. A hidden mesh is not drawn until world_show_mesh (to
// show several at once).
world_add_mesh :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	chunk: [3]i32,
	vertices: []u8,
	counts: Mesh_Counts,
	hidden := false,
) -> (
	handle: Mesh_Handle,
	result: Upload_Result,
) {
	count := u32(len(vertices) / WORLD_VERTEX_SIZE)
	assert(len(vertices) % (4 * WORLD_VERTEX_SIZE) == 0 && count > 0)
	layers: [Mesh_Layer]u32
	for groups, l in counts {
		for n in groups {
			assert(n % 4 == 0)
			layers[l] += n
		}
		assert(layers[l] / 4 <= MAX_QUADS_PER_LAYER)
	}
	assert(layers[.Opaque] + layers[.Cutout] + layers[.Translucent] == count)
	f := &p.frames[gpu.frame_slot(g)]
	if f.staging_used + len(vertices) + size_of(Chunk_Draw) > f.staging.size {return 0, .Busy}
	r, ok := base.range_alloc(&p.ranges, count)
	if !ok {
		if !p.full_reported {
			log.errorf(
				"render chunk vertex buffer full (%d of %d vertices used); raise vertex_capacity",
				p.ranges.used,
				p.ranges.capacity,
			)
			p.full_reported = true
		}
		return 0, .Full
	}
	h, _, added := base.pool_add(&p.meshes, Mesh{chunk, r, counts, layers, hidden})
	if !added {
		base.range_free(&p.ranges, r)
		log.error("render too many chunk meshes")
		return 0, .Full
	}
	p.live_at[base.pool_index(h)] = u32(len(p.live))
	append(&p.live, Live_Mesh{chunk, h})
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
	// Its record in the chunk draw table, at its slot: a frame that drew
	// the slot's last mesh has finished before the copy runs (world_upload's
	// barrier), and nothing draws the slot before this frame.
	record := Chunk_Draw{chunk, r.offset}
	mem.copy(&f.staging.mapped[f.staging_used], &record, size_of(record))
	append(
		&f.draw_copies,
		vk.BufferCopy {
			srcOffset = vk.DeviceSize(f.staging_used),
			dstOffset = vk.DeviceSize(base.pool_index(h)) * size_of(Chunk_Draw),
			size = size_of(Chunk_Draw),
		},
	)
	f.staging_used += size_of(Chunk_Draw)
	p.stats.uploaded_bytes += len(vertices) + size_of(Chunk_Draw)
	return h, .Ok
}

// world_show_mesh starts drawing a mesh added hidden.
world_show_mesh :: proc(p: ^World_Pass, h: Mesh_Handle) {
	if m := base.pool_get(&p.meshes, h); m != nil {m.hidden = false}
}

// world_remove_mesh stops drawing the mesh; its memory is reused once the
// GPU is done with it.
world_remove_mesh :: proc(p: ^World_Pass, g: ^gpu.Gpu, h: Mesh_Handle) {
	m := base.pool_get(&p.meshes, h)
	if m == nil {return}
	append(&p.frames[gpu.frame_slot(g)].freed, m.range)
	at := p.live_at[base.pool_index(h)]
	last := pop(&p.live)
	if int(at) < len(p.live) {
		p.live[at] = last
		p.live_at[base.pool_index(last.handle)] = at
	}
	base.pool_remove(&p.meshes, h)
}

// world_upload records this frame's copies. Call before begin_rendering.
world_upload :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame) -> bool {
	f := &p.frames[gpu.frame_slot(g)]
	cmd := frame.cmd
	if p.setup_pending != nil {
		upload_setup(p, f, cmd) or_return
	}
	if p.occlusion {
		// Reset before rendering (a reset cannot go inside it).
		if f.queries == 0 {
			info := vk.QueryPoolCreateInfo {
				sType      = .QUERY_POOL_CREATE_INFO,
				queryType  = .OCCLUSION,
				queryCount = OCCLUSION_QUERIES,
			}
			if vk.CreateQueryPool(g.device, &info, nil, &f.queries) !=
			   .SUCCESS {p.occlusion = false}
		}
		if f.queries != 0 {vk.CmdResetQueryPool(cmd, f.queries, 0, OCCLUSION_QUERIES)}
	}
	if len(f.copies) == 0 {return true}
	gpu.begin_label(g, cmd, "upload chunk meshes")
	defer gpu.end_label(g, cmd)
	// Ranges and table slots being written were last drawn (and copied) by
	// finished frames, except a table slot freed and reused, whose last draw
	// may be the other frame in flight: order the copies after vertex shading
	// and earlier copies (for that, and for the validation layer's sake:
	// without the write, a range copied again is a write-after-write hazard).
	before := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.VERTEX_ATTRIBUTE_INPUT, .COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.COPY},
		dstAccessMask = {.TRANSFER_WRITE},
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
	vk.CmdCopyBuffer(
		cmd,
		f.staging.handle,
		p.chunk_draws.handle,
		u32(len(f.draw_copies)),
		raw_data(f.draw_copies),
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
			"render world staging (%d bytes) too small for setup data (%d)",
			f.staging.size,
			len(data),
		)
		return false
	}
	base_offset := f.staging_used
	copy(f.staging.mapped[base_offset:][:len(data)], data)
	f.staging_used += len(data)

	index_bytes := MAX_QUADS_PER_LAYER * 6 * size_of(u32)
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

// world_cull finds the meshes in the camera's view and writes this frame's
// draw commands. Call before world_draw (a GPU culling pass, recorded
// before rendering, will take its place).
world_cull :: proc(p: ^World_Pass, g: ^gpu.Gpu, camera: Camera) {
	p.stats.meshes = p.meshes.count
	p.stats.vertices_used = p.ranges.used
	p.stats.drawn = 0
	p.stats.triangles = 0
	p.stats.api_draws = 0
	clear(&p.visible)
	clear(&p.near_first)
	clear(&p.water_near_first)
	if p.meshes.count == 0 {return}
	slot := &p.frames[gpu.frame_slot(g)]
	// Room for every command this frame can write; its last frame is done.
	if !indirect_reserve(g, slot, p.meshes.count * COMMANDS_PER_MESH) {return}
	// The meshes in view, each list sorted nearest first: what is nearer is
	// drawn before what it hides, so the depth test spares the hidden
	// fragments their shading (water is drawn the other way). A key is the
	// distance's bits (ordered as the distance: it is not negative) over
	// the mesh's place in visible.
	planes := frustum_planes(camera.view_proj)
	for l in p.live {
		origin := (l.chunk - camera.chunk) * CHUNK_EXTENT
		lo := [3]f32{f32(origin.x), f32(origin.y), f32(origin.z)}
		if !box_visible(&planes, lo, lo + CHUNK_EXTENT) {continue}
		m := base.pool_get(&p.meshes, l.handle)
		if m.hidden {continue}
		h := l.handle
		d := lo + CHUNK_EXTENT / 2 - camera.position
		distance := d.x * d.x + d.y * d.y + d.z * d.z
		key := u64(transmute(u32)distance) << 32 | u64(len(p.visible))
		append(&p.visible, Visible{m, base.pool_index(h), facing(lo, camera.position)})
		if m.layers[.Opaque] + m.layers[.Cutout] > 0 {append(&p.near_first, key)}
		if m.layers[.Translucent] > 0 {append(&p.water_near_first, key)}
	}
	sort_keys(p.near_first[:], &p.sort_scratch)
	sort_keys(p.water_near_first[:], &p.sort_scratch)
	query := p.occlusion && slot.queries != 0
	queried := 0
	for layer in ([2]Mesh_Layer{.Opaque, .Cutout}) {
		span := Span {
			first = slot.commands,
		}
		for key in p.near_first {
			v := &p.visible[u32(key)]
			if v.mesh.layers[layer] == 0 {continue}
			if layer == .Opaque {p.stats.drawn += 1}
			if query && layer == .Opaque && queried < OCCLUSION_QUERIES {
				// Counting what each chunk hides: a span (a draw) a chunk.
				at := slot.commands
				t := write_commands(slot, v, layer)
				append(&slot.spans[layer], Span{at, slot.commands - at, t, true})
				queried += 1
				span.first = slot.commands
				continue
			}
			span.triangles += write_commands(slot, v, layer)
		}
		span.count = slot.commands - span.first
		append(&slot.spans[layer], span)
	}
	span := Span {
		first = slot.commands,
	}
	#reverse for key in p.water_near_first {
		span.triangles += write_commands(slot, &p.visible[u32(key)], .Translucent)
	}
	span.count = slot.commands - span.first
	append(&slot.spans[.Translucent], span)
}

// world_draw draws the opaque and cutout layers world_cull found in view,
// one indirect draw a layer. Call inside rendering. scene: this frame's
// scene_upload (for world_cull's camera).
world_draw :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64) {
	slot := &p.frames[gpu.frame_slot(g)]
	if slot.commands == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "world")
	defer gpu.end_label(g, cmd)
	query := 0
	for layer in ([2]Mesh_Layer{.Opaque, .Cutout}) {
		draw_begin(p, g, cmd, layer, scene, 0)
		for s in slot.spans[layer] {
			if s.query {vk.CmdBeginQuery(cmd, slot.queries, u32(query), {})}
			draw_span(p, g, cmd, slot, s)
			if s.query {
				vk.CmdEndQuery(cmd, slot.queries, u32(query))
				query += 1
			}
		}
	}
	slot.queried = u32(query)
}

// world_draw_translucent draws the translucent layers world_cull found in
// view, the farthest chunks first (blending needs what is behind drawn
// already: the commands are written in that order). Call after world_draw.
// time: seconds, for the moving surface.
world_draw_translucent :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	frame: gpu.Frame,
	scene: u64,
	time: f32,
) {
	slot := &p.frames[gpu.frame_slot(g)]
	spans := slot.spans[.Translucent][:]
	if len(spans) == 0 || spans[0].count == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "water")
	defer gpu.end_label(g, cmd)
	draw_begin(p, g, cmd, .Translucent, scene, time)
	draw_span(p, g, cmd, slot, spans[0])
}

// Span: commands drawn by one indirect draw (in the occlusion statistics'
// queries, one mesh's).
@(private)
Span :: struct {
	first, count: int,
	triangles:    int,
	query:        bool,
}

// Live_Mesh: a mesh's chunk, for culling.
@(private)
Live_Mesh :: struct {
	chunk:  [3]i32,
	handle: Mesh_Handle,
}

// Visible: a mesh in view this frame.
@(private)
Visible :: struct {
	mesh:  ^Mesh,
	slot:  u32, // its pool slot: its record in the chunk draw table
	faces: u8, // bit g: face group g can face the camera (facing)
}

// facing: which face groups of a chunk whose box starts at lo can face a
// camera at eye: a group's faces lie within the chunk's box, so +x faces can
// face the camera only when it is past the box's low x side, and so on;
// both-ways faces (plants) always can.
@(private = "file")
facing :: proc(lo, eye: [3]f32) -> (faces: u8) {
	hi := lo + CHUNK_EXTENT
	if eye.x > lo.x {faces |= 1 << 0} 	// +x
	if eye.y > lo.y {faces |= 1 << 1} 	// +y
	if eye.z > lo.z {faces |= 1 << 2} 	// +z
	if eye.z < hi.z {faces |= 1 << 4} 	// -z
	if eye.y < hi.y {faces |= 1 << 5} 	// -y
	if eye.x < hi.x {faces |= 1 << 6} 	// -x
	return faces | 1 << 3 // both ways
}

// indirect_reserve makes this slot's indirect buffer hold at least n
// commands (doubling it); its last frame is done with it.
@(private = "file")
indirect_reserve :: proc(g: ^gpu.Gpu, f: ^World_Frame, n: int) -> bool {
	STRIDE :: size_of(vk.DrawIndexedIndirectCommand)
	if f.indirect.size >= n * STRIDE {return true}
	size := max(f.indirect.size, 4096 * STRIDE)
	for size < n * STRIDE {size *= 2}
	gpu.destroy_buffer(g, &f.indirect)
	ok: bool
	f.indirect, ok = gpu.create_buffer(g, size, {.INDIRECT_BUFFER}, true, "world draw commands")
	if !ok {log.errorf("render could not make a %d-byte indirect buffer", size)}
	return ok
}

@(private = "file")
draw_begin :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	cmd: vk.CommandBuffer,
	layer: Mesh_Layer,
	scene: u64,
	time: f32,
) {
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipelines[layer].handle)
	gpu.bind_globals(g, cmd)
	vk.CmdBindIndexBuffer(cmd, p.indices.handle, 0, .UINT32)
	buffers := [2]vk.Buffer{p.vertices.handle, p.chunk_draws.handle}
	offsets: [2]vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 2, &buffers[0], &offsets[0])
	push := World_Push {
		scene      = scene,
		textures   = u32(p.textures_id),
		sampler_id = u32(gpu.Sampler.Pixel_Art),
		time       = time,
	}
	gpu.push_constants(g, cmd, &push)
}

// draw_span draws a span's commands (none: no call).
@(private = "file")
draw_span :: proc(p: ^World_Pass, g: ^gpu.Gpu, cmd: vk.CommandBuffer, f: ^World_Frame, s: Span) {
	if s.count == 0 {return}
	calls := g.draws.api_calls
	gpu.draw_indexed_indirect(
		g,
		cmd,
		f.indirect.handle,
		s.first * size_of(vk.DrawIndexedIndirectCommand),
		u32(s.count),
		s.triangles,
	)
	p.stats.api_draws += g.draws.api_calls - calls
	p.stats.triangles += s.triangles
}

// write_commands writes a mesh's layer's draw commands to the frame's
// indirect buffer: for opaque and cutout, only the face groups that can
// face the camera (v.faces), adjacent groups in one command. Returns the
// triangles.
@(private = "file")
write_commands :: proc(f: ^World_Frame, v: ^Visible, layer: Mesh_Layer) -> (triangles: int) {
	m := v.mesh
	commands := ([^]vk.DrawIndexedIndirectCommand)(f.indirect.mapped)
	first := m.range.offset
	switch layer {
	case .Opaque:
	case .Cutout:
		first += m.layers[.Opaque]
	case .Translucent:
		first += m.layers[.Opaque] + m.layers[.Cutout]
		commands[f.commands] = {m.layers[layer] / 4 * 6, 1, 0, i32(first), v.slot}
		f.commands += 1
		return int(m.layers[layer] / 2)
	}
	// Runs of visible groups, one command each.
	counts := &m.counts[layer]
	run_start, run_count := first, u32(0)
	at := first
	#no_bounds_check for group in 0 ..< FACE_GROUPS {
		n := counts[group]
		if v.faces & (1 << u8(group)) != 0 {
			if run_count == 0 {run_start = at}
			run_count += n
		} else if run_count > 0 {
			commands[f.commands] = {run_count / 4 * 6, 1, 0, i32(run_start), v.slot}
			f.commands += 1
			triangles += int(run_count / 2)
			run_count = 0
		}
		at += n
	}
	if run_count > 0 {
		commands[f.commands] = {run_count / 4 * 6, 1, 0, i32(run_start), v.slot}
		f.commands += 1
		triangles += int(run_count / 2)
	}
	return
}

// sort_keys sorts keys by their high 32 bits, keeping the order of equal
// ones: a least-significant-digit radix sort, a byte a pass, the four
// bytes' counts taken in one read, a pass skipped where every key has the
// same byte (distances near each other share their high bytes).
@(private)
sort_keys :: proc(keys: []u64, scratch: ^[dynamic]u64) {
	if len(keys) < 2 {return}
	counts: [4][256]int
	for k in keys {
		#no_bounds_check for d in 0 ..< 4 {counts[d][k >> (32 + 8 * u64(d)) & 0xff] += 1}
	}
	resize(scratch, len(keys))
	from, to := keys, scratch[:]
	for d in 0 ..< 4 {
		shift := 32 + 8 * u64(d)
		if counts[d][keys[0] >> shift & 0xff] == len(keys) {continue}
		at: [256]int
		for b in 1 ..< 256 {at[b] = at[b - 1] + counts[d][b - 1]}
		for k in from {
			b := k >> shift & 0xff
			to[at[b]] = k
			at[b] += 1
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(keys) {copy(keys, from)}
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
