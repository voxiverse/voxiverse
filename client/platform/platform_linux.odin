package platform

import "core:dynlib"
import "core:log"
import "core:reflect"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import vk "vendor:vulkan"
import "vendor:x11/xlib"

// Linux backend: X11 (Wayland desktops run it through XWayland). libX11 is
// loaded at runtime, so only its types come from vendor:x11 and nothing is
// linked at build time.

@(private)
native_vulkan_loader_name :: proc() -> string {
	return "libvulkan.so.1"
}

Native_Window :: struct {
	display:          ^xlib.Display,
	window:           xlib.Window,
	wm_delete_window: xlib.Atom,
	keys_down:        [Key]bool, // to tell auto-repeat presses from real ones
	// Mouse capture: pointer grabbed, cursor hidden and kept at the centre.
	// Motion comes from XInput2 raw events (device deltas, unaccelerated;
	// XWayland feeds them from Wayland's relative pointer) when libXi is
	// available, otherwise from how far the pointer moved off the centre.
	captured:         bool,
	xi_opcode:        i32, // XInput extension opcode; 0 without XInput2
	grab_pending:     bool, // the grab failed (e.g. not yet viewable): retry
	// Until the first warp lands, motion is measured from wherever the
	// pointer was before: ignore it.
	awaiting_centre:  bool,
	hidden_cursor:    xlib.Cursor,
	awake_reset:      time.Tick, // when X's screensaver timer was last reset (keep_awake)
	// XIM for Unicode/composed text input (dead keys, CJK IMEs); an IM that
	// supports neither preedit nor status is ignored. Fallback: Latin-1 text.
	xim:              rawptr,
	ic:               rawptr,
}

@(private)
X11 :: struct {
	__handle:                  dynlib.Library,
	OpenDisplay:               proc "c" (name: cstring) -> ^xlib.Display,
	CloseDisplay:              proc "c" (display: ^xlib.Display) -> i32,
	DefaultScreen:             proc "c" (display: ^xlib.Display) -> i32,
	RootWindow:                proc "c" (display: ^xlib.Display, screen: i32) -> xlib.Window,
	CreateWindow:              proc "c" (
		display: ^xlib.Display,
		parent: xlib.Window,
		x, y: i32,
		width, height, border_width: u32,
		depth: i32,
		class: u32,
		visual: rawptr,
		valuemask: xlib.WindowAttributeMask,
		attributes: ^xlib.XSetWindowAttributes,
	) -> xlib.Window,
	DestroyWindow:             proc "c" (display: ^xlib.Display, window: xlib.Window) -> i32,
	ResetScreenSaver:          proc "c" (display: ^xlib.Display) -> i32,
	StoreName:                 proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		name: cstring,
	) -> i32,
	InternAtom:                proc "c" (
		display: ^xlib.Display,
		name: cstring,
		only_if_exists: b32,
	) -> xlib.Atom,
	SetWMProtocols:            proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		protocols: [^]xlib.Atom,
		count: i32,
	) -> xlib.Status,
	SetWMNormalHints:          proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		hints: ^xlib.XSizeHints,
	),
	MapWindow:                 proc "c" (display: ^xlib.Display, window: xlib.Window) -> i32,
	MoveWindow:                proc "c" (display: ^xlib.Display, window: xlib.Window, x, y: i32),
	TranslateCoordinates:      proc "c" (
		display: ^xlib.Display,
		src_window, dst_window: xlib.Window,
		src_x, src_y: i32,
		dst_x, dst_y: ^i32,
		dst_child: ^xlib.Window,
	) -> xlib.Status,
	Pending:                   proc "c" (display: ^xlib.Display) -> i32,
	NextEvent:                 proc "c" (display: ^xlib.Display, event: ^xlib.XEvent) -> i32,
	PeekEvent:                 proc "c" (display: ^xlib.Display, event: ^xlib.XEvent) -> i32,
	Flush:                     proc "c" (display: ^xlib.Display) -> i32,
	LookupKeysym:              proc "c" (event: ^xlib.XKeyEvent, index: i32) -> xlib.KeySym,
	KeycodeToKeysym:           proc "c" (
		display: ^xlib.Display,
		keycode: xlib.KeyCode,
		index: i32,
	) -> xlib.KeySym,
	LookupString:              proc "c" (
		event: ^xlib.XKeyEvent,
		buffer: [^]u8,
		length: i32,
		keysym: ^xlib.KeySym,
		status: rawptr,
	) -> i32,
	GrabPointer:               proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		owner_events: b32,
		mask: xlib.EventMask,
		pointer_mode, keyboard_mode: xlib.GrabMode,
		confine_to: xlib.Window,
		cursor: xlib.Cursor,
		time: xlib.Time,
	) -> i32,
	UngrabPointer:             proc "c" (display: ^xlib.Display, time: xlib.Time) -> i32,
	WarpPointer:               proc "c" (
		display: ^xlib.Display,
		src, dst: xlib.Window,
		src_x, src_y: i32,
		src_width, src_height: u32,
		dst_x, dst_y: i32,
	) -> i32,
	CreatePixmap:              proc "c" (
		display: ^xlib.Display,
		drawable: xlib.Drawable,
		width, height, depth: u32,
	) -> xlib.Pixmap,
	FreePixmap:                proc "c" (display: ^xlib.Display, pixmap: xlib.Pixmap) -> i32,
	CreatePixmapCursor:        proc "c" (
		display: ^xlib.Display,
		source, mask: xlib.Pixmap,
		fg, bg: ^xlib.XColor,
		x, y: u32,
	) -> xlib.Cursor,
	FreeCursor:                proc "c" (display: ^xlib.Display, cursor: xlib.Cursor) -> i32,
	DefineCursor:              proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		cursor: xlib.Cursor,
	) -> i32,
	UndefineCursor:            proc "c" (display: ^xlib.Display, window: xlib.Window) -> i32,
	QueryExtension:            proc "c" (
		display: ^xlib.Display,
		name: cstring,
		opcode, event, error: ^i32,
	) -> b32,
	GetEventData:              proc "c" (
		display: ^xlib.Display,
		cookie: ^xlib.XGenericEventCookie,
	) -> b32,
	FreeEventData:             proc "c" (
		display: ^xlib.Display,
		cookie: ^xlib.XGenericEventCookie,
	),
	kbSetDetectableAutoRepeat: proc "c" (
		display: ^xlib.Display,
		detectable: b32,
		supported: ^b32,
	) -> b32,
	XOpenIM:                   proc "c" (
		display: ^xlib.Display,
		dbase: rawptr,
		res_name: cstring,
		res_class: cstring,
	) -> rawptr,
	XCloseIM:                  proc "c" (xim: rawptr) -> i32,
	XCreateIC:                 proc "c" (xim: rawptr, #c_vararg args: ..any) -> rawptr,
	XDestroyIC:                proc "c" (xic: rawptr) -> i32,
	XSetICFocus:               proc "c" (xic: rawptr) -> i32,
	XUnsetICFocus:             proc "c" (xic: rawptr) -> i32,
	XSetIMValues:              proc "c" (xim: rawptr, #c_vararg args: ..any) -> rawptr,
	XGetIMValues:              proc "c" (xim: rawptr, #c_vararg args: ..any) -> rawptr,
	XFilterEvent:              proc "c" (event: ^xlib.XEvent, w: xlib.Window) -> bool,
	Xutf8LookupString:         proc "c" (
		ic: rawptr,
		event: ^xlib.XKeyEvent,
		buffer: [^]u8,
		length: i32,
		keysym: ^xlib.KeySym,
		status: ^i32,
	) -> i32,
	XmbLookupString:           proc "c" (
		ic: rawptr,
		event: ^xlib.XKeyEvent,
		buffer: [^]u8,
		length: i32,
		keysym: ^xlib.KeySym,
		status: ^i32,
	) -> i32,
	XFree:                     proc "c" (ptr: rawptr) -> i32,
	ChangeProperty:            proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		property, type: xlib.Atom,
		format, mode: i32,
		data: rawptr,
		count: i32,
	) -> i32,
	SendEvent:                 proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		propagate: b32,
		mask: xlib.EventMask,
		event: ^xlib.XEvent,
	) -> i32,
}

@(private)
x: X11

// libXrandr, for monitor names, sizes and refresh rates (optional).
@(private)
RR :: struct {
	__handle:               dynlib.Library,
	XRRGetScreenResources:  proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
	) -> ^xlib.XRRScreenResources,
	XRRFreeScreenResources: proc "c" (resources: ^xlib.XRRScreenResources),
	XRRGetOutputInfo:       proc "c" (
		display: ^xlib.Display,
		resources: ^xlib.XRRScreenResources,
		output: xlib.RROutput,
	) -> ^xlib.XRROutputInfo,
	XRRFreeOutputInfo:      proc "c" (output_info: ^xlib.XRROutputInfo),
	XRRGetCrtcInfo:         proc "c" (
		display: ^xlib.Display,
		resources: ^xlib.XRRScreenResources,
		crtc: xlib.RRCrtc,
	) -> ^xlib.XRRCrtcInfo,
	XRRFreeCrtcInfo:        proc "c" (crtc_info: ^xlib.XRRCrtcInfo),
}

// Raw RandR: X outputs (connected monitors), their current CRTCs, the mode
// the CRTC is on, and that mode's dot clock / totals give the refresh rate.
@(private)
rr: RR
@(private)
rr_failed: bool // set when libXrandr is unusable, for the rest of the run

@(private)
rr_usable :: proc(display: ^xlib.Display) -> bool {
	if rr.__handle == nil {
		if rr_failed {return false}
		count, ok := dynlib.initialize_symbols(&rr, "libXrandr.so.2", "XRR")
		if !ok || count != reflect.struct_field_count(RR) - 1 {
			log.info("platform RandR unavailable: no monitor info or refresh rate")
			rr_failed = true
			return false
		}
	}
	return true
}

// libXi, for raw mouse motion (optional).
@(private)
XI :: struct {
	__handle:       dynlib.Library,
	XIQueryVersion: proc "c" (display: ^xlib.Display, major, minor: ^i32) -> i32,
	XISelectEvents: proc "c" (
		display: ^xlib.Display,
		window: xlib.Window,
		masks: ^XI_Event_Mask,
		count: i32,
	) -> i32,
}

@(private)
xi: XI

@(private)
XI_Event_Mask :: struct {
	deviceid: i32,
	mask_len: i32,
	mask:     [^]u8,
}

@(private)
XI_Raw_Event :: struct {
	type:       i32,
	serial:     uint,
	send_event: b32,
	display:    ^xlib.Display,
	extension:  i32,
	evtype:     i32,
	time:       xlib.Time,
	deviceid:   i32,
	sourceid:   i32,
	detail:     i32,
	flags:      i32,
	valuators:  struct {
		mask_len: i32,
		mask:     [^]u8,
		values:   [^]f64,
	},
	raw_values: [^]f64,
}

@(private)
XI_ALL_MASTER_DEVICES :: 1
@(private)
XI_RAW_MOTION :: 17

// XIM error/status constants (Xlib protocol spec).
@(private)
XBufferOverflow :: 4
@(private)
XLookupChars :: 2
@(private)
XLookupBoth :: 3

// xim_destroy_callback: the IM disappeared (its server exited). Its ICs are
// gone with it; clear the references so we do not use them later.
@(private)
xim_destroy_callback :: proc "c" (xim: xlib.XIM, client_data: rawptr, call_data: rawptr) {
	n := (^Native_Window)(client_data)
	if n != nil {
		n.ic = nil
		n.xim = nil
	}
}

// ic_destroy_callback: the IC was destroyed underneath us (IM exiting or
// reset). Do not touch it afterwards.
@(private)
ic_destroy_callback :: proc "c" (xim: xlib.XIM, client_data: rawptr, call_data: rawptr) {
	n := (^Native_Window)(client_data)
	if n != nil {n.ic = nil}
}

// setup_xim opens the X input method and creates an input context (preedit
// and status styles, the ones the app draws inside itself). On any failure
// the window gets no IC and text input falls back to Latin-1.
@(private)
setup_xim :: proc(w: ^Window) {
	n := &w.native
	styles: ^xlib.XIMStyles
	n.xim = x.XOpenIM(n.display, nil, nil, nil)
	if n.xim != nil {
		im_cb := xlib.XIMCallback {
			client_data = n,
			callback    = xim_destroy_callback,
		}
		x.XSetIMValues(n.xim, "destroyCallback", &im_cb, nil)
	}
	if n.xim == nil {
		log.info("platform no IM for this locale; text input will be Latin-1 only")
		return
	}
	if x.XGetIMValues(n.xim, "queryInputStyle", &styles, nil) != nil {
		log.info("platform this IM has no supported styles; text input will be Latin-1 only")
		x.XCloseIM(n.xim)
		n.xim = nil
		return
	}
	found := false
	want := xlib.XIMStyle(xlib.XIMPreeditNothing | xlib.XIMStatusNothing)
	for i in 0 ..< int(styles.count_styles) {
		if styles.supported_styles[i] == want {
			found = true
			break
		}
	}
	x.XFree(styles)
	if !found {
		log.info("platform this IM supports no hidden style; text input will be Latin-1 only")
		x.XCloseIM(n.xim)
		n.xim = nil
		return
	}
	ic_cb := xlib.XICCallback {
		client_data = n,
		callback    = ic_destroy_callback,
	}
	style := xlib.XIMStyle(xlib.XIMPreeditNothing | xlib.XIMStatusNothing)
	ic := x.XCreateIC(
		n.xim,
		"inputStyle",
		style,
		"clientWindow",
		n.window,
		"focusWindow",
		n.window,
		"destroyCallback",
		&ic_cb,
		nil,
	)
	if ic == nil {
		log.info("platform could not create an IC; text input will be Latin-1 only")
		x.XCloseIM(n.xim)
		n.xim = nil
		return
	}
	n.ic = ic
	if w.focused {x.XSetICFocus(n.ic)}
}

@(private)
native_open :: proc(w: ^Window, title: string) -> bool {
	if x.__handle == nil {
		// Every field but __handle must resolve.
		count, ok := dynlib.initialize_symbols(&x, "libX11.so.6", "X")
		if !ok || count != reflect.struct_field_count(X11) - 1 {
			log.errorf("platform could not load libX11.so.6 (%s)", dynlib.last_error())
			return false
		}
	}
	n := &w.native
	n.display = x.OpenDisplay(nil)
	if n.display == nil {
		log.error("platform cannot open the X display (is DISPLAY set?)")
		return false
	}
	// Without this, holding a key produces fake release+press pairs.
	x.kbSetDetectableAutoRepeat(n.display, true, nil)

	screen := x.DefaultScreen(n.display)
	attributes := xlib.XSetWindowAttributes {
		event_mask = {
			.KeyPress,
			.KeyRelease,
			.ButtonPress,
			.ButtonRelease,
			.PointerMotion,
			.StructureNotify,
			.FocusChange,
		},
	}
	n.window = x.CreateWindow(
		n.display,
		x.RootWindow(n.display, screen),
		0,
		0,
		u32(w.width),
		u32(w.height),
		0,
		0, // CopyFromParent depth
		1, // InputOutput
		nil, // CopyFromParent visual
		{.CWEventMask},
		&attributes,
	)
	if n.window == 0 {
		log.error("platform XCreateWindow failed")
		x.CloseDisplay(n.display)
		return false
	}
	x.StoreName(n.display, n.window, strings.clone_to_cstring(title, context.temp_allocator))
	n.wm_delete_window = x.InternAtom(n.display, "WM_DELETE_WINDOW", false)
	x.SetWMProtocols(n.display, n.window, &n.wm_delete_window, 1)
	x.MapWindow(n.display, n.window)
	x.Flush(n.display)
	setup_xim(w)
	setup_raw_motion(n)
	return true
}

// setup_raw_motion subscribes to XInput2 raw motion (delivered to the root
// window; used only while captured).
@(private = "file")
setup_raw_motion :: proc(n: ^Native_Window) {
	if xi.__handle == nil {
		count, ok := dynlib.initialize_symbols(&xi, "libXi.so.6")
		if !ok || count != reflect.struct_field_count(XI) - 1 {
			log.info("platform libXi not available; mouse look uses pointer warping")
			return
		}
	}
	opcode, first_event, first_error: i32
	if !x.QueryExtension(
		n.display,
		"XInputExtension",
		&opcode,
		&first_event,
		&first_error,
	) {return}
	major, minor: i32 = 2, 0
	SUCCESS :: 0
	if xi.XIQueryVersion(n.display, &major, &minor) != SUCCESS {return}
	bits: [(XI_RAW_MOTION + 8) / 8]u8
	bits[XI_RAW_MOTION / 8] |= 1 << (XI_RAW_MOTION % 8)
	mask := XI_Event_Mask{XI_ALL_MASTER_DEVICES, len(bits), &bits[0]}
	if xi.XISelectEvents(
		   n.display,
		   x.RootWindow(n.display, x.DefaultScreen(n.display)),
		   &mask,
		   1,
	   ) !=
	   SUCCESS {
		return
	}
	n.xi_opcode = opcode
}

// The window's icon: _NET_WM_ICON, CARDINAL/32 (width, height, then ARGB per
// pixel, for each size). Format 32 is an array of C longs, 64 bits here.
@(private)
native_set_window_icon :: proc(w: ^Window, images: []Icon_Image) {
	n := &w.native
	XA_CARDINAL :: 6
	data := make([dynamic]int, context.temp_allocator)
	for im in images {
		if im.size <= 0 || len(im.rgba) != im.size * im.size * 4 {continue}
		append(&data, im.size, im.size)
		for i in 0 ..< im.size * im.size {
			p := im.rgba[i * 4:][:4]
			append(&data, int(u32(p[3]) << 24 | u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])))
		}
	}
	if len(data) == 0 {return}
	x.ChangeProperty(
		n.display,
		n.window,
		x.InternAtom(n.display, "_NET_WM_ICON", false),
		XA_CARDINAL,
		32,
		0, // PropModeReplace
		raw_data(data),
		i32(len(data)),
	)
	x.Flush(n.display)
}

// Set the WM_NORMAL_HINTS property's minimum size; a WM that honors the
// property (most modern ones do) refuses to shrink our window below it.
@(private)
native_set_window_min_size :: proc(w: ^Window, width, height: i32) {
	n := &w.native
	hints := xlib.XSizeHints {
		flags      = {.PMinSize},
		min_width  = width,
		min_height = height,
	}
	x.SetWMNormalHints(n.display, n.window, &hints)
}

// Placement: XMoveWindow asks the WM to reconfigure to the given coordinates
// (like the resize events, it is a request most WMs honor). Wayland-compositor
// setups ignore it, matching SDL and GLFW.
@(private)
native_set_window_position :: proc(w: ^Window, xi32, yi32: i32) {
	n := &w.native
	x.MoveWindow(n.display, n.window, xi32, yi32)
	x.Flush(n.display)
}

// Root-relative coordinates of the top-left corner of the window; frame
// included, like SDL_GetWindowPosition on X11.
@(private)
native_window_position :: proc(w: ^Window) -> (wx, wy: i32, ok: bool) {
	n := &w.native
	root := x.RootWindow(n.display, x.DefaultScreen(n.display))
	child: xlib.Window
	rx, ry: i32
	if x.TranslateCoordinates(n.display, n.window, root, 0, 0, &rx, &ry, &child) != .Success {
		return 0, 0, false
	}
	return rx, ry, true
}

// Always-on-top: asked of the window manager (EWMH _NET_WM_STATE_ABOVE).
// Useful when the game needs to stay on top of other windows (e.g., while
// the user is watching another app for reference). Default is off.
@(private)
native_set_always_on_top :: proc(w: ^Window, on: bool) {
	n := &w.native
	NET_WM_STATE_REMOVE :: 0
	NET_WM_STATE_ADD :: 1
	e: xlib.XEvent
	e.xclient = {
		type         = .ClientMessage,
		window       = n.window,
		message_type = x.InternAtom(n.display, "_NET_WM_STATE", false),
		format       = 32,
	}
	e.xclient.data.l[0] = NET_WM_STATE_ADD if on else NET_WM_STATE_REMOVE
	e.xclient.data.l[1] = int(x.InternAtom(n.display, "_NET_WM_STATE_ABOVE", false))
	e.xclient.data.l[3] = 1 // from a normal application
	root := x.RootWindow(n.display, x.DefaultScreen(n.display))
	x.SendEvent(n.display, root, false, {.SubstructureNotify, .SubstructureRedirect}, &e)
	x.Flush(n.display)
}

// Fullscreen: asked of the window manager (EWMH _NET_WM_STATE_FULLSCREEN),
// which removes the frame and covers the monitor; the new size arrives as
// a ConfigureNotify like any resize.
@(private)
native_set_fullscreen :: proc(w: ^Window, fullscreen: bool) {
	n := &w.native
	NET_WM_STATE_REMOVE :: 0
	NET_WM_STATE_ADD :: 1
	e: xlib.XEvent
	e.xclient = {
		type         = .ClientMessage,
		window       = n.window,
		message_type = x.InternAtom(n.display, "_NET_WM_STATE", false),
		format       = 32,
	}
	e.xclient.data.l[0] = NET_WM_STATE_ADD if fullscreen else NET_WM_STATE_REMOVE
	e.xclient.data.l[1] = int(x.InternAtom(n.display, "_NET_WM_STATE_FULLSCREEN", false))
	e.xclient.data.l[3] = 1 // from a normal application
	root := x.RootWindow(n.display, x.DefaultScreen(n.display))
	x.SendEvent(n.display, root, false, {.SubstructureNotify, .SubstructureRedirect}, &e)
	x.Flush(n.display)
}

@(private)
native_set_keep_awake :: proc(w: ^Window, on: bool) {
	screensaver_inhibit(on)
	w.native.awake_reset = {}
}

@(private)
native_close :: proc(w: ^Window) {
	n := &w.native
	if n.display == nil {return}
	if n.ic != nil {x.XDestroyIC(n.ic); n.ic = nil}
	if n.xim != nil {x.XCloseIM(n.xim); n.xim = nil}
	if n.captured {native_set_mouse_captured(w, false)}
	if n.hidden_cursor != 0 {x.FreeCursor(n.display, n.hidden_cursor)}
	if n.window != 0 {x.DestroyWindow(n.display, n.window)}
	x.CloseDisplay(n.display)
}

@(private)
native_wait :: proc(w: ^Window) {
	e: xlib.XEvent
	x.PeekEvent(w.native.display, &e) // blocks until an event is queued
}

@(private)
native_set_mouse_captured :: proc(w: ^Window, captured: bool) {
	n := &w.native
	n.grab_pending = false
	if captured {
		if n.hidden_cursor == 0 {
			// A 1x1 cursor with an empty mask: invisible.
			pixmap := x.CreatePixmap(n.display, xlib.Drawable(n.window), 1, 1, 1)
			black: xlib.XColor
			n.hidden_cursor = x.CreatePixmapCursor(n.display, pixmap, pixmap, &black, &black, 0, 0)
			x.FreePixmap(n.display, pixmap)
		}
		x.DefineCursor(n.display, n.window, n.hidden_cursor)
		GRAB_SUCCESS :: 0
		mask: xlib.EventMask = {.ButtonPress, .ButtonRelease, .PointerMotion}
		if x.GrabPointer(
			   n.display,
			   n.window,
			   true,
			   mask,
			   .GrabModeAsync,
			   .GrabModeAsync,
			   n.window,
			   n.hidden_cursor,
			   xlib.CurrentTime,
		   ) !=
		   GRAB_SUCCESS {
			n.grab_pending = true
		}
		if !n.captured {n.awaiting_centre = true}
		n.captured = true
		warp_to_centre(w)
	} else if n.captured {
		x.UngrabPointer(n.display, xlib.CurrentTime)
		x.UndefineCursor(n.display, n.window)
		n.captured = false
		warp_to_centre(w) // release where the cursor isn't in anyone's way
	}
	x.Flush(n.display)
}

@(private = "file")
warp_to_centre :: proc(w: ^Window) {
	x.WarpPointer(w.native.display, 0, w.native.window, 0, 0, 0, 0, w.width / 2, w.height / 2)
}

// push_xim_text: full input-method text (dead keys, CJK compose) from the
// IC's UTF-8 lookup, as rune Text_Events.
@(private)
push_xim_text :: proc(w: ^Window, ic: rawptr, e: ^xlib.XKeyEvent) {
	buf: [64]u8
	status: i32
	count := x.Xutf8LookupString(ic, e, &buf[0], len(buf), nil, &status)
	out: []u8
	if status == XBufferOverflow {
		out = make([]u8, count + 1, context.temp_allocator)
		count = x.Xutf8LookupString(ic, e, raw_data(out), i32(count + 1), nil, &status)
	} else {
		out = buf[:count]
	}
	if status == XLookupChars || status == XLookupBoth {
		i := 0
		for i < int(count) {
			r, n := utf8.decode_rune_in_bytes(out[i:])
			if r == utf8.RUNE_ERROR && n == 1 {break}
			push_event(w, Text_Event{r})
			i += n
		}
	}
}


@(private)
native_poll :: proc(w: ^Window) {
	n := &w.native
	if w.keep_awake && time.tick_since(n.awake_reset) > KEEP_AWAKE_RESET {
		x.ResetScreenSaver(n.display)
		n.awake_reset = time.tick_now()
	}
	if n.grab_pending {native_set_mouse_captured(w, true)}
	moved := false
	defer if moved {
		warp_to_centre(w)
		x.Flush(n.display)
	}
	for x.Pending(n.display) > 0 {
		e: xlib.XEvent
		x.NextEvent(n.display, &e)
		#partial switch e.type {
		case .ClientMessage:
			state := x.InternAtom(n.display, "_NET_WM_STATE", true)
			hidden := x.InternAtom(n.display, "_NET_WM_STATE_HIDDEN", true)
			if state != 0 && xlib.Atom(e.xclient.message_type) == state {
				// XEvent.xclient.data.l is an array of 32-bit ints; the X event format guarantees
				// that even for pointer-size atoms we get at most 32 bits per slot.
				a, b := xlib.Atom(e.xclient.data.l[1]), xlib.Atom(e.xclient.data.l[2])
				if hidden != 0 && (a == hidden || b == hidden) {
					add := e.xclient.data.l[0] == 1
					if add {
						// Closer to the minimization state the game treats as 0x0.
						push_event(w, Resize_Event{0, 0})
					}
					break
				}
			}
			if xlib.Atom(e.xclient.data.l[0]) == n.wm_delete_window {
				w.close_requested = true
			}
		case .ConfigureNotify:
			width, height := e.xconfigure.width, e.xconfigure.height
			if width != w.width || height != w.height {
				push_event(w, Resize_Event{width, height})
			}
		case .FocusIn, .FocusOut:
			if n.ic != nil {
				if e.type == .FocusIn {x.XSetICFocus(n.ic)} else {x.XUnsetICFocus(n.ic)}
			}
			push_event(w, Focus_Event{e.type == .FocusIn})
		case .KeyPress, .KeyRelease:
			// XIM first: a filtered event is consumed by the input method
			// (dead keys, composed CJK) and no normal key repeat/text events
			// should be generated from it. Note keycode is kept from before the
			// filter because the IM may modify it.
			keycode := e.xkey.keycode
			filtered := false
			if n.ic != nil {filtered = x.XFilterEvent(&e, n.window)}
			// The IM consumed the event (dead keys, composed CJK): no game
			// input, key repeat or text should fire from it.
			if filtered {break}
			pressed := e.type == .KeyPress
			symbol := key_from_keysym(x.LookupKeysym(&e.xkey, 0))
			key := key_from_evdev(keycode - 8)
			if key == .Unknown {key = symbol}
			repeat := pressed && n.keys_down[key]
			n.keys_down[key] = pressed
			push_event(w, Key_Event{key, symbol, pressed, repeat})
			if pressed {
				if n.ic != nil {
					push_xim_text(w, n.ic, &e.xkey)
				} else {
					// Latin-1 text for systems without an input method.
					buf: [8]u8
					if count := x.LookupString(&e.xkey, &buf[0], len(buf), nil, nil);
					   count == 1 && buf[0] >= 0x20 && buf[0] != 0x7f {
						push_event(w, Text_Event{rune(buf[0])})
					}
				}
			}
		case .MotionNotify:
			if n.captured {
				// Away from the centre: put it back (keeps clicks inside).
				dx, dy := e.xmotion.x - w.width / 2, e.xmotion.y - w.height / 2
				if n.awaiting_centre {
					if dx == 0 && dy == 0 {n.awaiting_centre = false}
				} else if dx != 0 || dy != 0 {
					// Without raw motion, this is the motion.
					if n.xi_opcode == 0 {push_event(w, Mouse_Delta_Event{f32(dx), f32(dy)})}
					moved = true
				}
			} else {
				push_event(w, Mouse_Move_Event{f32(e.xmotion.x), f32(e.xmotion.y)})
			}
		case .GenericEvent:
			cookie := &e.xcookie
			if n.xi_opcode == 0 ||
			   cookie.extension != n.xi_opcode ||
			   !x.GetEventData(n.display, cookie) {
				continue
			}
			defer x.FreeEventData(n.display, cookie)
			if cookie.evtype != XI_RAW_MOTION || !n.captured || !w.focused {continue}
			raw := (^XI_Raw_Event)(cookie.data)
			// raw_values holds one value per set mask bit; x is axis 0, y axis 1.
			d: [2]f64
			next := 0
			for axis in 0 ..< min(int(raw.valuators.mask_len) * 8, 2) {
				if raw.valuators.mask[axis / 8] & (1 << uint(axis % 8)) == 0 {continue}
				d[axis] = raw.raw_values[next]
				next += 1
			}
			if d != {} {push_event(w, Mouse_Delta_Event{f32(d.x), f32(d.y)})}
		case .ButtonPress, .ButtonRelease:
			pressed := e.type == .ButtonPress
			px, py := f32(e.xbutton.x), f32(e.xbutton.y)
			switch e.xbutton.button {
			case .Button1:
				push_event(w, Mouse_Button_Event{.Left, pressed, px, py})
			case .Button2:
				push_event(w, Mouse_Button_Event{.Middle, pressed, px, py})
			case .Button3:
				push_event(w, Mouse_Button_Event{.Right, pressed, px, py})
			case .Button4:
				if pressed {push_event(w, Mouse_Wheel_Event{0, 1})}
			case .Button5:
				if pressed {push_event(w, Mouse_Wheel_Event{0, -1})}
			case:
				// 6/7: horizontal wheel, 8/9: back/forward.
				switch u32(e.xbutton.button) {
				case 6:
					if pressed {push_event(w, Mouse_Wheel_Event{-1, 0})}
				case 7:
					if pressed {push_event(w, Mouse_Wheel_Event{1, 0})}
				case 8:
					push_event(w, Mouse_Button_Event{.X1, pressed, px, py})
				case 9:
					push_event(w, Mouse_Button_Event{.X2, pressed, px, py})
				}
			}
		}
	}
}

@(private)
native_vulkan_instance_extensions :: proc() -> []cstring {
	@(static, rodata)
	extensions := [?]cstring{"VK_KHR_surface", "VK_KHR_xlib_surface"}
	return extensions[:]
}

@(private)
native_vulkan_create_surface :: proc(
	w: ^Window,
	instance: vk.Instance,
) -> (
	surface: vk.SurfaceKHR,
	ok: bool,
) {
	info := vk.XlibSurfaceCreateInfoKHR {
		sType  = .XLIB_SURFACE_CREATE_INFO_KHR,
		dpy    = w.native.display,
		window = w.native.window,
	}
	if vk.CreateXlibSurfaceKHR(instance, &info, nil, &surface) != .SUCCESS {return 0, false}
	return surface, true
}

// key_from_evdev: X keycodes are Linux's evdev codes + 8, which are scan
// codes for the main block; the extended keys have codes of their own.
@(private)
key_from_evdev :: proc(code: u32) -> Key {
	switch code {
	case 96:
		return .Enter
	case 97:
		return .Right_Control
	case 100:
		return .Right_Alt
	// Keypad digits
	case 71:
		return .Num_7
	case 72:
		return .Num_8
	case 73:
		return .Num_9
	case 75:
		return .Num_4
	case 76:
		return .Num_5
	case 77:
		return .Num_6
	case 79:
		return .Num_1
	case 80:
		return .Num_2
	case 81:
		return .Num_3
	case 82:
		return .Num_0
	// Keypad operators and punctuation
	case 55:
		return .Num_Asterisk
	case 74:
		return .Num_Minus
	case 78:
		return .Num_Plus
	case 83:
		return .Num_Decimal
	case 98:
		return .Num_Slash
	case 102 ..= 111:
		NAV := [?]Key {
			.Home,
			.Up,
			.Page_Up,
			.Left,
			.Right,
			.End,
			.Down,
			.Page_Down,
			.Insert,
			.Delete,
		}
		return NAV[code - 102]
	}
	return key_from_scancode(code, false)
}

// native_key_symbol: the layout's key at key's keycode.
@(private)
native_key_symbol :: proc(w: ^Window, key: Key) -> Key {
	if w.native.display == nil {return .Unknown}
	code := u32(SCANCODES[key]) + 8
	return key_from_keysym(x.KeycodeToKeysym(w.native.display, xlib.KeyCode(code), 0))
}

@(private)
key_from_keysym :: proc(sym: xlib.KeySym) -> Key {
	#partial switch sym {
	case .XK_a ..= .XK_z:
		return Key(int(Key.A) + int(sym - .XK_a))
	case .XK_0 ..= .XK_9:
		return Key(int(Key.Num_0) + int(sym - .XK_0))
	case .XK_F1 ..= .XK_F12:
		return Key(int(Key.F1) + int(sym - .XK_F1))
	case .XK_Escape:
		return .Escape

	case .XK_KP_0 ..= .XK_KP_9:
		return Key(int(Key.Num_0) + int(sym - .XK_KP_0))
	case .XK_KP_Multiply:
		return .Num_Asterisk
	case .XK_KP_Add:
		return .Num_Plus
	case .XK_KP_Subtract:
		return .Num_Minus
	case .XK_KP_Decimal:
		return .Num_Decimal
	case .XK_KP_Divide:
		return .Num_Slash
	case .XK_KP_Separator:
		return .Comma
	case .XK_Return, .XK_KP_Enter:
		return .Enter
	case .XK_Tab:
		return .Tab
	case .XK_BackSpace:
		return .Backspace
	case .XK_space:
		return .Space
	case .XK_grave:
		return .Grave
	case .XK_minus:
		return .Minus
	case .XK_equal:
		return .Equals
	case .XK_bracketleft:
		return .Left_Bracket
	case .XK_bracketright:
		return .Right_Bracket
	case .XK_backslash:
		return .Backslash
	case .XK_semicolon:
		return .Semicolon
	case .XK_apostrophe:
		return .Apostrophe
	case .XK_comma:
		return .Comma
	case .XK_period:
		return .Period
	case .XK_slash:
		return .Slash
	case .XK_Caps_Lock:
		return .Caps_Lock
	case .XK_Left:
		return .Left
	case .XK_Right:
		return .Right
	case .XK_Up:
		return .Up
	case .XK_Down:
		return .Down
	case .XK_Home:
		return .Home
	case .XK_End:
		return .End
	case .XK_Page_Up:
		return .Page_Up
	case .XK_Page_Down:
		return .Page_Down
	case .XK_Insert:
		return .Insert
	case .XK_Delete:
		return .Delete
	case .XK_Shift_L:
		return .Left_Shift
	case .XK_Shift_R:
		return .Right_Shift
	case .XK_Control_L:
		return .Left_Control
	case .XK_Control_R:
		return .Right_Control
	case .XK_Alt_L:
		return .Left_Alt
	case .XK_Alt_R:
		return .Right_Alt
	}
	return .Unknown
}

// display_count: the number of connected RandR outputs on the default display,
// or 1/false if we cannot talk to RandR.
@(private)
native_display_count :: proc() -> (count: i32, ok: bool) {
	display := x.OpenDisplay(nil)
	if display == nil {return 1, false}
	defer x.CloseDisplay(display)
	if !rr_usable(display) {return 1, false}
	root := x.RootWindow(display, x.DefaultScreen(display))
	res := rr.XRRGetScreenResources(display, root)
	if res == nil {return 1, false}
	defer rr.XRRFreeScreenResources(res)
	connected: i32
	for i in 0 ..< res.noutput {
		try := rr.XRRGetOutputInfo(display, res, res.outputs[i])
		if try != nil {
			if try.connection == .RR_Connected {connected += 1}
			rr.XRRFreeOutputInfo(try)
		}
	}
	return max(1, connected), true
}

@(private)
native_display_info :: proc(index: i32) -> (info: Display_Info, ok: bool) {
	display := x.OpenDisplay(nil)
	if display == nil {return {}, false}
	defer x.CloseDisplay(display)
	if !rr_usable(display) {return {}, false}
	root := x.RootWindow(display, x.DefaultScreen(display))
	res := rr.XRRGetScreenResources(display, root)
	if res == nil {return {}, false}
	defer rr.XRRFreeScreenResources(res)
	want := int(index)
	idx := 0
	for i in 0 ..< res.noutput {
		try := rr.XRRGetOutputInfo(display, res, res.outputs[i])
		if try == nil {continue}
		if try.connection != .RR_Connected {
			rr.XRRFreeOutputInfo(try)
			continue
		}
		if idx == want {
			info = display_info_from(display, res, try)
			rr.XRRFreeOutputInfo(try)
			return info, true
		}
		rr.XRRFreeOutputInfo(try)
		idx += 1
	}
	return {}, false
}

@(private = "file")
display_info_from :: proc(
	display: ^xlib.Display,
	res: ^xlib.XRRScreenResources,
	output: ^xlib.XRROutputInfo,
) -> Display_Info {
	info := Display_Info {
		name               = strings.clone_from_cstring(
			output.name,
			context.temp_allocator,
		) or_else "",
		physical_mm_width  = i32(output.mm_width),
		physical_mm_height = i32(output.mm_height),
	}
	if output.crtc != 0 {
		crtc := rr.XRRGetCrtcInfo(display, res, output.crtc)
		if crtc != nil {
			info.width, info.height = i32(crtc.width), i32(crtc.height)
			for j in 0 ..< res.nmode {
				if res.modes[j].id == crtc.mode {
					info.refresh_hz =
						f64(res.modes[j].dotClock) /
						1000 /
						(f64(res.modes[j].hTotal) * f64(res.modes[j].vTotal))
					break
				}
			}
			rr.XRRFreeCrtcInfo(crtc)
		}
	}
	return info
}
