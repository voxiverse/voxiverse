package gpu

import "core:mem"
import vk "vendor:vulkan"

// Screenshots: request_screenshot makes the next presented frame be copied
// into a readback buffer; once the GPU has finished that frame,
// screenshot_take returns its pixels as RGBA8 (sRGB, as displayed). No
// stalls: the copy rides along with the frame.
//
//	gpu.request_screenshot(&g)
//	... every frame (and after wait_idle at exit):
//	if pixels, w, h, ok := gpu.screenshot_take(&g, allocator); ok {...}

@(private)
Screenshot :: struct {
	buffer:        Buffer,
	pending:       bool, // copy recorded, not yet read
	width, height: u32,
	format:        vk.Format,
}

request_screenshot :: proc(g: ^Gpu) {
	g.screenshot_requested = true
}

// screenshot_take returns a finished screenshot, if one is ready.
screenshot_take :: proc(
	g: ^Gpu,
	allocator := context.allocator,
) -> (
	pixels: []u8,
	width, height: int,
	ok: bool,
) {
	for &f in g.frames {
		s := &f.screenshot
		if !s.pending {continue}
		if vk.GetFenceStatus(g.device, f.fence) != .SUCCESS {continue} 	// still in flight
		s.pending = false
		n := int(s.width * s.height * 4)
		err: mem.Allocator_Error
		if pixels, err = make([]u8, n, allocator); err != nil {return}
		copy(pixels, s.buffer.mapped[:n])
		if s.format == .B8G8R8A8_SRGB || s.format == .B8G8R8A8_UNORM {
			for i := 0; i < n; i += 4 {pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]}
		}
		for i := 3; i < n; i += 4 {pixels[i] = 255} 	// what you see is opaque
		return pixels, int(s.width), int(s.height), true
	}
	return
}

// screenshot_record copies what was drawn if a screenshot was requested and
// leaves the shown image ready to present; otherwise just transitions it.
// Replaces the frame's final barrier. Drawn offscreen (set_offscreen), the
// copy is of the offscreen image at its own size (left TRANSFER_SRC_OPTIMAL by
// offscreen_copy), not of the window's scaled copy of it.
@(private)
screenshot_record :: proc(g: ^Gpu, f: ^Frame_Sync, shown: Frame, drawn: Frame) {
	if !g.screenshot_requested || f.screenshot.pending {
		image_barrier(shown.cmd, shown.image, .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)
		return
	}
	offscreen := g.offscreen.size != {}
	frame := drawn if offscreen else shown
	s := &f.screenshot
	size := int(frame.extent.width * frame.extent.height * 4)
	if s.buffer.size < size {
		destroy_buffer(g, &s.buffer)
		ok: bool
		if s.buffer, ok = create_buffer(g, size, {.TRANSFER_DST}, true, "screenshot readback");
		   !ok {
			image_barrier(shown.cmd, shown.image, .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)
			return
		}
	}
	range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}
	to_copy := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask    = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask     = {.COPY},
		dstAccessMask    = {.TRANSFER_READ},
		oldLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout        = .TRANSFER_SRC_OPTIMAL,
		image            = frame.image,
		subresourceRange = range,
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_copy,
	}
	if !offscreen {vk.CmdPipelineBarrier2(frame.cmd, &dep)} 	// (offscreen: the blit's read layout already)
	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = {frame.extent.width, frame.extent.height, 1},
	}
	vk.CmdCopyImageToBuffer(
		frame.cmd,
		frame.image,
		.TRANSFER_SRC_OPTIMAL,
		s.buffer.handle,
		1,
		&region,
	)
	to_present := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COPY},
		srcAccessMask    = {.TRANSFER_READ},
		dstStageMask     = {.BOTTOM_OF_PIPE},
		oldLayout        = .TRANSFER_SRC_OPTIMAL,
		newLayout        = .PRESENT_SRC_KHR,
		image            = frame.image,
		subresourceRange = range,
	}
	if offscreen {
		// The window's image was not copied from: it goes from drawing to presenting.
		to_present.srcStageMask = {.COLOR_ATTACHMENT_OUTPUT}
		to_present.srcAccessMask = {.COLOR_ATTACHMENT_WRITE}
		to_present.oldLayout = .COLOR_ATTACHMENT_OPTIMAL
		to_present.image = shown.image
	}
	// The host reads the buffer after the frame's fence.
	host := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.HOST},
		dstAccessMask = {.HOST_READ},
	}
	dep.pImageMemoryBarriers = &to_present
	dep.memoryBarrierCount = 1
	dep.pMemoryBarriers = &host
	vk.CmdPipelineBarrier2(frame.cmd, &dep)
	s.pending = true
	s.width, s.height, s.format = frame.extent.width, frame.extent.height, frame.format
	g.screenshot_requested = false
}
