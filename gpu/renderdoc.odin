package gpu

import "core:log"
import "core:strings"

// RenderDoc in-application API. Active only when the game was started from
// RenderDoc (its library is already in the process); otherwise everything
// here is a no-op and RenderDoc is never loaded. RenderDoc's own capture key
// (F12) works regardless; this adds programmatic captures (--capture-frame).
//
// Table layout from renderdoc_app.h (RENDERDOC_API_1_6_0, v1.45); only the
// entries we call are typed.

Renderdoc :: struct {
	api: ^Renderdoc_Api,
}

@(private)
RENDERDOC_API_VERSION_1_6_0 :: 10600

@(private)
Renderdoc_Get_Api :: #type proc "c" (version: i32, out_api: ^rawptr) -> i32

@(private)
Renderdoc_Api :: struct {
	GetAPIVersion:              proc "c" (major, minor, patch: ^i32),
	_:                          [8]rawptr, // capture options, keys, overlay
	RemoveHooks:                rawptr,
	UnloadCrashHandler:         rawptr,
	SetCaptureFilePathTemplate: proc "c" (path_template: cstring),
	GetCaptureFilePathTemplate: rawptr,
	GetNumCaptures:             proc "c" () -> u32,
	GetCapture:                 proc "c" (
		index: u32,
		filename: [^]u8,
		path_length: ^u32,
		timestamp: ^u64,
	) -> u32,
	TriggerCapture:             proc "c" (),
	IsTargetControlConnected:   proc "c" () -> u32,
	LaunchReplayUI:             proc "c" (connect_target_control: u32, cmdline: cstring) -> u32,
	SetActiveWindow:            rawptr,
	StartFrameCapture:          rawptr,
	IsFrameCapturing:           proc "c" () -> u32,
	EndFrameCapture:            rawptr,
	TriggerMultiFrameCapture:   rawptr,
	SetCaptureFileComments:     rawptr,
	DiscardFrameCapture:        rawptr,
	ShowReplayUI:               rawptr,
	SetCaptureTitle:            proc "c" (title: cstring),
}

// renderdoc_attach connects to RenderDoc if it injected itself into this
// process, and makes captures land in capture_dir/<name>_frameN.rdc.
renderdoc_attach :: proc(rd: ^Renderdoc, capture_dir, name: string) -> bool {
	get_api := cast(Renderdoc_Get_Api)renderdoc_find_get_api()
	if get_api == nil {return false}
	api: rawptr
	if get_api(RENDERDOC_API_VERSION_1_6_0, &api) != 1 || api == nil {
		log.warn("gpu: RenderDoc is loaded but did not provide API 1.6")
		return false
	}
	rd.api = cast(^Renderdoc_Api)api
	major, minor, patch: i32
	rd.api.GetAPIVersion(&major, &minor, &patch)
	path := strings.concatenate({capture_dir, "/", name}, context.temp_allocator)
	rd.api.SetCaptureFilePathTemplate(strings.clone_to_cstring(path, context.temp_allocator))
	log.infof(
		"gpu: RenderDoc %d.%d.%d attached, captures go to %s_frame*.rdc",
		major,
		minor,
		patch,
		path,
	)
	return true
}

// renderdoc_capture captures the next frame that gets presented.
renderdoc_capture :: proc(rd: ^Renderdoc, title := "") {
	if rd.api == nil {return}
	if title !=
	   "" {rd.api.SetCaptureTitle(strings.clone_to_cstring(title, context.temp_allocator))}
	rd.api.TriggerCapture()
}

// renderdoc_log_captures lists this run's captures (call at shutdown).
renderdoc_log_captures :: proc(rd: ^Renderdoc) {
	if rd.api == nil {return}
	for i in 0 ..< rd.api.GetNumCaptures() {
		buf: [1024]u8
		length := u32(len(buf))
		timestamp: u64
		if rd.api.GetCapture(i, &buf[0], &length, &timestamp) == 1 && length > 0 {
			log.infof("gpu: RenderDoc capture %s", string(buf[:length - 1]))
		}
	}
}
