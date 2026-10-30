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
//	render.world_cull(&pass, &g, frame, scene, camera)   // the draw commands (GPU culling)
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
// command's firstInstance (the mesh's slot) picks its chunk.
//
// Culling is on the GPU (R6). Every mesh shown has a Cull_Record in a dense
// table (its place: live_at); world_cull dispatches world_cull.comp, one
// invocation per record, which tests the chunk against the frustum (from
// the scene buffer) and writes CULL_RUNS vk.DrawIndexedIndirectCommand per
// opaque and cutout layer at fixed places: one per run of face groups that
// can face the camera, the rest (and every command of a mesh out of view)
// drawing nothing. Each layer is then one vkCmdDrawIndexedIndirect of every
// mesh's commands: the CPU never walks the meshes. Water is drawn after
// everything else, farthest first, so the CPU still culls and sorts the
// meshes with water (a short list of their own). What the GPU drew (meshes,
// triangles, commands) is read back FRAMES_IN_FLIGHT frames late, for the
// statistics. (Vertices come through vertex input,
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

// CULL_RUNS: commands per mesh in each culled layer: runs of face groups
// that can face the camera. They are three at most in the group order
// (whichever side of a chunk the camera is on along an axis, one of the axis's
// two groups can face it); when there are three, the gap with fewer vertices
// is drawn too (`bridged`: its faces all face away, the back-face culling
// drops them), so two commands cover every case: a command costs the GPU more
// than a few vertices do (R5b; test_runs_of_visible_face_groups).
CULL_RUNS :: 2
CULL_LAYERS :: 2 // opaque and cutout: culled on the GPU (water on the CPU)

// Cull_Record: a mesh shown, in the dense table world_cull.comp reads
// (std430, as the shader declares it).
Cull_Record :: struct {
	chunk:        [3]i32,
	slot:         u32, // its pool slot (its Chunk_Draw: the commands' firstInstance)
	first_vertex: u32,
	counts:       [CULL_LAYERS * FACE_GROUPS]u32, // face groups' vertices, opaque then cutout
	_:            u32,
}

// Cull_Push matches world_cull.comp's push constants.
@(private)
Cull_Push :: struct {
	scene:    u64,
	records:  u64,
	commands: u64,
	stats:    u64,
	count:    u32,
	cutouts:  u32, // the first records have cutout faces; the others have none
}

// Cull_Stats: the head of world_cull.comp's statistics (a bit per mesh in
// view follows it).
Cull_Stats :: struct {
	drawn:     u32, // meshes with opaque faces in view
	triangles: u32, // opaque and cutout
	commands:  u32, // that draw something
	_:         u32,
}

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

// World_Shaders: the world's SPIR-V, one vertex shader for every layer,
// and the culling pass's compute shader.
World_Shaders :: struct {
	vertex:   []byte,
	fragment: [Mesh_Layer][]byte,
	cull:     []byte,
}

Upload_Result :: enum {
	Ok,
	Busy, // staging full this frame: try again next frame
	Full, // vertex buffer full (logged)
}

World_Pass :: struct {
	settings:         World_Settings,
	pipelines:        [Mesh_Layer]gpu.Pipeline,
	cull_pipeline:    gpu.Pipeline,
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
	// Every mesh shown, densely (the pool has gaps), and each pool slot's
	// place in it; their Cull_Records, in the same order, as the GPU's table
	// (cull_records) has them once the records changed since are copied
	// (dirty: their places, each once).
	live:             [dynamic]Live_Mesh,
	live_at:          []u32,
	// The meshes with cutout faces are the first `cutouts` places of live and
	// records, so the cutout layer's commands are only theirs.
	cutouts:          u32,
	records:          [dynamic]Cull_Record,
	cull_records:     gpu.Buffer,
	dirty:            [dynamic]u32,
	is_dirty:         []bool,
	// The meshes shown with water, densely (culled and sorted on the CPU),
	// and each pool slot's place in it.
	water:            [dynamic]Live_Mesh,
	water_at:         []u32,
	// This frame's water in view, and keys into it sorted nearest first; with
	// occlusion statistics, every mesh's place in live, nearest first.
	visible:          [dynamic]Visible,
	near_first:       [dynamic]u64,
	water_near_first: [dynamic]u64,
	sort_scratch:     [dynamic]u64,
	gpu_stats:        Cull_Stats, // the GPU's culling, as last read back
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
	staging:       gpu.Buffer,
	staging_used:  int,
	copies:        [dynamic]vk.BufferCopy, // into the vertices
	draw_copies:   [dynamic]vk.BufferCopy, // into the chunk draw table
	// This frame's water draw commands, written by world_cull (grown there).
	indirect:      gpu.Buffer,
	commands:      int, // written this frame
	water:         Span,
	// The culling pass's: its commands (CULL_RUNS per mesh per culled
	// layer, every opaque one, then every cutout one), its statistics and
	// their copy for the CPU, and the records it copies into the table.
	cull_commands: gpu.Buffer,
	cull_stats:    gpu.Buffer,
	cull_readback: gpu.Buffer,
	cull_staging:  gpu.Buffer,
	cutouts:       u32, // of them, with cutout faces (the first places)
	culled:        u32, // meshes culled this frame (its commands' count / CULL_RUNS / CULL_LAYERS)
	freed:         [dynamic]base.Range, // reusable once this slot comes round again
	queries:       vk.QueryPool, // occlusion (made when first wanted)
	queried:       [dynamic]u32, // the meshes (places in live) queried in this slot's last frame
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
	p.cull_pipeline = gpu.create_compute_pipeline(g, "world cull", shaders.cull) or_return
	p.cull_records = gpu.create_buffer(
		g,
		max_meshes * size_of(Cull_Record),
		{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS, .TRANSFER_DST},
		false,
		"cull records",
	) or_return
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
	p.records = make([dynamic]Cull_Record, 0, max_meshes, allocator)
	p.dirty = make([dynamic]u32, allocator)
	p.is_dirty = make([]bool, max_meshes, allocator)
	p.water = make([dynamic]Live_Mesh, allocator)
	p.water_at = make([]u32, max_meshes + 1, allocator)
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
		f.freed = make([dynamic]base.Range, allocator)
		f.queried = make([dynamic]u32, allocator)
		stats_size := size_of(Cull_Stats) + (max_meshes + 31) / 32 * size_of(u32)
		f.cull_stats = gpu.create_buffer(
			g,
			stats_size,
			{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS, .TRANSFER_DST, .TRANSFER_SRC},
			false,
			i == 0 ? "cull stats 0" : "cull stats 1",
		) or_return
		f.cull_readback = gpu.create_buffer(
			g,
			stats_size,
			{.TRANSFER_DST},
			true,
			i == 0 ? "cull readback 0" : "cull readback 1",
		) or_return
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
	if !gpu.replace_compute_pipeline(g, &p.cull_pipeline, "world cull", shaders.cull) {ok = false}
	return ok
}

// world_destroy releases everything; call after gpu.wait_idle.
world_destroy :: proc(p: ^World_Pass, g: ^gpu.Gpu) {
	for &f in p.frames {
		if f.queries != 0 {vk.DestroyQueryPool(g.device, f.queries, nil)}
		gpu.destroy_buffer(g, &f.staging)
		gpu.destroy_buffer(g, &f.indirect)
		gpu.destroy_buffer(g, &f.cull_commands)
		gpu.destroy_buffer(g, &f.cull_stats)
		gpu.destroy_buffer(g, &f.cull_readback)
		gpu.destroy_buffer(g, &f.cull_staging)
		delete(f.queried)
		delete(f.copies)
		delete(f.draw_copies)
		delete(f.freed)
	}
	delete(p.setup_pending)
	delete(p.live)
	delete(p.live_at)
	delete(p.records)
	delete(p.dirty)
	delete(p.is_dirty)
	delete(p.water)
	delete(p.water_at)
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
	gpu.destroy_buffer(g, &p.cull_records)
	gpu.destroy_buffer(g, &p.vertices)
	for &pipeline in p.pipelines {gpu.destroy_pipeline(g, &pipeline)}
	gpu.destroy_pipeline(g, &p.cull_pipeline)
	p^ = {}
}

// world_begin starts this frame slot's uploads: its staging buffer is free
// again, and ranges removed when the slot was last used can be reused. What
// the slot's last culling pass counted is read back.
world_begin :: proc(p: ^World_Pass, g: ^gpu.Gpu) {
	f := &p.frames[gpu.frame_slot(g)]
	f.staging_used = 0
	f.commands = 0
	f.water = {}
	if f.culled > 0 {
		p.gpu_stats = (^Cull_Stats)(f.cull_readback.mapped)^
		f.culled = 0
	}
	clear(&f.copies)
	clear(&f.draw_copies)
	for r in f.freed {base.range_free(&p.ranges, r)}
	clear(&f.freed)
	p.stats.uploaded_bytes = 0
	// This slot's last occlusion queries are done (its fence was waited on).
	// A query counts only for a mesh the GPU found in view (the rest drew
	// nothing).
	if n := u32(len(f.queried)); n > 0 {
		results: [OCCLUSION_QUERIES]u64
		visible := mem.slice_data_cast(
			[]u32,
			f.cull_readback.mapped[size_of(Cull_Stats):f.cull_readback.size],
		)
		if vk.GetQueryPoolResults(
			   g.device,
			   f.queries,
			   0,
			   n,
			   int(n) * size_of(u64),
			   &results[0],
			   size_of(u64),
			   {._64},
		   ) ==
		   .SUCCESS {
			o := &p.occlusion_stats
			o.frames += 1
			for r, q in results[:n] {
				at := f.queried[q]
				if visible[at >> 5] & (1 << (at & 31)) == 0 {continue}
				o.queried += 1
				if r == 0 {o.hidden += 1}
			}
		}
		clear(&f.queried)
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
	if !hidden {live_add(p, h)}
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
	if m := base.pool_get(&p.meshes, h); m != nil && m.hidden {
		m.hidden = false
		live_add(p, h)
	}
}

// world_remove_mesh stops drawing the mesh; its memory is reused once the
// GPU is done with it.
world_remove_mesh :: proc(p: ^World_Pass, g: ^gpu.Gpu, h: Mesh_Handle) {
	m := base.pool_get(&p.meshes, h)
	if m == nil {return}
	append(&p.frames[gpu.frame_slot(g)].freed, m.range)
	if !m.hidden {live_remove(p, h, m)}
	base.pool_remove(&p.meshes, h)
}

// live_add puts a mesh being shown at the end of live (and of water, if it
// has some), its record to be copied.
@(private = "file")
live_add :: proc(p: ^World_Pass, h: Mesh_Handle) {
	m := base.pool_get(&p.meshes, h)
	slot := base.pool_index(h)
	p.live_at[slot] = u32(len(p.live))
	append(&p.live, Live_Mesh{m.chunk, h})
	record := Cull_Record {
		chunk        = m.chunk,
		slot         = slot,
		first_vertex = m.range.offset,
	}
	copy(record.counts[:FACE_GROUPS], m.counts[.Opaque][:])
	copy(record.counts[FACE_GROUPS:], m.counts[.Cutout][:])
	append(&p.records, record)
	record_dirty(p, p.live_at[slot])
	if m.layers[.Cutout] > 0 {
		live_swap(p, p.live_at[slot], p.cutouts)
		p.cutouts += 1
	}
	if m.layers[.Translucent] > 0 {
		p.water_at[slot] = u32(len(p.water))
		append(&p.water, Live_Mesh{m.chunk, h})
	}
}

// live_swap exchanges two places of live (and records), both to be copied.
@(private = "file")
live_swap :: proc(p: ^World_Pass, a, b: u32) {
	if a == b {return}
	p.live[a], p.live[b] = p.live[b], p.live[a]
	p.records[a], p.records[b] = p.records[b], p.records[a]
	p.live_at[base.pool_index(p.live[a].handle)] = a
	p.live_at[base.pool_index(p.live[b].handle)] = b
	record_dirty(p, a)
	record_dirty(p, b)
}

// live_remove takes a mesh shown out of live (and water): the last takes
// its place, its record to be copied there. A mesh with cutout faces first
// goes to the end of the cutout places, so they stay the first.
@(private = "file")
live_remove :: proc(p: ^World_Pass, h: Mesh_Handle, m: ^Mesh) {
	slot := base.pool_index(h)
	if m.layers[.Cutout] > 0 {
		live_swap(p, p.live_at[slot], p.cutouts - 1)
		p.cutouts -= 1
	}
	at := p.live_at[slot]
	live_swap(p, at, u32(len(p.live)) - 1)
	pop(&p.live)
	pop(&p.records)
	if m.layers[.Translucent] > 0 {
		at = p.water_at[slot]
		last := pop(&p.water)
		if int(at) < len(p.water) {
			p.water[at] = last
			p.water_at[base.pool_index(last.handle)] = at
		}
	}
}

@(private = "file")
record_dirty :: proc(p: ^World_Pass, at: u32) {
	if p.is_dirty[at] {return}
	p.is_dirty[at] = true
	append(&p.dirty, at)
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

// world_cull writes this frame's draw commands: the culling pass (compute,
// recorded here, before rendering) writes the opaque and cutout layers',
// the CPU the water's. scene: this frame's scene_upload (for camera).
world_cull :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64, camera: Camera) {
	p.stats.meshes = p.meshes.count
	p.stats.vertices_used = p.ranges.used
	p.stats.drawn = int(p.gpu_stats.drawn)
	p.stats.triangles = 0
	p.stats.api_draws = 0
	clear(&p.visible)
	clear(&p.near_first)
	clear(&p.water_near_first)
	if len(p.live) == 0 {return}
	slot := &p.frames[gpu.frame_slot(g)]
	if !cull_dispatch(p, g, frame.cmd, slot, scene) {return}
	slot.culled = u32(len(p.live))
	slot.cutouts = p.cutouts
	if p.occlusion && slot.queries != 0 {
		// The meshes with opaque faces nearest first (each drawn on its own,
		// in a query, after the nearer ones that may hide it).
		for l, at in p.live {
			if base.pool_get(&p.meshes, l.handle).layers[.Opaque] == 0 {continue}
			append(&p.near_first, distance_key(l.chunk, camera, u32(at)))
		}
		sort_keys(p.near_first[:], &p.sort_scratch)
	}

	// Water in view, drawn farthest first (blended over what is behind).
	planes := frustum_planes(camera.view_proj)
	for l in p.water {
		origin := (l.chunk - camera.chunk) * CHUNK_EXTENT
		lo := [3]f32{f32(origin.x), f32(origin.y), f32(origin.z)}
		if !box_visible(&planes, lo, lo + CHUNK_EXTENT) {continue}
		key := distance_key(l.chunk, camera, u32(len(p.visible)))
		append(&p.visible, Visible{base.pool_get(&p.meshes, l.handle), base.pool_index(l.handle)})
		append(&p.water_near_first, key)
	}
	if len(p.visible) == 0 || !indirect_reserve(g, slot, len(p.visible)) {return}
	sort_keys(p.water_near_first[:], &p.sort_scratch)
	commands := ([^]vk.DrawIndexedIndirectCommand)(slot.indirect.mapped)
	#reverse for key in p.water_near_first {
		v := &p.visible[u32(key)]
		m := v.mesh
		first := m.range.offset + m.layers[.Opaque] + m.layers[.Cutout]
		commands[slot.commands] = {m.layers[.Translucent] / 4 * 6, 1, 0, i32(first), v.slot}
		slot.commands += 1
		slot.water.triangles += int(m.layers[.Translucent] / 2)
	}
	slot.water.count = slot.commands
}

// distance_key: a sort key for a chunk by its distance from the camera
// (its centre's, squared): the distance's bits (ordered as the distance: it
// is not negative) over what it is the key of.
@(private = "file")
distance_key :: proc(chunk: [3]i32, camera: Camera, of: u32) -> u64 {
	origin := (chunk - camera.chunk) * CHUNK_EXTENT
	d := [3]f32{f32(origin.x), f32(origin.y), f32(origin.z)} + CHUNK_EXTENT / 2 - camera.position
	distance := d.x * d.x + d.y * d.y + d.z * d.z
	return u64(transmute(u32)distance) << 32 | u64(of)
}

// cull_dispatch records the culling pass: the records changed since last
// time copied into the table, the statistics cleared, world_cull.comp over
// every mesh shown, and the statistics copied for the CPU (world_begin
// reads them when the slot comes round again).
@(private = "file")
cull_dispatch :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	cmd: vk.CommandBuffer,
	f: ^World_Frame,
	scene: u64,
) -> bool {
	n := len(p.live)
	buffer_reserve(
		g,
		&f.cull_commands,
		n * CULL_LAYERS * CULL_RUNS * size_of(vk.DrawIndexedIndirectCommand),
		{.INDIRECT_BUFFER, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		false,
		"cull commands",
	) or_return
	buffer_reserve(
		g,
		&f.cull_staging,
		max(len(p.dirty), 1) * size_of(Cull_Record),
		{.TRANSFER_SRC},
		true,
		"cull staging",
	) or_return
	copies := make([dynamic]vk.BufferCopy, 0, len(p.dirty), context.temp_allocator)
	for at in p.dirty {
		p.is_dirty[at] = false
		if int(at) >= n {continue} 	// (no longer a place: the list shrank)
		offset := len(copies) * size_of(Cull_Record)
		mem.copy(&f.cull_staging.mapped[offset], &p.records[at], size_of(Cull_Record))
		append(
			&copies,
			vk.BufferCopy {
				srcOffset = vk.DeviceSize(offset),
				dstOffset = vk.DeviceSize(at) * size_of(Cull_Record),
				size = size_of(Cull_Record),
			},
		)
	}
	clear(&p.dirty)

	gpu.begin_label(g, cmd, "cull")
	defer gpu.end_label(g, cmd)
	// The table was last read by the previous frame's pass: written after it.
	// Those copies' own writes (the stats readback below, written again by this
	// frame slot's next pass) are ordered before this frame's too.
	memory_barrier(
		cmd,
		{.COMPUTE_SHADER, .COPY},
		{.TRANSFER_WRITE},
		{.COPY, .CLEAR},
		{.TRANSFER_WRITE},
	)
	stats_size := size_of(Cull_Stats) + (n + 31) / 32 * size_of(u32)
	vk.CmdFillBuffer(cmd, f.cull_stats.handle, 0, vk.DeviceSize(stats_size), 0)
	if len(copies) > 0 {
		vk.CmdCopyBuffer(
			cmd,
			f.cull_staging.handle,
			p.cull_records.handle,
			u32(len(copies)),
			raw_data(copies),
		)
	}
	memory_barrier(
		cmd,
		{.COPY, .CLEAR},
		{.TRANSFER_WRITE},
		{.COMPUTE_SHADER},
		{.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE},
	)
	vk.CmdBindPipeline(cmd, .COMPUTE, p.cull_pipeline.handle)
	push := Cull_Push {
		scene    = scene,
		records  = gpu.buffer_address(g, p.cull_records),
		commands = gpu.buffer_address(g, f.cull_commands),
		stats    = gpu.buffer_address(g, f.cull_stats),
		count    = u32(n),
		cutouts  = p.cutouts,
	}
	gpu.push_constants(g, cmd, &push)
	vk.CmdDispatch(cmd, u32(n + CULL_GROUP - 1) / CULL_GROUP, 1, 1)
	memory_barrier(
		cmd,
		{.COMPUTE_SHADER},
		{.SHADER_STORAGE_WRITE},
		{.DRAW_INDIRECT, .COPY},
		{.INDIRECT_COMMAND_READ, .TRANSFER_READ},
	)
	region := vk.BufferCopy {
		size = vk.DeviceSize(stats_size),
	}
	vk.CmdCopyBuffer(cmd, f.cull_stats.handle, f.cull_readback.handle, 1, &region)
	memory_barrier(cmd, {.COPY}, {.TRANSFER_WRITE}, {.HOST}, {.HOST_READ})
	return true
}

CULL_GROUP :: 64 // world_cull.comp's local_size_x

@(private)
memory_barrier :: proc(
	cmd: vk.CommandBuffer,
	src_stage: vk.PipelineStageFlags2,
	src_access: vk.AccessFlags2,
	dst_stage: vk.PipelineStageFlags2,
	dst_access: vk.AccessFlags2,
) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = src_stage,
		srcAccessMask = src_access,
		dstStageMask  = dst_stage,
		dstAccessMask = dst_access,
	}
	dep := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

// world_draw draws the opaque and cutout layers: every mesh's commands the
// culling pass wrote, one indirect draw a layer (with occlusion statistics,
// the opaque layer a draw a mesh, nearest first). Call inside rendering.
// scene: this frame's scene_upload (for world_cull's camera).
world_draw :: proc(p: ^World_Pass, g: ^gpu.Gpu, frame: gpu.Frame, scene: u64) {
	slot := &p.frames[gpu.frame_slot(g)]
	n := int(slot.culled)
	if n == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "world")
	defer gpu.end_label(g, cmd)
	// What they draw is known on the GPU: counted once, as last read back.
	calls, triangles := int(p.gpu_stats.commands), int(p.gpu_stats.triangles)
	for layer, l in ([2]Mesh_Layer{.Opaque, .Cutout}) {
		draw_begin(p, g, cmd, layer, scene, 0)
		first := l * n * CULL_RUNS
		count := n if layer == .Opaque else int(slot.cutouts)
		if layer == .Opaque && len(p.near_first) > 0 {
			for key in p.near_first {
				at := u32(key)
				query := len(slot.queried) < OCCLUSION_QUERIES
				if query {vk.CmdBeginQuery(cmd, slot.queries, u32(len(slot.queried)), {})}
				draw_commands(
					p,
					g,
					cmd,
					slot.cull_commands,
					first + int(at) * CULL_RUNS,
					CULL_RUNS,
					triangles,
					calls,
				)
				triangles, calls = 0, 0
				if query {
					vk.CmdEndQuery(cmd, slot.queries, u32(len(slot.queried)))
					append(&slot.queried, at)
				}
			}
			continue
		}
		draw_commands(p, g, cmd, slot.cull_commands, first, count * CULL_RUNS, triangles, calls)
		triangles, calls = 0, 0
	}
}

// world_draw_translucent draws the water world_cull found in view, the
// farthest chunks first (blending needs what is behind drawn already: the
// commands are written in that order). Call after world_draw. time:
// seconds, for the moving surface.
world_draw_translucent :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	frame: gpu.Frame,
	scene: u64,
	time: f32,
) {
	slot := &p.frames[gpu.frame_slot(g)]
	if slot.water.count == 0 {return}
	cmd := frame.cmd
	gpu.begin_label(g, cmd, "water")
	defer gpu.end_label(g, cmd)
	draw_begin(p, g, cmd, .Translucent, scene, time)
	s := slot.water
	draw_commands(p, g, cmd, slot.indirect, s.first, s.count, s.triangles)
}

// Span: commands drawn by one indirect draw.
@(private)
Span :: struct {
	first, count: int,
	triangles:    int,
}

// Live_Mesh: a mesh's chunk, for culling.
@(private)
Live_Mesh :: struct {
	chunk:  [3]i32,
	handle: Mesh_Handle,
}

// Visible: a mesh with water in view this frame.
@(private)
Visible :: struct {
	mesh: ^Mesh,
	slot: u32, // its pool slot: its record in the chunk draw table
}

// facing: which face groups of a chunk whose box starts at lo can face a
// camera at eye: a group's faces lie within the chunk's box, so +x faces can
// face the camera only when it is past the box's low x side, and so on;
// both-ways faces (plants) always can. (world_cull.comp has the same.)
@(private)
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

// Cull_Command: what world_cull.comp writes (vk.DrawIndexedIndirectCommand).
Cull_Command :: vk.DrawIndexedIndirectCommand

// cull_reference: what world_cull.comp writes for the record r, by the same
// rules on the CPU (world_cull_check compares the two), and its share of
// the statistics.
@(private)
cull_reference :: proc(
	r: Cull_Record,
	planes: ^Planes,
	eye: [3]f32,
	camera_chunk: [3]i32,
) -> (
	commands: [CULL_LAYERS * CULL_RUNS]Cull_Command,
	stats: Cull_Stats,
	in_view: bool,
) {
	origin := (r.chunk - camera_chunk) * CHUNK_EXTENT
	lo := [3]f32{f32(origin.x), f32(origin.y), f32(origin.z)}
	in_view = box_visible(planes, lo, lo + CHUNK_EXTENT)
	faces := facing(lo, eye) if in_view else 0
	first := r.first_vertex
	r := r
	for layer in 0 ..< CULL_LAYERS {
		counts := r.counts[layer * FACE_GROUPS:][:FACE_GROUPS]
		runs := face_runs(faces, counts, first)
		for run, i in runs {
			if run.count == 0 {continue}
			commands[layer * CULL_RUNS + i] = {run.count / 4 * 6, 1, 0, i32(run.first), r.slot}
			stats.commands += 1
		}
		for n, group in counts {
			if faces & (1 << u8(group)) != 0 {stats.triangles += n / 2}
			first += n
		}
	}
	opaque: u32
	for n in r.counts[:FACE_GROUPS] {opaque += n}
	if in_view && opaque > 0 {stats.drawn = 1}
	return
}

// Run: vertices first ..< first + count of a layer, drawn by one command.
@(private)
Run :: struct {
	first, count: u32,
}

// bridged: faces, and when its groups make three runs (the most they can), the
// group-wide gap whose groups have the fewer vertices (the earlier on a tie)
// too, so they make two. world_cull.comp has the same.
@(private)
bridged :: proc(faces: u8, counts: []u32) -> u8 {
	first, last := -1, -1
	for g in 0 ..< len(counts) {
		if faces & (1 << u8(g)) != 0 {
			if first < 0 {first = g}
			last = g
		}
	}
	From_To :: struct {
		from, to: int, // the groups from ..< to
		vertices: u32,
	}
	gaps: [2]From_To
	n := 0
	for g := first; first >= 0 && g <= last; {
		if faces & (1 << u8(g)) != 0 {
			g += 1
			continue
		}
		if n == len(gaps) {return faces}
		gaps[n].from = g
		for g <= last && faces & (1 << u8(g)) == 0 {
			gaps[n].vertices += counts[g]
			g += 1
		}
		gaps[n].to = g
		n += 1
	}
	if n < len(gaps) {return faces}
	gap := gaps[1] if gaps[1].vertices < gaps[0].vertices else gaps[0]
	filled := faces
	for g in gap.from ..< gap.to {filled |= 1 << u8(g)}
	return filled
}

// face_runs: the runs of a layer's face groups (counts, from its first
// vertex) whose bit is set in faces, or in the gap `bridged` fills, adjacent
// groups in one run; empty runs after them. There are never more than
// CULL_RUNS (test_runs_of_visible_face_groups).
@(private)
face_runs :: proc(visible: u8, counts: []u32, first: u32) -> (runs: [CULL_RUNS]Run) {
	faces := bridged(visible, counts)
	n := 0
	at := first
	for count, group in counts {
		if faces & (1 << u8(group)) != 0 {
			if runs[n].count == 0 {runs[n].first = at}
			runs[n].count += count
		} else if n < CULL_RUNS - 1 && runs[n].count > 0 {
			n += 1
		}
		at += count
	}
	return
}

// indirect_reserve makes this slot's water command buffer hold at least n
// commands; its last frame is done with it.
@(private = "file")
indirect_reserve :: proc(g: ^gpu.Gpu, f: ^World_Frame, n: int) -> bool {
	return buffer_reserve(
		g,
		&f.indirect,
		n * size_of(vk.DrawIndexedIndirectCommand),
		{.INDIRECT_BUFFER},
		true,
		"world draw commands",
	)
}

// buffer_reserve makes b hold at least size bytes (doubling it; what it
// held is lost); nothing may still use it.
@(private = "file")
buffer_reserve :: proc(
	g: ^gpu.Gpu,
	b: ^gpu.Buffer,
	size: int,
	usage: vk.BufferUsageFlags,
	host_visible: bool,
	name: string,
) -> bool {
	if b.size >= size {return true}
	grown := max(b.size, 64 * 1024)
	for grown < size {grown *= 2}
	gpu.destroy_buffer(g, b)
	ok: bool
	b^, ok = gpu.create_buffer(g, grown, usage, host_visible, name)
	if !ok {log.errorf("render could not make a %d-byte buffer (%s)", grown, name)}
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

// draw_commands draws count commands from first in buffer (none: no call);
// triangles and calls: what they draw (calls -1: every command).
@(private = "file")
draw_commands :: proc(
	p: ^World_Pass,
	g: ^gpu.Gpu,
	cmd: vk.CommandBuffer,
	buffer: gpu.Buffer,
	first, count, triangles: int,
	calls := -1,
) {
	if count == 0 {return}
	api_calls := g.draws.api_calls
	gpu.draw_indexed_indirect(
		g,
		cmd,
		buffer.handle,
		first * size_of(vk.DrawIndexedIndirectCommand),
		u32(count),
		triangles,
		calls,
	)
	p.stats.api_draws += g.draws.api_calls - api_calls
	p.stats.triangles += triangles
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
