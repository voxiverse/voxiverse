package gpu

import "core:fmt"
import "core:log"
import vk "vendor:vulkan"

// choose_present_mode: FIFO for vsync (always available). Without:
// IMMEDIATE, what "vsync off" means in games (frames go out at once, so
// the frame rate is uncapped and the image may tear); else MAILBOX
// (uncapped, no tearing: the newest frame replaces a waiting one; some
// window systems offer only this); else FIFO after all.
@(private = "file")
choose_present_mode :: proc(g: ^Gpu, vsync: bool) -> vk.PresentModeKHR {
	if vsync {return .FIFO}
	modes := present_modes(g)
	for want in ([]vk.PresentModeKHR{.IMMEDIATE, .MAILBOX}) {
		for m in modes {if m == want {return m}}
	}
	return .FIFO
}

@(private = "file")
present_modes :: proc(g: ^Gpu) -> []vk.PresentModeKHR {
	count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical, g.surface, &count, nil)
	modes := make([]vk.PresentModeKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical, g.surface, &count, raw_data(modes))
	return modes[:count]
}

// recreate_swapchain (re)builds the swapchain at width×height. Only the
// swapchain, its views and its per-image semaphores are touched; pipelines
// and everything else survive a resize.
@(private)
recreate_swapchain :: proc(g: ^Gpu, width, height: i32) -> bool {
	vk.DeviceWaitIdle(g.device) // the old images may still be in use
	sc := &g.swapchain

	caps: vk.SurfaceCapabilitiesKHR
	check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.physical, g.surface, &caps)) or_return
	extent := caps.currentExtent
	if extent.width == max(u32) {
		// The window system lets us choose; use the window's size.
		extent = {
			clamp(u32(width), caps.minImageExtent.width, caps.maxImageExtent.width),
			clamp(u32(height), caps.minImageExtent.height, caps.maxImageExtent.height),
		}
	}
	if extent.width == 0 || extent.height == 0 {return false} 	// minimized

	mode := choose_present_mode(g, sc.vsync)
	image_count := caps.minImageCount + 1
	// MAILBOX runs uncapped only if, besides the image on screen and the one
	// waiting to replace it, every frame in flight has an image of its own;
	// with fewer, acquiring waits for the display (e.g. 3 images: exactly
	// twice the refresh rate).
	if mode == .MAILBOX {image_count = max(image_count, 2 + FRAMES_IN_FLIGHT)}
	if caps.maxImageCount > 0 {image_count = min(image_count, caps.maxImageCount)}
	image_count = min(image_count, MAX_SWAPCHAIN_IMAGES)

	old := sc.handle
	usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT, .TRANSFER_SRC}
	if g.offscreen.size != {} {usage += {.TRANSFER_DST}}
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = g.surface,
		minImageCount    = image_count,
		imageFormat      = sc.format,
		imageColorSpace  = sc.color_space,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = usage, // TRANSFER_SRC: screenshots; TRANSFER_DST: the offscreen copy
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	handle: vk.SwapchainKHR
	if result := vk.CreateSwapchainKHR(g.device, &info, nil, &handle); result != .SUCCESS {
		log.errorf("gpu vkCreateSwapchainKHR failed: %v", result)
		return false
	}
	destroy_swapchain(g, sc) // destroys old (retired by oldSwapchain above)
	sc.handle = handle
	if info.presentMode != sc.present_mode || old == 0 {
		log.infof(
			"gpu present mode=%v vsync=%v available=%v",
			info.presentMode,
			sc.vsync,
			present_modes(g),
		)
	}
	sc.present_mode = info.presentMode
	sc.extent = extent

	check(vk.GetSwapchainImagesKHR(g.device, handle, &sc.count, nil)) or_return
	sc.count = min(sc.count, MAX_SWAPCHAIN_IMAGES)
	check(vk.GetSwapchainImagesKHR(g.device, handle, &sc.count, &sc.images[0])) or_return
	for i in 0 ..< sc.count {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = sc.images[i],
			viewType = .D2,
			format = sc.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		check(vk.CreateImageView(g.device, &view_info, nil, &sc.views[i])) or_return
		semaphore_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		check(vk.CreateSemaphore(g.device, &semaphore_info, nil, &sc.render_finished[i])) or_return
		set_name(g, .IMAGE, u64(sc.images[i]), fmt.tprintf("swapchain image %d", i))
		set_name(g, .IMAGE_VIEW, u64(sc.views[i]), fmt.tprintf("swapchain image %d view", i))
		set_name(
			g,
			.SEMAPHORE,
			u64(sc.render_finished[i]),
			fmt.tprintf("swapchain image %d rendered", i),
		)
	}
	set_name(g, .SWAPCHAIN_KHR, u64(handle), "swapchain")
	ok: bool
	sc.depth, ok = create_image(
		g,
		extent.width,
		extent.height,
		DEPTH_FORMAT,
		{.DEPTH_STENCIL_ATTACHMENT},
		"depth",
	)
	if !ok {return false}
	log.infof(
		"gpu swapchain size=%dx%d images=%d format=%v",
		extent.width,
		extent.height,
		sc.count,
		sc.format,
	)
	return true
}

@(private)
destroy_swapchain :: proc(g: ^Gpu, sc: ^Swapchain) {
	for i in 0 ..< sc.count {
		if sc.views[i] != 0 {vk.DestroyImageView(g.device, sc.views[i], nil)}
		if sc.render_finished[i] != 0 {vk.DestroySemaphore(g.device, sc.render_finished[i], nil)}
	}
	if sc.handle != 0 {vk.DestroySwapchainKHR(g.device, sc.handle, nil)}
	destroy_image(g, &sc.depth)
	// Kept across rebuilds: the format (chosen once at init_device) and the
	// vsync wanted, with the mode it gave.
	keep := Swapchain {
		format       = sc.format,
		color_space  = sc.color_space,
		vsync        = sc.vsync,
		present_mode = sc.present_mode,
	}
	sc^ = keep
}

// choose_surface_format prefers an 8-bit sRGB format, so shaders write
// linear colour and the hardware encodes it.
@(private)
choose_surface_format :: proc(g: ^Gpu) {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical, g.surface, &count, nil)
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical, g.surface, &count, raw_data(formats))
	chosen := formats[0]
	for f in formats {
		if (f.format == .B8G8R8A8_SRGB || f.format == .R8G8B8A8_SRGB) &&
		   f.colorSpace == .SRGB_NONLINEAR {
			chosen = f
			break
		}
	}
	g.swapchain.format, g.swapchain.color_space = chosen.format, chosen.colorSpace
}
