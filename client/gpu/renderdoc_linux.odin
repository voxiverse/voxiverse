package gpu

import "core:sys/posix"

// RenderDoc's library is only looked up if already loaded (RTLD_NOLOAD,
// glibc value 0x4, which core:sys/posix doesn't name), never loaded here.
@(private)
renderdoc_find_get_api :: proc() -> rawptr {
	RTLD_NOW_NOLOAD :: 0x2 | 0x4
	lib := posix.dlopen("librenderdoc.so", transmute(posix.RTLD_Flags)i32(RTLD_NOW_NOLOAD))
	if lib == nil {return nil}
	return posix.dlsym(lib, "RENDERDOC_GetAPI")
}
