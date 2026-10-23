package gpu

import "core:log"
import vk "vendor:vulkan"

// Bindless resources. One descriptor set holds every texture (binding 0, an
// array indexed by Texture_Id) and the samplers (binding 1); every pipeline
// shares one layout: that set plus PUSH_CONSTANT_SIZE bytes of push
// constants. Shaders declare:
//
//	layout(set = 0, binding = 0) uniform texture2D textures[];
//	layout(set = 0, binding = 1) uniform sampler samplers[SAMPLER_COUNT];
//
// (texture2DArray textures[] for array textures: the same binding, viewed
// with the type of the image at the index used.)
//
// and receive texture ids through push constants.

MAX_TEXTURES :: 1024
PUSH_CONSTANT_SIZE :: 128

Texture_Id :: distinct u32

// Samplers, by index in binding 1.
Sampler :: enum u32 {
	Nearest, // pixel-exact (UI glyphs)
	Linear,
	// Pixel art on surfaces (blocks): sharp texels up close, mipmapped and
	// anisotropic at a distance, repeating.
	Pixel_Art,
}

@(private)
Bindless :: struct {
	layout:      vk.DescriptorSetLayout,
	pool:        vk.DescriptorPool,
	set:         vk.DescriptorSet,
	samplers:    [Sampler]vk.Sampler,
	texture_ids: [MAX_TEXTURES]bool, // in use
}

@(private)
bindless_init :: proc(g: ^Gpu) -> bool {
	b := &g.bindless
	for s in Sampler {
		info := vk.SamplerCreateInfo {
			sType        = .SAMPLER_CREATE_INFO,
			magFilter    = .NEAREST if s == .Nearest else .LINEAR,
			minFilter    = .NEAREST if s == .Nearest else .LINEAR,
			mipmapMode   = .NEAREST,
			addressModeU = .CLAMP_TO_EDGE,
			addressModeV = .CLAMP_TO_EDGE,
			addressModeW = .CLAMP_TO_EDGE,
			maxLod       = vk.LOD_CLAMP_NONE,
		}
		if s == .Pixel_Art {
			info.magFilter = .NEAREST
			info.mipmapMode = .LINEAR
			info.addressModeU, info.addressModeV = .REPEAT, .REPEAT
			if g.max_anisotropy > 1 {
				info.anisotropyEnable = true
				info.maxAnisotropy = min(g.max_anisotropy, 8)
			}
		}
		check(vk.CreateSampler(g.device, &info, nil, &b.samplers[s])) or_return
	}
	set_name(g, .SAMPLER, u64(b.samplers[.Nearest]), "nearest sampler")
	set_name(g, .SAMPLER, u64(b.samplers[.Linear]), "linear sampler")
	set_name(g, .SAMPLER, u64(b.samplers[.Pixel_Art]), "pixel art sampler")

	samplers := b.samplers
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = MAX_TEXTURES,
			stageFlags = {.VERTEX, .FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .SAMPLER,
			descriptorCount = len(Sampler),
			stageFlags = {.VERTEX, .FRAGMENT},
			pImmutableSamplers = &samplers[Sampler(0)],
		},
	}
	binding_flags := [2]vk.DescriptorBindingFlags{{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}, {}}
	flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = len(binding_flags),
		pBindingFlags = &binding_flags[0],
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}
	check(vk.CreateDescriptorSetLayout(g.device, &layout_info, nil, &b.layout)) or_return

	sizes := [2]vk.DescriptorPoolSize{{.SAMPLED_IMAGE, MAX_TEXTURES}, {.SAMPLER, len(Sampler)}}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = len(sizes),
		pPoolSizes    = &sizes[0],
	}
	check(vk.CreateDescriptorPool(g.device, &pool_info, nil, &b.pool)) or_return
	alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = b.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &b.layout,
	}
	check(vk.AllocateDescriptorSets(g.device, &alloc, &b.set)) or_return
	set_name(g, .DESCRIPTOR_SET, u64(b.set), "bindless set")

	push := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = PUSH_CONSTANT_SIZE,
	}
	pl_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &b.layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	check(vk.CreatePipelineLayout(g.device, &pl_info, nil, &g.pipeline_layout)) or_return
	set_name(g, .PIPELINE_LAYOUT, u64(g.pipeline_layout), "shared pipeline layout")
	return true
}

@(private)
bindless_destroy :: proc(g: ^Gpu) {
	b := &g.bindless
	if g.pipeline_layout != 0 {vk.DestroyPipelineLayout(g.device, g.pipeline_layout, nil)}
	if b.pool != 0 {vk.DestroyDescriptorPool(g.device, b.pool, nil)} 	// frees the set
	if b.layout != 0 {vk.DestroyDescriptorSetLayout(g.device, b.layout, nil)}
	for s in b.samplers {if s != 0 {vk.DestroySampler(g.device, s, nil)}}
	b^ = {}
}

// register_texture makes an image view sampleable by Texture_Id. The image
// must be in SHADER_READ_ONLY_OPTIMAL whenever a shader samples it.
register_texture :: proc(g: ^Gpu, view: vk.ImageView) -> (id: Texture_Id, ok: bool) {
	b := &g.bindless
	for used, i in b.texture_ids {
		if used {continue}
		info := vk.DescriptorImageInfo {
			imageView   = view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = b.set,
			dstBinding      = 0,
			dstArrayElement = u32(i),
			descriptorCount = 1,
			descriptorType  = .SAMPLED_IMAGE,
			pImageInfo      = &info,
		}
		vk.UpdateDescriptorSets(g.device, 1, &write, 0, nil)
		b.texture_ids[i] = true
		return Texture_Id(i), true
	}
	log.error("gpu out of texture slots")
	return 0, false
}

// unregister_texture frees the slot. Only once no submitted frame can still
// sample it (e.g. after wait_idle, or FRAMES_IN_FLIGHT frames later).
unregister_texture :: proc(g: ^Gpu, id: Texture_Id) {
	g.bindless.texture_ids[id] = false
}

// bind_globals binds the bindless set; once per command buffer, before
// drawing with any pipeline.
bind_globals :: proc(g: ^Gpu, cmd: vk.CommandBuffer) {
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g.pipeline_layout, 0, 1, &g.bindless.set, 0, nil)
}

// push_constants sends up to PUSH_CONSTANT_SIZE bytes to the current draw.
push_constants :: proc(
	g: ^Gpu,
	cmd: vk.CommandBuffer,
	data: ^$T,
) where size_of(T) <=
	PUSH_CONSTANT_SIZE {
	vk.CmdPushConstants(cmd, g.pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(T), data)
}
