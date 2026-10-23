package gpu

import "base:runtime"
import "core:dynlib"
import "core:log"
import "core:strings"
import "core:sync"
import vk "vendor:vulkan"

import "../base"

// Vulkan device, swapchain and frame pacing. Vulkan 1.3 core features only:
// dynamic rendering (no render passes or framebuffers) and synchronization2.
//
// Setup is two-phase because the window owns surface creation:
//
//	gpu.create_instance(&g, platform.vulkan_loader_name(), platform.vulkan_instance_extensions(), gpu.Validation{enabled = true})
//	surface := platform.vulkan_create_surface(&window, g.instance)
//	gpu.init_device(&g, surface)
//
// The Gpu must not move after create_instance: the validation callback holds
// a pointer to it.

FRAMES_IN_FLIGHT :: 2

// Validation configures the Khronos validation layer (when installed).
// Synchronization validation is always on with it: it catches CPU/GPU and
// GPU/GPU races, the hardest Vulkan bugs to find otherwise.
Validation :: struct {
	enabled:        bool,
	best_practices: bool, // advice about API usage; noisy
	gpu_assisted:   bool, // checks inside shaders (out-of-bounds etc.); slow
}

Gpu :: struct {
	loader:               dynlib.Library,
	instance:             vk.Instance,
	messenger:            vk.DebugUtilsMessengerEXT,
	surface:              vk.SurfaceKHR,
	physical:             vk.PhysicalDevice,
	device:               vk.Device,
	queue_family:         u32,
	queue:                vk.Queue,
	device_name:          string,
	swapchain:            Swapchain,
	frames:               [FRAMES_IN_FLIGHT]Frame_Sync,
	frame_index:          int,
	ctx:                  runtime.Context, // logger etc. for the validation callback
	debug_utils:          bool, // object names and command labels are available
	// GPU timing (timing.odin)
	timing:               bool,
	calibrated:           bool, // GPU timestamps convertible to the trace clock
	host_time_domain:     vk.TimeDomainKHR,
	timestamp_period:     f32, // ns per tick
	timestamp_mask:       u64,
	gpu_frame_stats:      base.Frame_Stats,
	// Bindless textures and the pipeline layout every pipeline shares.
	bindless:             Bindless,
	pipeline_layout:      vk.PipelineLayout,
	max_anisotropy:       f32, // 0 when not supported
	screenshot_requested: bool,
	// Validation-layer warnings and errors since startup. Tests and CI runs
	// treat any as a failure.
	validation_issues:    int,
}

// create_instance opens the Vulkan loader and creates the instance, with the
// Khronos validation layer when requested and installed.
create_instance :: proc(
	g: ^Gpu,
	loader_name: string,
	extensions: []cstring,
	validation: Validation,
) -> bool {
	g^ = {}
	g.ctx = context

	lib, loaded := dynlib.load_library(loader_name)
	if !loaded {
		log.errorf(
			"gpu cannot load the Vulkan loader %s - is a Vulkan driver installed?",
			loader_name,
		)
		return false
	}
	g.loader = lib
	get_instance_proc_addr, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found {
		log.errorf("gpu %s has no vkGetInstanceProcAddr", loader_name)
		return false
	}
	vk.load_proc_addresses_global(get_instance_proc_addr)

	version: u32
	if vk.EnumerateInstanceVersion(&version) != .SUCCESS || version < vk.API_VERSION_1_3 {
		log.errorf(
			"gpu Vulkan 1.3 required, the loader offers %d.%d",
			version >> 22,
			(version >> 12) & 0x3ff,
		)
		return false
	}

	exts := make([dynamic]cstring, context.temp_allocator)
	append(&exts, ..extensions)
	layers := make([dynamic]cstring, context.temp_allocator)
	use_validation := validation.enabled && has_validation_layer()
	if validation.enabled && !use_validation {
		log.warn(
			"gpu validation requested but VK_LAYER_KHRONOS_validation is not installed (Linux: vulkan-validation-layers package; Windows/macOS: Vulkan SDK)",
		)
	}
	if use_validation {
		append(&layers, "VK_LAYER_KHRONOS_validation")
		append(&exts, "VK_EXT_debug_utils", "VK_EXT_validation_features")
	}
	enabled_features := make([dynamic]vk.ValidationFeatureEnableEXT, context.temp_allocator)
	append(&enabled_features, vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION)
	if validation.best_practices {append(&enabled_features, vk.ValidationFeatureEnableEXT.BEST_PRACTICES)}
	if validation.gpu_assisted {append(&enabled_features, vk.ValidationFeatureEnableEXT.GPU_ASSISTED)}

	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "Voxiverse",
		pEngineName      = "Voxiverse",
		apiVersion       = vk.API_VERSION_1_3,
	}
	messenger_info := debug_messenger_info(g)
	features := vk.ValidationFeaturesEXT {
		sType                         = .VALIDATION_FEATURES_EXT,
		pNext                         = &messenger_info,
		enabledValidationFeatureCount = u32(len(enabled_features)),
		pEnabledValidationFeatures    = raw_data(enabled_features),
	}
	info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app,
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
		// Also report problems during vkCreateInstance/vkDestroyInstance.
		pNext                   = &features if use_validation else nil,
	}
	if result := vk.CreateInstance(&info, nil, &g.instance); result != .SUCCESS {
		log.errorf("gpu vkCreateInstance failed: %v", result)
		return false
	}
	vk.load_proc_addresses_instance(g.instance)
	if use_validation {
		vk.CreateDebugUtilsMessengerEXT(g.instance, &messenger_info, nil, &g.messenger)
		g.debug_utils = true
		log.infof(
			"gpu validation on best_practices=%v gpu_assisted=%v",
			validation.best_practices,
			validation.gpu_assisted,
		)
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
	features12 := vk.PhysicalDeviceVulkan12Features {
		sType                                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		descriptorIndexing                           = true,
		runtimeDescriptorArray                       = true,
		descriptorBindingPartiallyBound              = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
		shaderSampledImageArrayNonUniformIndexing    = true,
		bufferDeviceAddress                          = true,
	}
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &features12,
		dynamicRendering = true,
		synchronization2 = true,
	}
	supported: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(g.physical, &supported)
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features13,
		features = {samplerAnisotropy = supported.samplerAnisotropy},
	}
	device_extensions := make([dynamic]cstring, context.temp_allocator)
	append(&device_extensions, "VK_KHR_swapchain")
	calibration := has_device_extension(g.physical, "VK_KHR_calibrated_timestamps")
	if calibration {append(&device_extensions, "VK_KHR_calibrated_timestamps")}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
	}
	if result := vk.CreateDevice(g.physical, &info, nil, &g.device); result != .SUCCESS {
		log.errorf("gpu vkCreateDevice failed: %v", result)
		return false
	}
	vk.load_proc_addresses_device(g.device)
	vk.GetDeviceQueue(g.device, g.queue_family, 0, &g.queue)
	set_name(g, .QUEUE, u64(uintptr(g.queue)), "main queue")
	choose_surface_format(g) // fixed from here on, so pipelines can use it

	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical, &props)
	timing_setup(g, queue_timestamp_bits(g), props.limits.timestampPeriod, calibration)
	if supported.samplerAnisotropy {g.max_anisotropy = props.limits.maxSamplerAnisotropy}

	for &f, i in g.frames {
		if !create_frame_sync(g, &f, i) {return false}
	}
	return bindless_init(g)
}

// destroy releases everything and returns the final count of validation
// findings. Some validation runs asynchronously and only finishes while the
// device and instance are torn down, so read the count here, not earlier.
destroy :: proc(g: ^Gpu) -> (validation_issues: int) {
	if g.device != nil {
		vk.DeviceWaitIdle(g.device)
		// The last frames' GPU timings are still unread; oldest slot first.
		for i in 0 ..< FRAMES_IN_FLIGHT {
			timing_collect(g, &g.frames[(g.frame_index + i) % FRAMES_IN_FLIGHT].timing)
		}
		timing_log_summary(g)
		for &f in g.frames {destroy_frame_sync(g, &f)}
		bindless_destroy(g)
		destroy_swapchain(g, &g.swapchain)
		vk.DestroyDevice(g.device, nil)
	}
	if g.instance != nil {
		if g.surface != 0 {vk.DestroySurfaceKHR(g.instance, g.surface, nil)}
		if g.messenger != 0 {vk.DestroyDebugUtilsMessengerEXT(g.instance, g.messenger, nil)}
		vk.DestroyInstance(g.instance, nil)
	}
	validation_issues = sync.atomic_load(&g.validation_issues)
	if g.loader != nil {dynlib.unload_library(g.loader)}
	delete(g.device_name)
	g^ = {}
	return
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
			"gpu no GPU with Vulkan 1.3 (dynamic rendering, synchronization2, descriptor indexing) that can present to this window",
		)
		return false
	}
	log.infof("gpu device name=%q", g.device_name)
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
	features12 := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	}
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext = &features12,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features13,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)
	return bool(
		features13.dynamicRendering &&
		features13.synchronization2 &&
		features12.descriptorIndexing &&
		features12.runtimeDescriptorArray &&
		features12.descriptorBindingPartiallyBound &&
		features12.descriptorBindingSampledImageUpdateAfterBind &&
		features12.shaderSampledImageArrayNonUniformIndexing &&
		features12.bufferDeviceAddress,
	)
}

@(private)
has_device_extension :: proc(device: vk.PhysicalDevice, name: string) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	exts := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(exts))
	for &e in exts {
		if string(cstring(&e.extensionName[0])) == name {return true}
	}
	return false
}

@(private)
queue_timestamp_bits :: proc(g: ^Gpu) -> u32 {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(g.physical, &count, nil)
	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(g.physical, &count, raw_data(families))
	return families[g.queue_family].timestampValidBits
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

// debug_callback reports layer and loader messages through the
// application's logger (the context captured at create_instance).
//
// Validation findings (warnings and errors other than best-practices advice
// and layer notices) are counted, logged with the stack of our code that made
// the offending call (the layer calls back synchronously from inside it) and
// stop in an attached debugger with VX_BREAK=1. Loader messages go to the
// log file at debug level.
@(private)
debug_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types: vk.DebugUtilsMessageTypeFlagsEXT,
	data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	g := cast(^Gpu)user_data
	context = g.ctx
	message := string(data.pMessage) if data != nil && data.pMessage != nil else "(no message)"
	id := string(data.pMessageIdName) if data != nil && data.pMessageIdName != nil else ""

	switch {
	case !(.WARNING in severity || .ERROR in severity) ||
	     !(.VALIDATION in types || .PERFORMANCE in types):
		// Loader messages (e.g. a driver that doesn't apply to this machine).
		log.debugf("vulkan [%s]: %s", id, message)
		return false
	case strings.has_prefix(id, "VALIDATION-SETTINGS") ||
	     strings.has_prefix(id, "WARNING-Setting"):
		// The layer describing its own configuration (GPU-assisted mode).
		log.infof("vulkan [%s]: %s", id, message)
		return false
	case strings.has_prefix(id, "BestPractices-"):
		// Advice (VX_VALIDATION=best): worth reading, not a bug.
		log.warnf("vulkan advice [%s]: %s", id, message)
		return false
	}
	sync.atomic_add(&g.validation_issues, 1)
	level: log.Level = .Error if .ERROR in severity else .Warning
	log.logf(level, "vulkan [%s]: %s", id, message)
	if !base.log_stack_trace(level, 1) {
		log.logf(
			level,
			"  (found by the validation layer's own thread, after the call returned: use the object names and labels above)",
		)
	}
	base.debug_break()
	return false
}

// set_name labels a Vulkan object for validation messages, RenderDoc and
// other tools, e.g. set_name(g, .FENCE, u64(fence), "frame 0 fence").
// Dispatchable handles (queue, command buffer, ...) pass u64(uintptr(h)).
// No-op without the debug utils extension.
set_name :: proc(g: ^Gpu, type: vk.ObjectType, handle: u64, name: string) {
	if !g.debug_utils || handle == 0 {return}
	info := vk.DebugUtilsObjectNameInfoEXT {
		sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
		objectType   = type,
		objectHandle = handle,
		pObjectName  = strings.clone_to_cstring(name, context.temp_allocator),
	}
	vk.SetDebugUtilsObjectNameEXT(g.device, &info)
}

// begin_label / end_label bracket a section of a command buffer: it is
// named in validation messages and captures (RenderDoc) and timed on the GPU
// (timing.odin). Use between begin_frame and end_frame; pairs must balance.
begin_label :: proc(
	g: ^Gpu,
	cmd: vk.CommandBuffer,
	name: string,
	color := [4]f32{0.5, 0.5, 0.5, 1},
) {
	timing_section_begin(g, &g.frames[g.frame_index].timing, cmd, name)
	if !g.debug_utils {return}
	label := vk.DebugUtilsLabelEXT {
		sType      = .DEBUG_UTILS_LABEL_EXT,
		pLabelName = strings.clone_to_cstring(name, context.temp_allocator),
		color      = color,
	}
	vk.CmdBeginDebugUtilsLabelEXT(cmd, &label)
}

end_label :: proc(g: ^Gpu, cmd: vk.CommandBuffer) {
	timing_section_end(g, &g.frames[g.frame_index].timing, cmd)
	if !g.debug_utils {return}
	vk.CmdEndDebugUtilsLabelEXT(cmd)
}
