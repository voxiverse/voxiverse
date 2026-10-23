package gpu

import "base:runtime"
import "core:dynlib"
import "core:log"
import "core:strings"
import "core:sync"
import vk "vendor:vulkan"

// Vulkan device, swapchain and frame pacing. Vulkan 1.3 core features only:
// dynamic rendering (no render passes or framebuffers) and synchronization2.
//
// Setup is two-phase because the window owns surface creation:
//
//	gpu.create_instance(&g, platform.vulkan_loader_name(), platform.vulkan_instance_extensions(), validation)
//	surface := platform.vulkan_create_surface(&window, g.instance)
//	gpu.init_device(&g, surface)
//
// The Gpu must not move after create_instance: the validation callback holds
// a pointer to it.

FRAMES_IN_FLIGHT :: 2

Gpu :: struct {
	loader:            dynlib.Library,
	instance:          vk.Instance,
	messenger:         vk.DebugUtilsMessengerEXT,
	surface:           vk.SurfaceKHR,
	physical:          vk.PhysicalDevice,
	device:            vk.Device,
	queue_family:      u32,
	queue:             vk.Queue,
	device_name:       string,
	swapchain:         Swapchain,
	frames:            [FRAMES_IN_FLIGHT]Frame_Sync,
	frame_index:       int,
	ctx:               runtime.Context, // logger etc. for the validation callback
	// Validation messages at warning level or above since startup. Tests and
	// CI runs treat any as a failure.
	validation_issues: int,
}

// create_instance opens the Vulkan loader and creates the instance, with the
// Khronos validation layer when requested and installed.
create_instance :: proc(
	g: ^Gpu,
	loader_name: string,
	extensions: []cstring,
	validation: bool,
) -> bool {
	g^ = {}
	g.ctx = context

	lib, loaded := dynlib.load_library(loader_name)
	if !loaded {
		log.errorf(
			"gpu: cannot load the Vulkan loader %s - is a Vulkan driver installed?",
			loader_name,
		)
		return false
	}
	g.loader = lib
	get_instance_proc_addr, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found {
		log.errorf("gpu: %s has no vkGetInstanceProcAddr", loader_name)
		return false
	}
	vk.load_proc_addresses_global(get_instance_proc_addr)

	version: u32
	if vk.EnumerateInstanceVersion(&version) != .SUCCESS || version < vk.API_VERSION_1_3 {
		log.errorf(
			"gpu: Vulkan 1.3 required, the loader offers %d.%d",
			version >> 22,
			(version >> 12) & 0x3ff,
		)
		return false
	}

	exts := make([dynamic]cstring, context.temp_allocator)
	append(&exts, ..extensions)
	layers := make([dynamic]cstring, context.temp_allocator)
	use_validation := validation && has_validation_layer()
	if validation && !use_validation {
		log.warn(
			"gpu: validation requested but VK_LAYER_KHRONOS_validation is not installed (Linux: vulkan-validation-layers package; Windows/macOS: Vulkan SDK)",
		)
	}
	if use_validation {
		append(&layers, "VK_LAYER_KHRONOS_validation")
		append(&exts, "VK_EXT_debug_utils")
	}

	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "Voxiverse",
		pEngineName      = "Voxiverse",
		apiVersion       = vk.API_VERSION_1_3,
	}
	messenger_info := debug_messenger_info(g)
	info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app,
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
		// Also report problems during vkCreateInstance/vkDestroyInstance.
		pNext                   = &messenger_info if use_validation else nil,
	}
	if result := vk.CreateInstance(&info, nil, &g.instance); result != .SUCCESS {
		log.errorf("gpu: vkCreateInstance failed: %v", result)
		return false
	}
	vk.load_proc_addresses_instance(g.instance)
	if use_validation {
		vk.CreateDebugUtilsMessengerEXT(g.instance, &messenger_info, nil, &g.messenger)
		log.info("gpu: validation enabled")
	}
	return true
}

// init_device picks a GPU that can draw to surface and creates the device.
// The swapchain is created by the first begin_frame; its colour format
// (color_format) is fixed now, so pipelines can be built before that.
init_device :: proc(g: ^Gpu, surface: vk.SurfaceKHR) -> bool {
	g.surface = surface
	if !pick_physical_device(g) {return false}

	priority: f32 = 1
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = g.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}
	device_extensions := [?]cstring{"VK_KHR_swapchain"}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features13,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = len(device_extensions),
		ppEnabledExtensionNames = &device_extensions[0],
	}
	if result := vk.CreateDevice(g.physical, &info, nil, &g.device); result != .SUCCESS {
		log.errorf("gpu: vkCreateDevice failed: %v", result)
		return false
	}
	vk.load_proc_addresses_device(g.device)
	vk.GetDeviceQueue(g.device, g.queue_family, 0, &g.queue)
	choose_surface_format(g) // fixed from here on, so pipelines can use it

	for &f in g.frames {
		if !create_frame_sync(g, &f) {return false}
	}
	return true
}

destroy :: proc(g: ^Gpu) {
	if g.device != nil {
		vk.DeviceWaitIdle(g.device)
		for &f in g.frames {destroy_frame_sync(g, &f)}
		destroy_swapchain(g, &g.swapchain)
		vk.DestroyDevice(g.device, nil)
	}
	if g.instance != nil {
		if g.surface != 0 {vk.DestroySurfaceKHR(g.instance, g.surface, nil)}
		if g.messenger != 0 {vk.DestroyDebugUtilsMessengerEXT(g.instance, g.messenger, nil)}
		vk.DestroyInstance(g.instance, nil)
	}
	if g.loader != nil {dynlib.unload_library(g.loader)}
	delete(g.device_name)
	g^ = {}
}

// color_format is the swapchain's pixel format, for pipelines that draw to it.
color_format :: proc(g: ^Gpu) -> vk.Format {
	return g.swapchain.format
}

// wait_idle blocks until the GPU has finished all submitted work (before
// destroying resources it might still use).
wait_idle :: proc(g: ^Gpu) {
	vk.DeviceWaitIdle(g.device)
}

@(private)
pick_physical_device :: proc(g: ^Gpu) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(g.instance, &count, nil)
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g.instance, &count, raw_data(devices))

	best_score := -1
	for device in devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)
		family, ok := usable_queue_family(g, device)
		if !ok ||
		   props.apiVersion < vk.API_VERSION_1_3 ||
		   !supports_required_features(device) {continue}
		score := 0
		#partial switch props.deviceType {
		case .DISCRETE_GPU:
			score = 3
		case .INTEGRATED_GPU:
			score = 2
		case .VIRTUAL_GPU:
			score = 1
		}
		if score > best_score {
			best_score = score
			g.physical = device
			g.queue_family = family
			delete(g.device_name)
			name := props.deviceName
			g.device_name = strings.clone(string(cstring(&name[0])))
		}
	}
	if best_score < 0 {
		log.error(
			"gpu: no GPU with Vulkan 1.3, dynamic rendering, synchronization2 and presentation to this window",
		)
		return false
	}
	log.infof("gpu: using %s", g.device_name)
	return true
}

// usable_queue_family finds one family that does both graphics and present.
@(private)
usable_queue_family :: proc(g: ^Gpu, device: vk.PhysicalDevice) -> (u32, bool) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))
	for family, i in families {
		present: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), g.surface, &present)
		if .GRAPHICS in family.queueFlags && present {return u32(i), true}
	}
	return 0, false
}

@(private)
supports_required_features :: proc(device: vk.PhysicalDevice) -> bool {
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features13,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)
	return bool(features13.dynamicRendering && features13.synchronization2)
}

@(private)
has_validation_layer :: proc() -> bool {
	count: u32
	vk.EnumerateInstanceLayerProperties(&count, nil)
	layers := make([]vk.LayerProperties, count, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&count, raw_data(layers))
	for &layer in layers {
		if string(cstring(&layer.layerName[0])) == "VK_LAYER_KHRONOS_validation" {return true}
	}
	return false
}

@(private)
debug_messenger_info :: proc(g: ^Gpu) -> vk.DebugUtilsMessengerCreateInfoEXT {
	return {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
		pUserData = g,
	}
}

// debug_callback reports validation messages through the application's
// logger (the context captured at create_instance) and counts them.
@(private)
debug_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types: vk.DebugUtilsMessageTypeFlagsEXT,
	data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	g := cast(^Gpu)user_data
	context = g.ctx
	sync.atomic_add(&g.validation_issues, 1)
	message := string(data.pMessage) if data != nil && data.pMessage != nil else "(no message)"
	if .ERROR in severity {
		log.errorf("vulkan: %s", message)
	} else {
		log.warnf("vulkan: %s", message)
	}
	return false
}
