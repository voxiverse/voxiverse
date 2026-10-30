package gpu

import "core:log"
import vk "vendor:vulkan"

import "../../base"

// Graphics pipelines for dynamic rendering. Viewport and scissor are dynamic
// state, so pipelines don't depend on the window size and survive resizes.
// All pipelines use the shared layout (bindless set + push constants).

Pipeline :: struct {
	handle: vk.Pipeline,
}

Vertex_Attribute :: struct {
	format: vk.Format,
	offset: u32,
}

Pipeline_Desc :: struct {
	name:                string, // for validation messages and captures
	vertex_spirv:        []byte,
	fragment_spirv:      []byte,
	color_format:        vk.Format,
	// One interleaved vertex buffer at binding 0; stride 0 = no vertex input
	// (vertices generated in the shader).
	vertex_stride:       u32,
	attributes:          []Vertex_Attribute, // locations 0, 1, ...
	// One per-instance buffer at binding 1 (stride 0 = none): its
	// attributes take the locations after the vertex ones. An indirect
	// command's firstInstance picks the record.
	instance_stride:     u32,
	instance_attributes: []Vertex_Attribute,
	alpha_blend:         bool, // standard "over" blending
	depth:               Depth_Mode,
	cull_back:           bool, // skip triangles wound clockwise on screen
	lines:               bool, // line list instead of triangle list
}

// Depth_Mode: reverse Z (nearer = greater) when tested.
Depth_Mode :: enum u8 {
	Off, // ignores depth (UI)
	Test_Write, // opaque geometry
	Test, // overlays that hide behind geometry without occluding (debug lines)
	Background, // drawn after the world, at the far plane (0), where nothing is yet
}

create_pipeline :: proc(g: ^Gpu, desc: Pipeline_Desc) -> (p: Pipeline, ok: bool) {
	vert := create_shader_module(g, desc.vertex_spirv) or_return
	defer vk.DestroyShaderModule(g.device, vert, nil)
	frag := create_shader_module(g, desc.fragment_spirv) or_return
	defer vk.DestroyShaderModule(g.device, frag, nil)

	stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag,
			pName = "main",
		},
	}
	bindings := make([dynamic]vk.VertexInputBindingDescription, context.temp_allocator)
	attributes := make([dynamic]vk.VertexInputAttributeDescription, context.temp_allocator)
	if desc.vertex_stride > 0 {
		append(&bindings, vk.VertexInputBindingDescription{0, desc.vertex_stride, .VERTEX})
		for a in desc.attributes {
			append(
				&attributes,
				vk.VertexInputAttributeDescription {
					location = u32(len(attributes)),
					binding = 0,
					format = a.format,
					offset = a.offset,
				},
			)
		}
	}
	if desc.instance_stride > 0 {
		append(&bindings, vk.VertexInputBindingDescription{1, desc.instance_stride, .INSTANCE})
		for a in desc.instance_attributes {
			append(
				&attributes,
				vk.VertexInputAttributeDescription {
					location = u32(len(attributes)),
					binding = 1,
					format = a.format,
					offset = a.offset,
				},
			)
		}
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = u32(len(bindings)),
		pVertexBindingDescriptions      = raw_data(bindings),
		vertexAttributeDescriptionCount = u32(len(attributes)),
		pVertexAttributeDescriptions    = raw_data(attributes),
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .LINE_LIST if desc.lines else .TRIANGLE_LIST,
	}
	viewport := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {.BACK} if desc.cull_back else {},
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	if desc.alpha_blend {
		blend_attachment.blendEnable = true
		blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		blend_attachment.colorBlendOp = .ADD
		blend_attachment.srcAlphaBlendFactor = .ONE
		blend_attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
		blend_attachment.alphaBlendOp = .ADD
	}
	depth := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = b32(desc.depth != .Off),
		depthWriteEnable = b32(desc.depth == .Test_Write),
		depthCompareOp   = .GREATER_OR_EQUAL if desc.depth == .Background else .GREATER,
	}
	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}
	color_format := desc.color_format
	rendering := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
		depthAttachmentFormat   = DEPTH_FORMAT, // every rendering has one (begin_rendering)
	}
	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering,
		stageCount          = len(stages),
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pDepthStencilState  = &depth,
		pColorBlendState    = &blend,
		pDynamicState       = &dynamic_state,
		layout              = g.pipeline_layout,
	}
	// What the driver reports about the build: its time, and whether the cache had it.
	feedback: vk.PipelineCreationFeedback
	feedback_info := vk.PipelineCreationFeedbackCreateInfo {
		sType                     = .PIPELINE_CREATION_FEEDBACK_CREATE_INFO,
		pPipelineCreationFeedback = &feedback,
	}
	feedback_info.pNext = info.pNext // (the chain before it: the attachments' formats)
	info.pNext = &feedback_info
	{
		base.profile_begin("create pipeline", desc.name)
		defer base.profile_end()
		check(
			vk.CreateGraphicsPipelines(g.device, g.pipeline_cache, 1, &info, nil, &p.handle),
		) or_return
	}
	set_name(g, .PIPELINE, u64(p.handle), desc.name)
	g.pipelines_built += 1
	if .VALID in feedback.flags {
		ms := f64(feedback.duration) / 1e6
		hit := .APPLICATION_PIPELINE_CACHE_HIT in feedback.flags
		g.pipeline_ms += ms
		if hit {g.pipelines_cached += 1}
		log.debugf("gpu pipeline built name=%s ms=%.2f cache_hit=%v", desc.name, ms, hit)
	}
	return p, true
}

// replace_pipeline rebuilds p from desc (shader hot reload). On failure p
// is unchanged; on success the old pipeline is destroyed once the GPU is
// idle (a reload is rare and interactive, so the wait is fine).
replace_pipeline :: proc(g: ^Gpu, p: ^Pipeline, desc: Pipeline_Desc) -> bool {
	fresh := create_pipeline(g, desc) or_return
	wait_idle(g)
	destroy_pipeline(g, p)
	p^ = fresh
	return true
}

destroy_pipeline :: proc(g: ^Gpu, p: ^Pipeline) {
	if p.handle != 0 {vk.DestroyPipeline(g.device, p.handle, nil)}
	p^ = {}
}

@(private)
create_shader_module :: proc(g: ^Gpu, spirv: []byte) -> (module: vk.ShaderModule, ok: bool) {
	if len(spirv) == 0 || len(spirv) % 4 != 0 {
		log.errorf("gpu invalid SPIR-V (%d bytes)", len(spirv))
		return 0, false
	}
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spirv),
		pCode    = cast(^u32)raw_data(spirv),
	}
	check(vk.CreateShaderModule(g.device, &info, nil, &module)) or_return
	return module, true
}
