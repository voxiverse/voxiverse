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
	log.error("platform the macOS backend is not written yet (milestone M1b)")
	return false
}

@(private)
native_close :: proc(w: ^Window) {}

@(private)
native_key_symbol :: proc(w: ^Window, key: Key) -> Key {return .Unknown}

// An IOKit power assertion keeps the display awake while held.
foreign import iokit "system:IOKit.framework"
foreign import corefoundation "system:CoreFoundation.framework"

@(private = "file")
CFStringRef :: rawptr

@(private = "file", default_calling_convention = "c")
foreign corefoundation {
	CFStringCreateWithCString :: proc(alloc: rawptr, s: cstring, encoding: u32) -> CFStringRef ---
	CFRelease :: proc(cf: rawptr) ---
}

@(private = "file", default_calling_convention = "c")
foreign iokit {
	IOPMAssertionCreateWithName :: proc(kind: CFStringRef, level: u32, name: CFStringRef, id: ^u32) -> i32 ---
	IOPMAssertionRelease :: proc(id: u32) -> i32 ---
}

@(private = "file")
assertion: u32

@(private)
native_set_keep_awake :: proc(w: ^Window, on: bool) {
	UTF8 :: 0x08000100
	ON :: 255 // kIOPMAssertionLevelOn
	if on {
		kind := CFStringCreateWithCString(nil, "PreventUserIdleDisplaySleep", UTF8)
		name := CFStringCreateWithCString(nil, "Voxiverse: playing", UTF8)
		defer CFRelease(kind)
		defer CFRelease(name)
		if IOPMAssertionCreateWithName(kind, ON, name, &assertion) != 0 {
			log.warn(
				"platform IOPMAssertionCreateWithName failed: the screen may sleep while playing",
			)
			assertion = 0
		}
	} else if assertion != 0 {
		IOPMAssertionRelease(assertion)
		assertion = 0
	}
}

@(private)
native_wait :: proc(w: ^Window) {}

@(private)
native_poll :: proc(w: ^Window) {}

@(private)
native_set_mouse_captured :: proc(w: ^Window, captured: bool) {}

@(private)
native_set_fullscreen :: proc(w: ^Window, fullscreen: bool) {}

@(private)
native_vulkan_instance_extensions :: proc() -> []cstring {
	return nil
}

@(private)
native_vulkan_create_surface :: proc(w: ^Window, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	return 0, false
}
