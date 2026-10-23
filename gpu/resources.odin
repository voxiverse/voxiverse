package gpu

import "core:log"
import vk "vendor:vulkan"

// Buffers and images. One memory allocation per resource for now; few
// resources exist yet. A sub-allocator comes with the world renderer, which
// creates many.

Buffer :: struct {
	handle: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   int,
	mapped: [^]u8, // host-visible buffers stay mapped
}

Image :: struct {
	handle: vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
	format: vk.Format,
	width:  u32,
	height: u32,
}

// create_buffer makes a buffer; host_visible ones are mapped and coherent
// (written by the CPU each frame), others are device-local.
create_buffer :: proc(
	g: ^Gpu,
	size: int,
	usage: vk.BufferUsageFlags,
	host_visible: bool,
	name: string,
) -> (
	b: Buffer,
	ok: bool,
) {
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	check(vk.CreateBuffer(g.device, &info, nil, &b.handle)) or_return
	reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g.device, b.handle, &reqs)
	props: vk.MemoryPropertyFlags =
		{.HOST_VISIBLE, .HOST_COHERENT} if host_visible else {.DEVICE_LOCAL}
	if b.memory, ok = allocate(g, reqs, props); !ok {
		vk.DestroyBuffer(g.device, b.handle, nil)
		return {}, false
	}
	check(vk.BindBufferMemory(g.device, b.handle, b.memory, 0)) or_return
	if host_visible {
		mapped: rawptr
		check(vk.MapMemory(g.device, b.memory, 0, vk.DeviceSize(size), {}, &mapped)) or_return
		b.mapped = cast([^]u8)mapped
	}
	b.size = size
	set_name(g, .BUFFER, u64(b.handle), name)
	return b, true
}

destroy_buffer :: proc(g: ^Gpu, b: ^Buffer) {
	if b.handle != 0 {vk.DestroyBuffer(g.device, b.handle, nil)}
	if b.memory != 0 {vk.FreeMemory(g.device, b.memory, nil)} 	// also unmaps
	b^ = {}
}

// create_image makes a device-local 2D image with a view.
create_image :: proc(
	g: ^Gpu,
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	name: string,
) -> (
	img: Image,
	ok: bool,
) {
	info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	check(vk.CreateImage(g.device, &info, nil, &img.handle)) or_return
	reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g.device, img.handle, &reqs)
	if img.memory, ok = allocate(g, reqs, {.DEVICE_LOCAL}); !ok {
		vk.DestroyImage(g.device, img.handle, nil)
		return {}, false
	}
	check(vk.BindImageMemory(g.device, img.handle, img.memory, 0)) or_return
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img.handle,
		viewType = .D2,
		format = format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	check(vk.CreateImageView(g.device, &view_info, nil, &img.view)) or_return
	img.format, img.width, img.height = format, width, height
	set_name(g, .IMAGE, u64(img.handle), name)
	set_name(g, .IMAGE_VIEW, u64(img.view), name)
	return img, true
}

destroy_image :: proc(g: ^Gpu, img: ^Image) {
	if img.view != 0 {vk.DestroyImageView(g.device, img.view, nil)}
	if img.handle != 0 {vk.DestroyImage(g.device, img.handle, nil)}
	if img.memory != 0 {vk.FreeMemory(g.device, img.memory, nil)}
	img^ = {}
}

// copy_to_image records a copy of rows [y0, y1) from staging (tightly
// packed, starting at offset 0) into img, with the layout transitions around
// it: from `from` (UNDEFINED the first time, else SHADER_READ_ONLY_OPTIMAL)
// to SHADER_READ_ONLY_OPTIMAL for fragment shaders. Record it outside
// rendering. The barriers also order it after earlier frames' reads.
copy_to_image :: proc(
	cmd: vk.CommandBuffer,
	staging: Buffer,
	img: Image,
	y0, y1: u32,
	from: vk.ImageLayout,
) {
	range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}
	to_transfer := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.FRAGMENT_SHADER} if from != .UNDEFINED else {},
		srcAccessMask    = {.SHADER_SAMPLED_READ} if from != .UNDEFINED else {},
		dstStageMask     = {.COPY},
		dstAccessMask    = {.TRANSFER_WRITE},
		oldLayout        = from,
		newLayout        = .TRANSFER_DST_OPTIMAL,
		image            = img.handle,
		subresourceRange = range,
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_transfer,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)

	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageOffset = {0, i32(y0), 0},
		imageExtent = {img.width, y1 - y0, 1},
	}
	vk.CmdCopyBufferToImage(cmd, staging.handle, img.handle, .TRANSFER_DST_OPTIMAL, 1, &region)

	to_shader := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COPY},
		srcAccessMask    = {.TRANSFER_WRITE},
		dstStageMask     = {.FRAGMENT_SHADER},
		dstAccessMask    = {.SHADER_SAMPLED_READ},
		oldLayout        = .TRANSFER_DST_OPTIMAL,
		newLayout        = .SHADER_READ_ONLY_OPTIMAL,
		image            = img.handle,
		subresourceRange = range,
	}
	dep.pImageMemoryBarriers = &to_shader
	vk.CmdPipelineBarrier2(cmd, &dep)
}

@(private)
allocate :: proc(
	g: ^Gpu,
	reqs: vk.MemoryRequirements,
	props: vk.MemoryPropertyFlags,
) -> (
	mem: vk.DeviceMemory,
	ok: bool,
) {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g.physical, &mem_props)
	for i in 0 ..< mem_props.memoryTypeCount {
		if reqs.memoryTypeBits & (1 << i) == 0 {continue}
		if mem_props.memoryTypes[i].propertyFlags & props != props {continue}
		info := vk.MemoryAllocateInfo {
			sType           = .MEMORY_ALLOCATE_INFO,
			allocationSize  = reqs.size,
			memoryTypeIndex = i,
		}
		check(vk.AllocateMemory(g.device, &info, nil, &mem)) or_return
		return mem, true
	}
	log.errorf("gpu: no memory type with %v for %d bytes", props, reqs.size)
	return 0, false
}
