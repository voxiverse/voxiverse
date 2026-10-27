package gpu

import win "core:sys/windows"

// RenderDoc's DLL is only looked up if already loaded, never loaded here.
@(private)
renderdoc_find_get_api :: proc() -> rawptr {
	module := win.GetModuleHandleW(win.L("renderdoc.dll"))
	if module == nil {return nil}
	return win.GetProcAddress(module, "RENDERDOC_GetAPI")
}
