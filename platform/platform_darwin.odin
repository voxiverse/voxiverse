package platform

import "core:log"
import vk "vendor:vulkan"

// macOS backend: AppKit + CAMetalLayer with MoltenVK, arriving in milestone
// M1b. Until then the window fails to open with a clear message, so macOS
// still type-checks and builds.

VULKAN_LOADER :: "libvulkan.1.dylib"

Native_Window :: struct {}

@(private)
native_open :: proc(w: ^Window, title: string) -> bool {
	log.error("platform: the macOS backend is not written yet (milestone M1b)")
	return false
}

@(private)
native_close :: proc(w: ^Window) {}

@(private)
native_wait :: proc(w: ^Window) {}

@(private)
native_poll :: proc(w: ^Window) {}

@(private)
native_vulkan_instance_extensions :: proc() -> []cstring {
	return nil
}

@(private)
native_vulkan_create_surface :: proc(w: ^Window, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	return 0, false
}
