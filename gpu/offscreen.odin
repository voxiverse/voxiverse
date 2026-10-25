package gpu

import "core:log"
import vk "vendor:vulkan"

// Offscreen drawing (benchmarks, PLAN.md M19): with set_offscreen, every
// frame draws into an image of a fixed size (and its own depth buffer)
// instead of the swapchain image, and end_frame copies it onto that, scaled
// to the window texel for texel. So the work measured is the same whatever
// the window is: its size, fullscreen, what the window manager does. The
// copy is a GPU section of its own ("present copy"), left out of the frame's
// time in benchmark metrics.

Offscreen :: struct {
	size:  [2]u32, // {0, 0}: off (frames draw into the swapchain image)
	color: Image,
	depth: Image,
}

// set_offscreen makes frames draw into a width x height image from now on
// (call before the first frame). False (and off) if the GPU cannot copy
// it onto the window.
set_offscreen :: proc(g: ^Gpu, width, height: u32) -> bool {
	props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(g.physical, g.swapchain.format, &props)
	if props.optimalTilingFeatures & {.BLIT_SRC, .BLIT_DST} != {.BLIT_SRC, .BLIT_DST} {
		log.errorf(
			"gpu cannot draw offscreen: %v images cannot be blitted here",
			g.swapchain.format,
		)
		return false
	}
	o := &g.offscreen
	ok: bool
	o.color, ok = create_image(
		g,
		width,
		height,
		g.swapchain.format,
		{.COLOR_ATTACHMENT, .TRANSFER_SRC},
		"offscreen colour",
	)
	if !ok {return false}
	o.depth, ok = create_image(
		g,
		width,
		height,
		DEPTH_FORMAT,
		{.DEPTH_STENCIL_ATTACHMENT},
		"offscreen depth",
	)
	if !ok {
		destroy_image(g, &o.color)
		return false
	}
	o.size = {width, height}
	g.swapchain.stale = true // rebuilt with TRANSFER_DST images, for the copy
	log.infof("gpu drawing offscreen size=%dx%d", width, height)
	return true
}

@(private)
offscreen_destroy :: proc(g: ^Gpu) {
	destroy_image(g, &g.offscreen.color)
	destroy_image(g, &g.offscreen.depth)
	g.offscreen = {}
}

// offscreen_begin readies the offscreen image to draw on: after the last
// frame's copy has finished reading it (one image serves every frame).
@(private)
offscreen_begin :: proc(cmd: vk.CommandBuffer, image: vk.Image) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.BLIT, .COLOR_ATTACHMENT_OUTPUT},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .COLOR_ATTACHMENT_READ},
		oldLayout = .UNDEFINED,
		newLayout = .COLOR_ATTACHMENT_OPTIMAL,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency)
}

// offscreen_copy records the copy of the frame's image onto the swapchain
// image index, leaving that ready to draw on (COLOR_ATTACHMENT_OPTIMAL), as
// a frame drawn there directly would be.
@(private)
offscreen_copy :: proc(g: ^Gpu, f: ^Frame_Sync, frame: Frame) {
	sc := &g.swapchain
	target := sc.images[frame.image_index]
	timing_section_begin(g, &f.timing, frame.cmd, "present copy")
	range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}
	before := [2]vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstStageMask = {.BLIT},
			dstAccessMask = {.TRANSFER_READ},
			oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
			newLayout = .TRANSFER_SRC_OPTIMAL,
			image = frame.image,
			subresourceRange = range,
		},
		{
			sType            = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask     = {.COLOR_ATTACHMENT_OUTPUT, .BLIT}, // (the acquire semaphore's wait stages)
			dstStageMask     = {.BLIT},
			dstAccessMask    = {.TRANSFER_WRITE},
			oldLayout        = .UNDEFINED,
			newLayout        = .TRANSFER_DST_OPTIMAL,
			image            = target,
			subresourceRange = range,
		},
	}
	dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = len(before),
		pImageMemoryBarriers    = &before[0],
	}
	vk.CmdPipelineBarrier2(frame.cmd, &dependency)
	layers := vk.ImageSubresourceLayers {
		aspectMask = {.COLOR},
		layerCount = 1,
	}
	blit := vk.ImageBlit {
		srcSubresource = layers,
		srcOffsets     = {{}, {i32(frame.extent.width), i32(frame.extent.height), 1}},
		dstSubresource = layers,
		dstOffsets     = {{}, {i32(sc.extent.width), i32(sc.extent.height), 1}},
	}
	vk.CmdBlitImage(
		frame.cmd,
		frame.image,
		.TRANSFER_SRC_OPTIMAL,
		target,
		.TRANSFER_DST_OPTIMAL,
		1,
		&blit,
		.NEAREST,
	)
	after := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.BLIT},
		srcAccessMask    = {.TRANSFER_WRITE},
		dstStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask    = {.COLOR_ATTACHMENT_WRITE, .COLOR_ATTACHMENT_READ},
		oldLayout        = .TRANSFER_DST_OPTIMAL,
		newLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		image            = target,
		subresourceRange = range,
	}
	dependency = {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &after,
	}
	vk.CmdPipelineBarrier2(frame.cmd, &dependency)
	timing_section_end(g, &f.timing, frame.cmd)
}
