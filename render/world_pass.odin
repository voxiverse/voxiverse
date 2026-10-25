package render

import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

import "../base"
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
//	... begin_rendering ...
//	render.world_draw(&pass, &g, frame, camera, scene)              // opaque, cutout
//	... entities, sky ...
//	render.world_draw_translucent(&pass, &g, frame, camera, scene, time)
//
// Vertices are 8 bytes (client/mesh.Vertex): positions relative to the
// chunk, which is drawn relative to the camera's chunk, so precision does
// not degrade far from the world origin.

WORLD_VERTEX_SIZE :: 8
// The most quads one layer of a chunk can have: every face of every block
// (a chunk full of leaves, whose faces show through each other).
MAX_QUADS_PER_LAYER :: 16 * 16 * 16 * 6
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
	settings:        World_Settings,
	pipelines:       [Mesh_Layer]gpu.Pipeline,
	vertices:        gpu.Buffer,
	ranges:          base.Range_Allocator, // in vertices
	indices:         gpu.Buffer,
	textures:        gpu.Image,
	textures_id:     gpu.Texture_Id,
	meshes:          base.Pool(Mesh, Mesh_Handle),
	frames:          [gpu.FRAMES_IN_FLIGHT]World_Frame,
	setup_pending:   []u8, // index and texture data for the first frame
	texture_layers:  u32,
	stats:           World_Stats,
	full_reported:   bool,
	// Occlusion statistics (a debug switch: a query a chunk costs): how many
	// chunks drawn passed no pixel, hidden behind nearer ones (drawn first):
	// what occlusion culling could leave out.
	occlusion:       bool,
	occlusion_stats: Occlusion_Stats,
}

Occlusion_Stats :: struct {
	frames, queried, hidden: int, // summed over the frames read
}

OCCLUSION_QUERIES :: 4096 // chunks queried a frame, at most

World_Stats :: struct {
	meshes, drawn:  int,
	triangles:      int, // drawn this frame, every layer
	vertices_used:  u32,
	uploaded_bytes: int, // this frame
}

// Within a layer a mesh's quads come by face group (client/mesh): +x, -x,
// +y, -y, +z, -z, then both ways (plants). Opaque and cutout layers draw
// only the groups that can face the camera.
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
	copies:       [dynamic]vk.BufferCopy,
	freed:        [dynamic]base.Range, // reusable once this slot comes round again
	queries:      vk.QueryPool, // occlusion (made when first wanted)
	queried:      u32, // queries recorded in this slot's last frame
}

// World_Push matches world.vert's push constants.
@(private)
World_Push :: struct {
	scene:        u64, // the scene's address (scene.odin)
	_:            u64,
	chunk_offset: [3]f32,
	textures:     u32,
	sampler_id:   u32,
	time:         f32, // seconds, for moving water
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
	index_bytes := MAX_QUADS_PER_LAYER * 6 * size_of(u32)
	p.setup_pending = make([]u8, index_bytes + len(texture_pixels), allocator)
	indices := mem.slice_data_cast([]u32, p.setup_pending[:index_bytes])
	for q in 0 ..< MAX_QUADS_PER_LAYER {
		v := u32(q * 4)
		copy(indices[q * 6:], []u32{v, v + 1, v + 2, v, v + 2, v + 3})
	}
	copy(p.setup_pending[index_bytes:], texture_pixels)
	return true
}

@(private = "file", rodata)
WORLD_ATTRIBUTES := [2]gpu.Vertex_Attribute{{.R32_UINT, 0}, {.R32_UINT, 4}}

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
		name           = LAYER_NAMES[layer],
		vertex_spirv   = shaders.vertex,
		fragment_spirv = shaders.fragment[layer],
		color_format   = gpu.color_format(g),
		vertex_stride  = WORLD_VERTEX_SIZE,
		attributes     = WORLD_ATTRIBUTES[:],
		depth          = .Test_Write,
		cull_back      = true,
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
	for &pipeline in p.pipelines {gpu.destroy_pipeline(g, &pipeline)}
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
	if f.staging_used + len(vertices) > f.staging.size {return 0, .Busy}
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

// world_draw draws the opaque and cutout layers of every mesh in the
// camera's view. Call inside rendering. scene: this frame's scene_upload
// (for the same camera).
world_draw :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame, camera: Camera, scene: u64) {
	p.stats.meshes = p.meshes.count
	p.stats.vertices_used = p.ranges.used
	p.stats.drawn = 0
	p.stats.triangles = 0
	if p.meshes.count == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "world")
	defer gpu.end_label(g, cmd)
	// The meshes in view, nearest first: what is nearer is drawn before what
	// it hides, so the depth test spares the hidden fragments their shading.
	Visible :: struct {
		mesh:     ^Mesh,
		lo:       [3]f32,
		distance: f32,
	}
	planes := frustum_planes(camera.view_proj)
	visible := make([dynamic]Visible, 0, p.meshes.count, context.temp_allocator)
	it: base.Pool_Iterator
	for m in base.pool_next(&p.meshes, &it) {
		if m.hidden || m.layers[.Opaque] + m.layers[.Cutout] == 0 {continue}
		lo, seen := mesh_visible(m, camera, &planes)
		if !seen {continue}
		d := lo + CHUNK_EXTENT / 2 - camera.position
		append(&visible, Visible{m, lo, d.x * d.x + d.y * d.y + d.z * d.z})
	}
	slice.sort_by(visible[:], proc(a, b: Visible) -> bool {return a.distance < b.distance})
	slot := &p.frames[gpu.frame_slot(g)]
	query := p.occlusion && slot.queries != 0
	for layer in ([2]Mesh_Layer{.Opaque, .Cutout}) {
		draw_begin(p, g, cmd, layer)
		push := world_push(p, scene, 0)
		for v in visible {
			if v.mesh.layers[layer] == 0 {continue}
			counted := query && layer == .Opaque && slot.queried < OCCLUSION_QUERIES
			if counted {vk.CmdBeginQuery(cmd, slot.queries, slot.queried, {})}
			p.stats.triangles += draw_layer(g, cmd, v.mesh, layer, v.lo, camera.position, &push)
			if counted {
				vk.CmdEndQuery(cmd, slot.queries, slot.queried)
				slot.queried += 1
			}
			if layer == .Opaque {p.stats.drawn += 1}
		}
	}
}

// world_draw_translucent draws the translucent layers in view, the
// farthest chunks first (blending needs what is behind drawn already).
// time: seconds, for the moving surface.
world_draw_translucent :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	frame: gpu.Frame,
	camera: Camera,
	scene: u64,
	time: f32,
) {
	if p.meshes.count == 0 {return}
	Visible :: struct {
		mesh:     ^Mesh,
		lo:       [3]f32,
		distance: f32,
	}
	planes := frustum_planes(camera.view_proj)
	visible := make([dynamic]Visible, context.temp_allocator)
	it: base.Pool_Iterator
	for m in base.pool_next(&p.meshes, &it) {
		if m.hidden || m.layers[.Translucent] == 0 {continue}
		lo, seen := mesh_visible(m, camera, &planes)
		if !seen {continue}
		d := lo + CHUNK_EXTENT / 2 - camera.position
		append(&visible, Visible{m, lo, d.x * d.x + d.y * d.y + d.z * d.z})
	}
	if len(visible) == 0 {return}
	slice.sort_by(visible[:], proc(a, b: Visible) -> bool {return a.distance > b.distance})
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "water")
	defer gpu.end_label(g, cmd)
	draw_begin(p, g, cmd, .Translucent)
	push := world_push(p, scene, time)
	for v in visible {
		p.stats.triangles += draw_layer(g, cmd, v.mesh, .Translucent, v.lo, camera.position, &push)
	}
}

@(private = "file")
draw_begin :: proc(p: ^World_Pass, g: ^gpu.Gpu, cmd: vk.CommandBuffer, layer: Mesh_Layer) {
	vk.CmdBindPipeline(cmd, .GRAPHICS, p.pipelines[layer].handle)
	gpu.bind_globals(g, cmd)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(cmd, 0, 1, &p.vertices.handle, &offset)
	vk.CmdBindIndexBuffer(cmd, p.indices.handle, 0, .UINT32)
}

@(private = "file")
world_push :: proc(p: ^World_Pass, scene: u64, time: f32) -> World_Push {
	return {
		scene = scene,
		textures = u32(p.textures_id),
		sampler_id = u32(gpu.Sampler.Pixel_Art),
		time = time,
	}
}

// mesh_visible: where the mesh's chunk is from the camera chunk's origin,
// and whether it is in view.
@(private = "file")
mesh_visible :: proc(m: ^Mesh, camera: Camera, planes: ^Planes) -> (lo: [3]f32, visible: bool) {
	origin := (m.chunk - camera.chunk) * CHUNK_EXTENT
	lo = {f32(origin.x), f32(origin.y), f32(origin.z)}
	return lo, box_visible(planes, lo, lo + CHUNK_EXTENT)
}

// draw_layer draws a mesh's layer: for opaque and cutout, only the face
// groups that can face the camera (a group's faces lie within the chunk's
// box: +x faces can face the camera only when it is past the box's low x
// side, and so on), adjacent groups in one draw. Returns the triangles.
@(private = "file")
draw_layer :: proc(
	g: ^gpu.Gpu,
	cmd: vk.CommandBuffer,
	m: ^Mesh,
	layer: Mesh_Layer,
	lo, eye: [3]f32,
	push: ^World_Push,
) -> (
	triangles: int,
) {
	first := m.range.offset
	for l in Mesh_Layer {
		if l == layer {break}
		first += m.layers[l]
	}
	push.chunk_offset = lo
	gpu.push_constants(g, cmd, push)
	if layer == .Translucent {
		vk.CmdDrawIndexed(cmd, m.layers[layer] / 4 * 6, 1, 0, i32(first), 0)
		return int(m.layers[layer] / 2)
	}
	hi := lo + CHUNK_EXTENT
	faces := [FACE_GROUPS]bool {
		eye.x > lo.x,
		eye.x < hi.x,
		eye.y > lo.y,
		eye.y < hi.y,
		eye.z > lo.z,
		eye.z < hi.z,
		true,
	}
	// Runs of visible groups, one draw each.
	run_start, run_count := first, u32(0)
	at := first
	for n, group in m.counts[layer] {
		if faces[group] {
			if run_count == 0 {run_start = at}
			run_count += n
		} else if run_count > 0 {
			vk.CmdDrawIndexed(cmd, run_count / 4 * 6, 1, 0, i32(run_start), 0)
			triangles += int(run_count / 2)
			run_count = 0
		}
		at += n
	}
	if run_count > 0 {
		vk.CmdDrawIndexed(cmd, run_count / 4 * 6, 1, 0, i32(run_start), 0)
		triangles += int(run_count / 2)
	}
	return
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
