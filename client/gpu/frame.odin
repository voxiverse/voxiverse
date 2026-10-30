package gpu

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

import "../../base"

// Frame pacing. Per frame in flight: a command pool + buffer, a fence and an
// "image acquired" semaphore. Per swapchain image: a "rendering finished"
// semaphore, since presentation of an image may still be waiting on it when
// the next frame in flight starts.

MAX_SWAPCHAIN_IMAGES :: 8

Swapchain :: struct {
	handle:          vk.SwapchainKHR,
	format:          vk.Format,
	color_space:     vk.ColorSpaceKHR,
	extent:          vk.Extent2D,
	count:           u32,
	images:          [MAX_SWAPCHAIN_IMAGES]vk.Image,
	views:           [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
	render_finished: [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	depth:           Image, // shared by all frames: rendering is ordered on the queue
	stale:           bool, // recreate before the next frame (suboptimal / out of date)
	vsync:           bool, // wanted: wait for the display (else as fast as possible)
	present_mode:    vk.PresentModeKHR, // what we got
}

// set_vsync chooses between waiting for the display (no tearing, frame rate
// capped at its refresh rate) and drawing as fast as possible; the
// swapchain is rebuilt before the next frame.
set_vsync :: proc(g: ^Gpu, on: bool) {
	if g.swapchain.vsync == on && g.swapchain.handle != 0 {return}
	g.swapchain.vsync = on
	g.swapchain.stale = true
}

Frame_Sync :: struct {
	pool:           vk.CommandPool,
	cmd:            vk.CommandBuffer,
	fence:          vk.Fence,
	image_acquired: vk.Semaphore,
	timing:         Frame_Timing,
	screenshot:     Screenshot,
}

// Frame is what a caller records into between begin_frame and end_frame.
Frame :: struct {
	cmd:         vk.CommandBuffer,
	image:       vk.Image,
	view:        vk.ImageView,
	format:      vk.Format,
	extent:      vk.Extent2D,
	image_index: u32,
	depth:       Image,
}

// begin_frame waits for this frame slot's previous work, acquires a swapchain
// image sized width×height and starts recording. ok is false when there is
// nothing to draw into this time (minimized, or the swapchain had to be
// rebuilt); just try again next frame.
begin_frame :: proc(g: ^Gpu, width, height: i32) -> (frame: Frame, ok: bool) {
	if width <= 0 || height <= 0 {return}
	sc := &g.swapchain
	if sc.handle == 0 || sc.stale || sc.extent != {u32(width), u32(height)} {
		base.profile_scope("recreate swapchain")
		if !recreate_swapchain(g, width, height) {return}
	}

	f := &g.frames[g.frame_index]
	{
		// The GPU still drawing this slot's last frame (FRAMES_IN_FLIGHT ago): GPU-bound.
		base.profile_scope("wait for frame fence")
		check(vk.WaitForFences(g.device, 1, &f.fence, true, max(u64))) or_return
	}

	index: u32
	base.profile_begin("acquire image") // (ended right after the call)
	result := vk.AcquireNextImageKHR(g.device, sc.handle, max(u64), f.image_acquired, 0, &index)
	base.profile_end()
	#partial switch result {
	case .SUCCESS:
	case .SUBOPTIMAL_KHR:
		sc.stale = true // still usable this frame (the semaphore is signalled)
	case .ERROR_OUT_OF_DATE_KHR:
		sc.stale = true
		return
	case:
		log.errorf("gpu vkAcquireNextImageKHR failed: %v", result)
		return
	}
	// Only now: resetting before a failed acquire would leave nothing to
	// signal the fence and deadlock the next wait.
	{
		base.profile_scope("reset and begin commands")
		check(vk.ResetFences(g.device, 1, &f.fence)) or_return
		check(vk.ResetCommandPool(g.device, f.pool, {})) or_return
		begin := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		check(vk.BeginCommandBuffer(f.cmd, &begin)) or_return
	}
	timing_frame_begin(g, &f.timing, f.cmd)

	frame = Frame {
		cmd         = f.cmd,
		image       = sc.images[index],
		view        = sc.views[index],
		format      = sc.format,
		extent      = sc.extent,
		image_index = index,
		depth       = sc.depth,
	}
	if o := &g.offscreen; o.size != {} {
		// Drawn at a fixed size, copied onto the swapchain image at the end.
		frame.image, frame.view, frame.depth = o.color.handle, o.color.view, o.depth
		frame.extent = {o.size.x, o.size.y}
	}
	if g.offscreen.size != {} {
		offscreen_begin(f.cmd, frame.image) // (after the last frame's copy read it)
	} else {
		image_barrier(f.cmd, frame.image, .UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL)
	}
	// The depth image is cleared every frame; wait only for the previous
	// frame's depth tests to finish with it.
	depth_barrier := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		srcAccessMask    = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		dstStageMask     = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		dstAccessMask    = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
		oldLayout        = .UNDEFINED,
		newLayout        = .DEPTH_ATTACHMENT_OPTIMAL,
		image            = frame.depth.handle,
		subresourceRange = whole_image(frame.depth),
	}
	dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &depth_barrier,
	}
	vk.CmdPipelineBarrier2(f.cmd, &dependency)
	return frame, true
}

// end_frame finishes recording, submits and presents.
end_frame :: proc(g: ^Gpu, frame: Frame) {
	f := &g.frames[g.frame_index]
	sc := &g.swapchain
	shown := frame
	if g.offscreen.size != {} {
		offscreen_copy(g, f, frame)
		shown.image, shown.view = sc.images[frame.image_index], sc.views[frame.image_index]
		shown.extent = sc.extent
	}
	screenshot_record(g, f, shown) // also transitions the image for presenting
	timing_frame_end(g, &f.timing, frame.cmd)
	if !check(vk.EndCommandBuffer(frame.cmd)) {return}

	wait := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = f.image_acquired,
		// Drawing waits for the image; so does the offscreen copy onto it.
		stageMask = {.COLOR_ATTACHMENT_OUTPUT, .BLIT} if g.offscreen.size != {} else {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = sc.render_finished[frame.image_index],
		stageMask = {.ALL_COMMANDS},
	}
	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = frame.cmd,
	}
	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal,
	}
	{
		base.profile_scope("queue submit")
		if !check(vk.QueueSubmit2(g.queue, 1, &submit, f.fence)) {return}
	}

	index := frame.image_index
	present := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &sc.render_finished[index],
		swapchainCount     = 1,
		pSwapchains        = &sc.handle,
		pImageIndices      = &index,
	}
	base.profile_begin("queue present") // (ended right after the call: vsync may wait here)
	presented := vk.QueuePresentKHR(g.queue, &present)
	base.profile_end()
	#partial switch presented {
	case .SUCCESS:
	case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR:
		sc.stale = true
	case:
		log.errorf("gpu vkQueuePresentKHR failed: %v", presented)
	}
	g.frame_index = (g.frame_index + 1) % FRAMES_IN_FLIGHT
}

// begin_rendering starts dynamic rendering into the frame's image, cleared
// to clear_color, with viewport and scissor covering it, and the depth
// buffer cleared to 0 (the far plane in reverse Z).
begin_rendering :: proc(frame: Frame, clear_color: [4]f32) {
	attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = frame.view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = {color = {float32 = clear_color}},
	}
	depth := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = frame.depth.view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 0}},
	}
	area := vk.Rect2D {
		extent = frame.extent,
	}
	info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = area,
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &attachment,
		pDepthAttachment     = &depth,
	}
	vk.CmdBeginRendering(frame.cmd, &info)
	viewport := vk.Viewport {
		width    = f32(frame.extent.width),
		height   = f32(frame.extent.height),
		maxDepth = 1,
	}
	vk.CmdSetViewport(frame.cmd, 0, 1, &viewport)
	vk.CmdSetScissor(frame.cmd, 0, 1, &area)
}

end_rendering :: proc(frame: Frame) {
	vk.CmdEndRendering(frame.cmd)
}

@(private)
create_frame_sync :: proc(g: ^Gpu, f: ^Frame_Sync, index: int) -> bool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.TRANSIENT},
		queueFamilyIndex = g.queue_family,
	}
	check(vk.CreateCommandPool(g.device, &pool_info, nil, &f.pool)) or_return
	alloc := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = f.pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	check(vk.AllocateCommandBuffers(g.device, &alloc, &f.cmd)) or_return
	// Signalled, so the first wait on each frame slot returns immediately.
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	check(vk.CreateFence(g.device, &fence_info, nil, &f.fence)) or_return
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	check(vk.CreateSemaphore(g.device, &semaphore_info, nil, &f.image_acquired)) or_return

	set_name(g, .COMMAND_POOL, u64(f.pool), fmt.tprintf("frame %d command pool", index))
	set_name(g, .COMMAND_BUFFER, u64(uintptr(f.cmd)), fmt.tprintf("frame %d commands", index))
	set_name(g, .FENCE, u64(f.fence), fmt.tprintf("frame %d fence", index))
	set_name(g, .SEMAPHORE, u64(f.image_acquired), fmt.tprintf("frame %d image acquired", index))
	return timing_init(g, &f.timing, index)
}

@(private)
destroy_frame_sync :: proc(g: ^Gpu, f: ^Frame_Sync) {
	timing_destroy(g, &f.timing)
	destroy_buffer(g, &f.screenshot.buffer)
	if f.image_acquired != 0 {vk.DestroySemaphore(g.device, f.image_acquired, nil)}
	if f.fence != 0 {vk.DestroyFence(g.device, f.fence, nil)}
	if f.pool != 0 {vk.DestroyCommandPool(g.device, f.pool, nil)} 	// frees cmd too
	f^ = {}
}

// image_barrier transitions a whole colour image between the layouts the
// frame uses (UNDEFINED -> attachment -> present).
image_barrier :: proc(cmd: vk.CommandBuffer, image: vk.Image, from, to: vk.ImageLayout) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE} if from != .UNDEFINED else {},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT} if to == .COLOR_ATTACHMENT_OPTIMAL else {.BOTTOM_OF_PIPE},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE, .COLOR_ATTACHMENT_READ} if to == .COLOR_ATTACHMENT_OPTIMAL else {},
		oldLayout = from,
		newLayout = to,
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

// check logs a failed Vulkan call; use with or_return.
check :: proc(result: vk.Result, loc := #caller_location) -> bool {
	if result == .SUCCESS {return true}
	log.errorf("gpu Vulkan call failed: %v", result, location = loc)
	return false
}

// frame_slot is the frame-in-flight index of the frame being recorded
// (between begin_frame and end_frame), for per-slot resources.
frame_slot :: proc(g: ^Gpu) -> int {
	return g.frame_index
}

// clear_depth clears the depth buffer to the far plane (0 in reverse Z) inside
// the frame's rendering: what is drawn next is never hidden by what was drawn
// before (the first-person view model).
clear_depth :: proc(frame: Frame) {
	attachment := vk.ClearAttachment {
		aspectMask = {.DEPTH},
		clearValue = {depthStencil = {depth = 0}},
	}
	rect := vk.ClearRect {
		rect = {extent = frame.extent},
		layerCount = 1,
	}
	vk.CmdClearAttachments(frame.cmd, 1, &attachment, 1, &rect)
}
