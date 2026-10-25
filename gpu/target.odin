package gpu

import vk "vendor:vulkan"

// Render targets: a colour image (in the swapchain's format, so the world's
// pipelines draw into it unchanged) and a depth buffer of their own, drawn
// into outside the frame's main rendering and then sampled like any texture
// by id (the UI draws the player's preview this way).
//
//	target_begin(g, cmd, &t, clear)  -> a Frame to draw into; before the frame's begin_rendering
//	... draws using the frame ...
//	target_end(&t, frame)
//
// One image serves every frame slot: the barriers order each use after the
// last frame's sampling of it.

Target :: struct {
	color: Image,
	depth: Image,
	id:    Texture_Id, // to sample it
	used:  bool, // drawn into before (so its layout is known)
}

target_create :: proc(g: ^Gpu, width, height: u32, name: string) -> (t: Target, ok: bool) {
	t.color = create_image(
		g,
		width,
		height,
		g.swapchain.format,
		{.COLOR_ATTACHMENT, .SAMPLED},
		name,
	) or_return
	t.depth, ok = create_image(g, width, height, DEPTH_FORMAT, {.DEPTH_STENCIL_ATTACHMENT}, name)
	if !ok {
		destroy_image(g, &t.color)
		return {}, false
	}
	t.id, ok = register_texture(g, t.color.view)
	if !ok {
		destroy_image(g, &t.color)
		destroy_image(g, &t.depth)
	}
	return t, ok
}

// target_destroy: call after wait_idle.
target_destroy :: proc(g: ^Gpu, t: ^Target) {
	if t.color.handle == 0 {return}
	unregister_texture(g, t.id)
	destroy_image(g, &t.color)
	destroy_image(g, &t.depth)
	t^ = {}
}

// target_begin starts rendering into t, cleared to clear_color (and depth
// to the far plane); the returned frame is for the world's draw procs.
target_begin :: proc(g: ^Gpu, cmd: vk.CommandBuffer, t: ^Target, clear_color: [4]f32) -> Frame {
	barriers := [2]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.FRAGMENT_SHADER} if t.used else {},
			srcAccessMask = {.SHADER_SAMPLED_READ} if t.used else {},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
			oldLayout = .SHADER_READ_ONLY_OPTIMAL if t.used else .UNDEFINED,
			newLayout = .COLOR_ATTACHMENT_OPTIMAL,
			image = t.color.handle,
			subresourceRange = whole_image(t.color),
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			image = t.depth.handle,
			subresourceRange = whole_image(t.depth),
		},
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = len(barriers),
		pImageMemoryBarriers    = &barriers[0],
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
	t.used = true
	frame := Frame {
		cmd    = cmd,
		view   = t.color.view,
		format = t.color.format,
		extent = {t.color.width, t.color.height},
		depth  = t.depth,
	}
	begin_rendering(frame, clear_color)
	return frame
}

// target_end finishes the rendering and makes t sampleable.
target_end :: proc(t: ^Target, frame: Frame) {
	end_rendering(frame)
	to_shader := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask    = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask     = {.FRAGMENT_SHADER},
		dstAccessMask    = {.SHADER_SAMPLED_READ},
		oldLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout        = .SHADER_READ_ONLY_OPTIMAL,
		image            = t.color.handle,
		subresourceRange = whole_image(t.color),
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_shader,
	}
	vk.CmdPipelineBarrier2(frame.cmd, &dep)
}
