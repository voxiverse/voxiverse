package gpu

import "core:log"
import vk "vendor:vulkan"

// Buffers and images, one memory allocation each: there are few. What
// needs many small pieces sub-allocates one big buffer instead (the world
// pass's vertices: common/base/range_alloc.odin).

Buffer :: struct {
	handle:      vk.Buffer,
	memory:      vk.DeviceMemory,
	size:        int,
	mapped:      [^]u8, // host-visible buffers stay mapped
	memory_size: int, // what its memory took (Gpu.memory_bytes)
}

Image :: struct {
	handle:      vk.Image,
	memory:      vk.DeviceMemory,
	view:        vk.ImageView,
	format:      vk.Format,
	width:       u32,
	height:      u32,
	mips:        u32,
	layers:      u32,
	memory_size: int, // what its memory took (Gpu.memory_bytes)
}

// DEPTH_FORMAT: 32-bit float depth, supported everywhere. The world renders
// with reverse Z (near = 1, far = 0), which spreads float precision evenly
// over distance.
DEPTH_FORMAT :: vk.Format.D32_SFLOAT

// buffer_address is where shaders find b (GL_EXT_buffer_reference); b needs
// SHADER_DEVICE_ADDRESS usage.
buffer_address :: proc(g: ^Gpu, b: Buffer) -> u64 {
	info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = b.handle,
	}
	return u64(vk.GetBufferDeviceAddress(g.device, &info))
}

// create_buffer makes a buffer; host_visible ones are mapped and coherent
// (written by the CPU each frame), others are device-local. With
// SHADER_DEVICE_ADDRESS usage, shaders can read it through buffer_address.
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
	defer if !ok {destroy_buffer(g, &b)} 	// whatever was made before a failure
	reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g.device, b.handle, &reqs)
	props: vk.MemoryPropertyFlags =
		{.HOST_VISIBLE, .HOST_COHERENT} if host_visible else {.DEVICE_LOCAL}
	b.memory = allocate(g, reqs, props, .SHADER_DEVICE_ADDRESS in usage) or_return
	b.memory_size = int(reqs.size)
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
	g.memory_bytes -= b.memory_size
	b^ = {}
}

// create_image makes a device-local 2D image (an array of layers when
// view_type is D2_ARRAY) with mips levels, and a view of all of it.
create_image :: proc(
	g: ^Gpu,
	width, height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	name: string,
	mips: u32 = 1,
	layers: u32 = 1,
	view_type := vk.ImageViewType.D2,
) -> (
	img: Image,
	ok: bool,
) {
	info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width, height, 1},
		mipLevels     = mips,
		arrayLayers   = layers,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	check(vk.CreateImage(g.device, &info, nil, &img.handle)) or_return
	defer if !ok {destroy_image(g, &img)} 	// whatever was made before a failure
	reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g.device, img.handle, &reqs)
	img.memory = allocate(g, reqs, {.DEVICE_LOCAL}) or_return
	img.memory_size = int(reqs.size)
	check(vk.BindImageMemory(g.device, img.handle, img.memory, 0)) or_return
	img.format, img.width, img.height, img.mips, img.layers = format, width, height, mips, layers
	view_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = img.handle,
		viewType         = view_type,
		format           = format,
		subresourceRange = whole_image(img),
	}
	check(vk.CreateImageView(g.device, &view_info, nil, &img.view)) or_return
	set_name(g, .IMAGE, u64(img.handle), name)
	set_name(g, .IMAGE_VIEW, u64(img.view), name)
	return img, true
}

destroy_image :: proc(g: ^Gpu, img: ^Image) {
	if img.view != 0 {vk.DestroyImageView(g.device, img.view, nil)}
	if img.handle != 0 {vk.DestroyImage(g.device, img.handle, nil)}
	if img.memory != 0 {vk.FreeMemory(g.device, img.memory, nil)}
	g.memory_bytes -= img.memory_size
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

// whole_image is the subresource range of every mip and layer.
whole_image :: proc(img: Image) -> vk.ImageSubresourceRange {
	aspect: vk.ImageAspectFlags = {.DEPTH} if img.format == DEPTH_FORMAT else {.COLOR}
	return {aspectMask = aspect, levelCount = img.mips, layerCount = img.layers}
}

// upload_image records copies of regions from staging into img, which
// becomes SHADER_READ_ONLY_OPTIMAL for fragment shaders. Replaces all of the
// image's contents (regions should cover it); record outside rendering.
upload_image :: proc(
	cmd: vk.CommandBuffer,
	staging: Buffer,
	img: Image,
	regions: []vk.BufferImageCopy,
) {
	to_transfer := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.FRAGMENT_SHADER}, // earlier frames' reads
		dstStageMask     = {.COPY},
		dstAccessMask    = {.TRANSFER_WRITE},
		oldLayout        = .UNDEFINED,
		newLayout        = .TRANSFER_DST_OPTIMAL,
		image            = img.handle,
		subresourceRange = whole_image(img),
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_transfer,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
	vk.CmdCopyBufferToImage(
		cmd,
		staging.handle,
		img.handle,
		.TRANSFER_DST_OPTIMAL,
		u32(len(regions)),
		raw_data(regions),
	)
	to_shader := vk.ImageMemoryBarrier2 {
		sType            = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask     = {.COPY},
		srcAccessMask    = {.TRANSFER_WRITE},
		dstStageMask     = {.FRAGMENT_SHADER},
		dstAccessMask    = {.SHADER_SAMPLED_READ},
		oldLayout        = .TRANSFER_DST_OPTIMAL,
		newLayout        = .SHADER_READ_ONLY_OPTIMAL,
		image            = img.handle,
		subresourceRange = whole_image(img),
	}
	dep.pImageMemoryBarriers = &to_shader
	vk.CmdPipelineBarrier2(cmd, &dep)
}

@(private)
allocate :: proc(
	g: ^Gpu,
	reqs: vk.MemoryRequirements,
	props: vk.MemoryPropertyFlags,
	device_address := false,
) -> (
	mem: vk.DeviceMemory,
	ok: bool,
) {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g.physical, &mem_props)
	for i in 0 ..< mem_props.memoryTypeCount {
		if reqs.memoryTypeBits & (1 << i) == 0 {continue}
		if mem_props.memoryTypes[i].propertyFlags & props != props {continue}
		flags := vk.MemoryAllocateFlagsInfo {
			sType = .MEMORY_ALLOCATE_FLAGS_INFO,
			flags = {.DEVICE_ADDRESS},
		}
		info := vk.MemoryAllocateInfo {
			sType           = .MEMORY_ALLOCATE_INFO,
			pNext           = &flags if device_address else nil,
			allocationSize  = reqs.size,
			memoryTypeIndex = i,
		}
		check(vk.AllocateMemory(g.device, &info, nil, &mem)) or_return
		g.memory_bytes += int(reqs.size)
		return mem, true
	}
	log.errorf("gpu no memory type with %v for %d bytes", props, reqs.size)
	return 0, false
}

// Memory_Report: device memory as the driver sees it (VK_EXT_memory_budget), summed
// over the device-local heaps: what the whole process uses and what it may use.
Memory_Report :: struct {
	ours:   int, // allocated by us (Gpu.memory_bytes)
	usage:  int, // the process's use of device-local heaps (0: no memory_budget)
	budget: int, // what the driver lets it use there now (0: no memory_budget)
}

memory_report :: proc(g: ^Gpu) -> (r: Memory_Report) {
	r.ours = g.memory_bytes
	if !g.memory_budget {return}
	budget := vk.PhysicalDeviceMemoryBudgetPropertiesEXT {
		sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
	}
	props := vk.PhysicalDeviceMemoryProperties2 {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
		pNext = &budget,
	}
	vk.GetPhysicalDeviceMemoryProperties2(g.physical, &props)
	for heap, i in props.memoryProperties.memoryHeaps[:props.memoryProperties.memoryHeapCount] {
		if .DEVICE_LOCAL not_in heap.flags {continue}
		r.usage += int(budget.heapUsage[i])
		r.budget += int(budget.heapBudget[i])
	}
	return
}
