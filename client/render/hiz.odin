package render

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

import "client:gpu"

// The depth pyramid: the world's depth, reduced level by level to the
// farthest depth each texel covers, so a box can be tested against it with
// four reads (occluded; assets/shaders/occlusion.glsl). Reverse Z (near 1,
// far 0): the farthest depth of a region is its minimum, so the reduction
// is the minimum.
//
// The frame's rendering is split round it (client/main/frame.odin):
//
//	gpu.begin_rendering(frame, clear)       // A: the world's opaque and cutout depth
//	render.world_draw(...)
//	gpu.end_rendering(frame)
//	render.hiz_frame(&pass.hiz, &g, frame)  // the pyramid, from that depth
//	gpu.begin_rendering(frame, clear, load = true)  // B: everything else, as before
//
// Level 0 is the largest power of two at or below the depth image's size,
// on each axis separately (1280 x 720 gives 1024 x 512); each level below
// halves each axis down to 1. A level-0 texel x covers depth texels
// [floor(x * W / w0), ceil((x + 1) * W / w0)) across and likewise down, so
// every depth texel is in some footprint. One dispatch per level
// (hiz.comp), each reading the one above as a sampled image and writing its
// own as a storage image, with a barrier between.
//
// The pyramid is R32_SFLOAT, in GENERAL layout whenever it is used, sampled
// by texture id (Hiz_Info) by compute shaders on the shared layout. There
// is one, shared by the frames in flight like the depth image it is built
// from (their work is ordered on the one queue). Its compute pass has a
// pipeline layout of its own: one descriptor set per level (binding 0 the
// source, binding 1 the level, binding 2 a sampler for the source's
// gathers), written when the pyramid is remade
// (hiz_resize: after the GPU is idle, never while a frame uses them).

HIZ_MAX_MIPS :: 16 // level 0 at most 32768 texels wide
HIZ_GROUP :: 8 // hiz.comp's local size, each way

Hiz :: struct {
	image:           gpu.Image,
	mips:            u32,
	size:            [2]u32, // level 0's
	depth_size:      [2]u32, // the depth image it is built from
	views:           [HIZ_MAX_MIPS]vk.ImageView, // one level each
	sets:            [HIZ_MAX_MIPS]vk.DescriptorSet,
	texture_id:      gpu.Texture_Id, // the whole pyramid, sampled (in GENERAL)
	layout:          vk.DescriptorSetLayout,
	pipeline_layout: vk.PipelineLayout,
	pool:            vk.DescriptorPool,
	sampler:         vk.Sampler, // nearest, clamped: hiz.comp's gathers
	pipeline:        gpu.Pipeline,
	depth_version:   u32, // gpu.Gpu.depth_version the sets were written for
}

// Hiz_Info matches occlusion.glsl's: what the occlusion test needs.
Hiz_Info :: struct {
	size:       [2]u32,
	mips:       u32,
	texture_id: u32,
}

@(private = "file")
Hiz_Push :: struct {
	source_size: [2]u32,
	target_size: [2]u32,
}

// hiz_sizes: level 0's size and the number of levels for a depth image.
hiz_sizes :: proc(depth: [2]u32) -> (size: [2]u32, mips: u32) {
	for axis in 0 ..< 2 {
		size[axis] = 1
		for size[axis] * 2 <= depth[axis] && size[axis] < 1 << (HIZ_MAX_MIPS - 1) {size[axis] *= 2}
	}
	mips = 1
	for max(size.x, size.y) >> mips > 0 {mips += 1}
	return
}

// hiz_mip_size: a level's size.
hiz_mip_size :: proc(size: [2]u32, level: u32) -> [2]u32 {
	return {max(size.x >> level, 1), max(size.y >> level, 1)}
}

// hiz_footprint: the source texels [lo, hi) a texel x of a level `target`
// wide covers in a source `source` wide (one axis).
hiz_footprint :: proc(x, source, target: u32) -> (lo, hi: u32) {
	return x * source / target, ((x + 1) * source + target - 1) / target
}

hiz_info :: proc(h: ^Hiz) -> Hiz_Info {
	return {h.size, h.mips, u32(h.texture_id)}
}

// hiz_init makes the pyramid's pipeline (from hiz.comp's SPIR-V); the
// pyramid itself is made by hiz_resize.
hiz_init :: proc(h: ^Hiz, g: ^gpu.Gpu, spirv: []byte) -> bool {
	h^ = {}
	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .NEAREST,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
	}
	gpu.check(vk.CreateSampler(g.device, &sampler_info, nil, &h.sampler)) or_return
	gpu.set_name(g, .SAMPLER, u64(h.sampler), "depth pyramid sampler")
	bindings := [3]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		},
		{
			binding = 1,
			descriptorType = .STORAGE_IMAGE,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		},
		{
			binding = 2,
			descriptorType = .SAMPLER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
			pImmutableSamplers = &h.sampler,
		},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}
	gpu.check(vk.CreateDescriptorSetLayout(g.device, &layout_info, nil, &h.layout)) or_return
	push := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		size       = size_of(Hiz_Push),
	}
	pl_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &h.layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	gpu.check(vk.CreatePipelineLayout(g.device, &pl_info, nil, &h.pipeline_layout)) or_return
	gpu.set_name(g, .PIPELINE_LAYOUT, u64(h.pipeline_layout), "depth pyramid layout")
	sizes := [3]vk.DescriptorPoolSize {
		{.SAMPLED_IMAGE, HIZ_MAX_MIPS},
		{.SAMPLER, HIZ_MAX_MIPS},
		{.STORAGE_IMAGE, HIZ_MAX_MIPS},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = HIZ_MAX_MIPS,
		poolSizeCount = len(sizes),
		pPoolSizes    = &sizes[0],
	}
	gpu.check(vk.CreateDescriptorPool(g.device, &pool_info, nil, &h.pool)) or_return
	h.pipeline = gpu.create_compute_pipeline(
		g,
		"depth pyramid",
		spirv,
		h.pipeline_layout,
	) or_return
	return true
}

// hiz_reload swaps in a new hiz.comp (hot reload); false keeps the old one.
hiz_reload :: proc(h: ^Hiz, g: ^gpu.Gpu, spirv: []byte) -> bool {
	return gpu.replace_compute_pipeline(g, &h.pipeline, "depth pyramid", spirv, h.pipeline_layout)
}

// hiz_destroy releases everything; call after gpu.wait_idle.
hiz_destroy :: proc(h: ^Hiz, g: ^gpu.Gpu) {
	hiz_free_image(h, g)
	gpu.destroy_pipeline(g, &h.pipeline)
	if h.pool != 0 {vk.DestroyDescriptorPool(g.device, h.pool, nil)}
	if h.pipeline_layout != 0 {vk.DestroyPipelineLayout(g.device, h.pipeline_layout, nil)}
	if h.layout != 0 {vk.DestroyDescriptorSetLayout(g.device, h.layout, nil)}
	if h.sampler != 0 {vk.DestroySampler(g.device, h.sampler, nil)}
	h^ = {}
}

@(private = "file")
hiz_free_image :: proc(h: ^Hiz, g: ^gpu.Gpu) {
	if h.image.handle == 0 {return}
	gpu.unregister_texture(g, h.texture_id)
	for &v in h.views {
		if v != 0 {vk.DestroyImageView(g.device, v, nil)}
		v = 0
	}
	if h.pool != 0 {vk.ResetDescriptorPool(g.device, h.pool, {})}
	h.sets = {}
	gpu.destroy_image(g, &h.image)
	h.mips, h.size, h.depth_size = 0, {}, {}
}

// hiz_resize remakes the pyramid for a depth image (its view is what level
// 0 reads): its levels, their views and descriptor sets. It idles the GPU
// first (a frame in flight may be using the old ones); the depth images are
// remade only after an idle anyway (gpu: the swapchain's and the offscreen
// image's), so this costs nothing more.
hiz_resize :: proc(h: ^Hiz, g: ^gpu.Gpu, depth: gpu.Image) -> bool {
	gpu.wait_idle(g)
	hiz_free_image(h, g)
	h.depth_size = {depth.width, depth.height}
	h.size, h.mips = hiz_sizes(h.depth_size)
	h.image = gpu.create_image(
		g,
		h.size.x,
		h.size.y,
		.R32_SFLOAT,
		{.STORAGE, .SAMPLED, .TRANSFER_SRC},
		"depth pyramid",
		mips = h.mips,
	) or_return
	h.texture_id = gpu.register_texture(g, h.image.view, .GENERAL) or_return
	layouts: [HIZ_MAX_MIPS]vk.DescriptorSetLayout
	for &l in layouts {l = h.layout}
	alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = h.pool,
		descriptorSetCount = h.mips,
		pSetLayouts        = &layouts[0],
	}
	gpu.check(vk.AllocateDescriptorSets(g.device, &alloc, &h.sets[0])) or_return
	for level in 0 ..< h.mips {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = h.image.handle,
			viewType = .D2,
			format = .R32_SFLOAT,
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = level,
				levelCount = 1,
				layerCount = 1,
			},
		}
		gpu.check(vk.CreateImageView(g.device, &view_info, nil, &h.views[level])) or_return
		gpu.set_name(
			g,
			.IMAGE_VIEW,
			u64(h.views[level]),
			fmt.tprintf("depth pyramid level %d", level),
		)
	}
	for level in 0 ..< h.mips {
		source := vk.DescriptorImageInfo {
			imageView   = depth.view if level == 0 else h.views[level - 1],
			imageLayout = .SHADER_READ_ONLY_OPTIMAL if level == 0 else .GENERAL,
		}
		target := vk.DescriptorImageInfo {
			imageView   = h.views[level],
			imageLayout = .GENERAL,
		}
		writes := [2]vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = h.sets[level],
				dstBinding = 0,
				descriptorCount = 1,
				descriptorType = .SAMPLED_IMAGE,
				pImageInfo = &source,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = h.sets[level],
				dstBinding = 1,
				descriptorCount = 1,
				descriptorType = .STORAGE_IMAGE,
				pImageInfo = &target,
			},
		}
		vk.UpdateDescriptorSets(g.device, len(writes), &writes[0], 0, nil)
	}
	log.debugf(
		"render depth pyramid size=%dx%d levels=%d (depth %dx%d)",
		h.size.x,
		h.size.y,
		h.mips,
		depth.width,
		depth.height,
	)
	return true
}

// hiz_frame builds the pyramid from the frame's depth (outside rendering,
// after the world's opaque and cutout layers), remaking it first if the
// depth image was remade.
hiz_frame :: proc(h: ^Hiz, g: ^gpu.Gpu, frame: gpu.Frame) {
	if h.depth_version != g.depth_version || h.image.handle == 0 {
		if !hiz_resize(h, g, frame.depth) {
			log.error("render could not make the depth pyramid")
			hiz_free_image(h, g)
			return
		}
		h.depth_version = g.depth_version
	}
	// Timed as a section of the frame (gpu_hiz); hiz_build alone is not, so
	// the check can record it outside the frames.
	gpu.begin_label(g, frame.cmd, "depth pyramid")
	defer gpu.end_label(g, frame.cmd)
	hiz_build(h, g, frame.cmd, frame.depth)
}

// hiz_build records the pyramid's levels from depth (in
// DEPTH_ATTACHMENT_OPTIMAL, after its last write; left so again for the
// rendering after). The pyramid is ready for compute shaders' sampled reads.
hiz_build :: proc(h: ^Hiz, g: ^gpu.Gpu, cmd: vk.CommandBuffer, depth: gpu.Image) {
	if h.image.handle == 0 {return}
	// The depth from the world's tests to this pass's reads; the pyramid's
	// old contents (read by the last frame's compute shaders) discarded.
	to_read := [2]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask = {.COMPUTE_SHADER},
			dstAccessMask = {.SHADER_SAMPLED_READ},
			oldLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			newLayout = .SHADER_READ_ONLY_OPTIMAL,
			image = depth.handle,
			subresourceRange = gpu.whole_image(depth),
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COMPUTE_SHADER, .COPY},
			dstStageMask = {.COMPUTE_SHADER},
			dstAccessMask = {.SHADER_STORAGE_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .GENERAL,
			image = h.image.handle,
			subresourceRange = gpu.whole_image(h.image),
		},
	}
	image_barriers(cmd, to_read[:])
	vk.CmdBindPipeline(cmd, .COMPUTE, h.pipeline.handle)
	source := [2]u32{depth.width, depth.height}
	for level in 0 ..< h.mips {
		if level > 0 {
			// The level above, written, before it is read.
			memory_barrier(
				cmd,
				{.COMPUTE_SHADER},
				{.SHADER_STORAGE_WRITE},
				{.COMPUTE_SHADER},
				{.SHADER_SAMPLED_READ},
			)
		}
		target := hiz_mip_size(h.size, level)
		vk.CmdBindDescriptorSets(cmd, .COMPUTE, h.pipeline_layout, 0, 1, &h.sets[level], 0, nil)
		push := Hiz_Push{source, target}
		vk.CmdPushConstants(cmd, h.pipeline_layout, {.COMPUTE}, 0, size_of(push), &push)
		vk.CmdDispatch(
			cmd,
			(target.x + HIZ_GROUP - 1) / HIZ_GROUP,
			(target.y + HIZ_GROUP - 1) / HIZ_GROUP,
			1,
		)
		source = target
	}
	// The depth back to its tests (after this pass's reads); the pyramid to
	// compute shaders' sampled reads and copies.
	to_draw := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COMPUTE_SHADER},
		dstStageMask     = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		dstAccessMask    = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
		oldLayout        = .SHADER_READ_ONLY_OPTIMAL,
		newLayout        = .DEPTH_ATTACHMENT_OPTIMAL,
		image            = depth.handle,
		subresourceRange = gpu.whole_image(depth),
	}
	image_barriers(cmd, {to_draw})
	memory_barrier(
		cmd,
		{.COMPUTE_SHADER},
		{.SHADER_STORAGE_WRITE},
		{.COMPUTE_SHADER, .COPY},
		{.SHADER_SAMPLED_READ, .TRANSFER_READ},
	)
}

@(private)
image_barriers :: proc(cmd: vk.CommandBuffer, barriers: []vk.ImageMemoryBarrier2) {
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = u32(len(barriers)),
		pImageMemoryBarriers    = raw_data(barriers),
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

// Hiz_Reference: the pyramid on the CPU (hiz_reference), level by level.
Hiz_Reference :: struct {
	size:   [2]u32,
	mips:   u32,
	levels: [HIZ_MAX_MIPS][]f32, // row by row
}

// hiz_reference builds the pyramid of a depth image (row by row) on the
// CPU: the same sizes, footprints and minimum as hiz.comp.
hiz_reference :: proc(
	depth: []f32,
	depth_size: [2]u32,
	allocator := context.allocator,
) -> (
	r: Hiz_Reference,
) {
	r.size, r.mips = hiz_sizes(depth_size)
	source, source_size := depth, depth_size
	for level in 0 ..< r.mips {
		size := hiz_mip_size(r.size, level)
		out := make([]f32, size.x * size.y, allocator)
		for y in 0 ..< size.y {
			y0, y1 := hiz_footprint(y, source_size.y, size.y)
			for x in 0 ..< size.x {
				x0, x1 := hiz_footprint(x, source_size.x, size.x)
				farthest := source[y0 * source_size.x + x0]
				for sy in y0 ..< y1 {
					for sx in x0 ..< x1 {farthest = min(farthest, source[sy * source_size.x + sx])}
				}
				out[y * size.x + x] = farthest
			}
		}
		r.levels[level] = out
		source, source_size = out, size
	}
	return
}

HIZ_NEAR_W :: 1e-3 // occlusion.glsl's

// Occlusion_Verdict: occlusion_reference's verdict, and how close its
// inputs came to a boundary where the GPU's rounding could decide
// otherwise (the check keeps its boxes away from them).
Occlusion_Verdict :: struct {
	occluded:     bool,
	// The smallest distances: of the nearest depth from the farthest; of a
	// rectangle edge from a texel edge at the level tested, or of the extent
	// from the next level's, in level-0 texels; of a corner's w from HIZ_NEAR_W
	// and of a corner from the screen's edge, in NDC.
	depth_margin: f32,
	texel_margin: f32,
	ndc_margin:   f32,
}

// occlusion_reference: occluded (occlusion.glsl) on the CPU, against a
// Hiz_Reference, written from the same rules.
occlusion_reference :: proc(
	view_proj: matrix[4, 4]f32,
	lo, hi: [3]f32,
	hiz: ^Hiz_Reference,
) -> (
	v: Occlusion_Verdict,
) {
	v.depth_margin, v.texel_margin, v.ndc_margin = max(f32), max(f32), max(f32)
	rmin, rmax := [2]f32{1e30, 1e30}, [2]f32{-1e30, -1e30}
	nearest: f32 = 0
	for i in 0 ..< 8 {
		p := [4]f32 {
			hi.x if i & 1 != 0 else lo.x,
			hi.y if i & 2 != 0 else lo.y,
			hi.z if i & 4 != 0 else lo.z,
			1,
		}
		c := view_proj * p
		v.ndc_margin = min(v.ndc_margin, abs(c.w - HIZ_NEAR_W))
		if c.w <= HIZ_NEAR_W {return}
		xy := c.xy / c.w
		for axis in 0 ..< 2 {v.ndc_margin = min(v.ndc_margin, abs(abs(xy[axis]) - 1))}
		rmin = {min(rmin.x, xy.x), min(rmin.y, xy.y)}
		rmax = {max(rmax.x, xy.x), max(rmax.y, xy.y)}
		nearest = max(nearest, c.z / c.w)
	}
	rmin = {max(rmin.x, -1), max(rmin.y, -1)}
	rmax = {min(rmax.x, 1), min(rmax.y, 1)}
	if rmin.x > rmax.x || rmin.y > rmax.y {return}
	size := [2]f32{f32(hiz.size.x), f32(hiz.size.y)}
	a := (rmin * 0.5 + 0.5) * size
	b := (rmax * 0.5 + 0.5) * size
	e := max(b.x - a.x, b.y - a.y)
	level: u32 = 0
	for level < hiz.mips - 1 && f32(u32(1) << level) < e {level += 1}
	for l in 0 ..< hiz.mips {v.texel_margin = min(v.texel_margin, abs(e - f32(u32(1) << l)))}
	scale := f32(u32(1) << level)
	mip := hiz_mip_size(hiz.size, level)
	last := [2]i32{i32(mip.x) - 1, i32(mip.y) - 1}
	t0, t1: [2]i32
	for axis in 0 ..< 2 {
		for edge in ([2]f32{a[axis], b[axis]}) {
			s := edge / scale
			v.texel_margin = min(v.texel_margin, abs(s - f32(i32(s + 0.5))) * scale)
		}
		t0[axis] = clamp(i32(floor_f32(a[axis] / scale)), 0, last[axis])
		t1[axis] = clamp(i32(floor_f32(b[axis] / scale)), 0, last[axis])
	}
	level_data := hiz.levels[level]
	fetch :: proc(data: []f32, width: u32, t: [2]i32) -> f32 {return(
			data[u32(t.y) * width + u32(t.x)] \
		)}
	farthest := min(
		min(fetch(level_data, mip.x, t0), fetch(level_data, mip.x, {t1.x, t0.y})),
		min(fetch(level_data, mip.x, {t0.x, t1.y}), fetch(level_data, mip.x, t1)),
	)
	v.depth_margin = abs(nearest - farthest)
	v.occluded = nearest < farthest
	return
}

@(private = "file")
floor_f32 :: proc(x: f32) -> f32 {
	t := f32(i32(x))
	return t - 1 if t > x else t
}
