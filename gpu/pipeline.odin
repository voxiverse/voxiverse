package gpu

import "core:log"
import vk "vendor:vulkan"

// Graphics pipelines for dynamic rendering. Viewport and scissor are dynamic
// state, so pipelines don't depend on the window size and survive resizes.

Pipeline :: struct {
	handle: vk.Pipeline,
	layout: vk.PipelineLayout,
}

Pipeline_Desc :: struct {
	name:           string, // for validation messages and captures
	vertex_spirv:   []byte,
	fragment_spirv: []byte,
	color_format:   vk.Format,
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
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
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
		cullMode    = {},
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
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	check(vk.CreatePipelineLayout(g.device, &layout_info, nil, &p.layout)) or_return

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
		pColorBlendState    = &blend,
		pDynamicState       = &dynamic_state,
		layout              = p.layout,
	}
	if !check(vk.CreateGraphicsPipelines(g.device, 0, 1, &info, nil, &p.handle)) {
		vk.DestroyPipelineLayout(g.device, p.layout, nil)
		return {}, false
	}
	set_name(g, .PIPELINE, u64(p.handle), desc.name)
	set_name(g, .PIPELINE_LAYOUT, u64(p.layout), desc.name)
	return p, true
}

destroy_pipeline :: proc(g: ^Gpu, p: ^Pipeline) {
	if p.handle != 0 {vk.DestroyPipeline(g.device, p.handle, nil)}
	if p.layout != 0 {vk.DestroyPipelineLayout(g.device, p.layout, nil)}
	p^ = {}
}

@(private)
create_shader_module :: proc(g: ^Gpu, spirv: []byte) -> (module: vk.ShaderModule, ok: bool) {
	if len(spirv) == 0 || len(spirv) % 4 != 0 {
		log.errorf("gpu: invalid SPIR-V (%d bytes)", len(spirv))
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
