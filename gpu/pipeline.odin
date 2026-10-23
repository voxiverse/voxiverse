package gpu

import "core:log"
import vk "vendor:vulkan"

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
	name:           string, // for validation messages and captures
	vertex_spirv:   []byte,
	fragment_spirv: []byte,
	color_format:   vk.Format,
	// One interleaved vertex buffer at binding 0; stride 0 = no vertex input
	// (vertices generated in the shader).
	vertex_stride:  u32,
	attributes:     []Vertex_Attribute, // locations 0, 1, ...
	alpha_blend:    bool, // standard "over" blending
	// Depth test and write with reverse Z (nearer = greater). Off: the
	// pipeline ignores depth (UI).
	depth_test:     bool,
	cull_back:      bool, // skip triangles wound clockwise on screen
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
	binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = desc.vertex_stride,
		inputRate = .VERTEX,
	}
	attributes := make(
		[]vk.VertexInputAttributeDescription,
		len(desc.attributes),
		context.temp_allocator,
	)
	for a, i in desc.attributes {
		attributes[i] = {
			location = u32(i),
			binding  = 0,
			format   = a.format,
			offset   = a.offset,
		}
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	if desc.vertex_stride > 0 {
		vertex_input.vertexBindingDescriptionCount = 1
		vertex_input.pVertexBindingDescriptions = &binding
		vertex_input.vertexAttributeDescriptionCount = u32(len(attributes))
		vertex_input.pVertexAttributeDescriptions = raw_data(attributes)
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
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
		depthTestEnable  = b32(desc.depth_test),
		depthWriteEnable = b32(desc.depth_test),
		depthCompareOp   = .GREATER,
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
	check(vk.CreateGraphicsPipelines(g.device, 0, 1, &info, nil, &p.handle)) or_return
	set_name(g, .PIPELINE, u64(p.handle), desc.name)
	return p, true
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
