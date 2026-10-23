package platform

import "core:dynlib"
import "core:log"
import "core:reflect"
import "core:strings"
import vk "vendor:vulkan"
import "vendor:x11/xlib"

// Linux backend: X11 (Wayland desktops run it through XWayland). libX11 is
// loaded at runtime, so only its types come from vendor:x11 and nothing is
// linked at build time.

VULKAN_LOADER :: "libvulkan.so.1"

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
	MapWindow:                 proc "c" (display: ^xlib.Display, window: xlib.Window) -> i32,
	Pending:                   proc "c" (display: ^xlib.Display) -> i32,
	NextEvent:                 proc "c" (display: ^xlib.Display, event: ^xlib.XEvent) -> i32,
	PeekEvent:                 proc "c" (display: ^xlib.Display, event: ^xlib.XEvent) -> i32,
	Flush:                     proc "c" (display: ^xlib.Display) -> i32,
	LookupKeysym:              proc "c" (event: ^xlib.XKeyEvent, index: i32) -> xlib.KeySym,
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
}

@(private)
x: X11

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

@(private)
native_open :: proc(w: ^Window, title: string) -> bool {
	if x.__handle == nil {
		// Every field but __handle must resolve.
		count, ok := dynlib.initialize_symbols(&x, "libX11.so.6", "X")
		if !ok || count != reflect.struct_field_count(X11) - 1 {
			log.errorf("platform: could not load libX11.so.6 (%s)", dynlib.last_error())
			return false
		}
	}
	n := &w.native
	n.display = x.OpenDisplay(nil)
	if n.display == nil {
		log.error("platform: cannot open the X display (is DISPLAY set?)")
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
		log.error("platform: XCreateWindow failed")
		x.CloseDisplay(n.display)
		return false
	}
	x.StoreName(n.display, n.window, strings.clone_to_cstring(title, context.temp_allocator))
	n.wm_delete_window = x.InternAtom(n.display, "WM_DELETE_WINDOW", false)
	x.SetWMProtocols(n.display, n.window, &n.wm_delete_window, 1)
	x.MapWindow(n.display, n.window)
	x.Flush(n.display)
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
			log.info("platform: libXi not available; mouse look uses pointer warping")
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

@(private)
native_close :: proc(w: ^Window) {
	n := &w.native
	if n.display == nil {return}
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

@(private)
native_poll :: proc(w: ^Window) {
	n := &w.native
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
			if xlib.Atom(e.xclient.data.l[0]) == n.wm_delete_window {
				w.close_requested = true
			}
		case .ConfigureNotify:
			width, height := e.xconfigure.width, e.xconfigure.height
			if width != w.width || height != w.height {
				push_event(w, Resize_Event{width, height})
			}
		case .FocusIn, .FocusOut:
			push_event(w, Focus_Event{e.type == .FocusIn})
		case .KeyPress, .KeyRelease:
			pressed := e.type == .KeyPress
			key := key_from_keysym(x.LookupKeysym(&e.xkey, 0))
			repeat := pressed && n.keys_down[key]
			n.keys_down[key] = pressed
			push_event(w, Key_Event{key, pressed, repeat})
			if pressed {
				// Latin-1 text for now; full Unicode input (XIM) comes with the UI.
				buf: [8]u8
				if count := x.LookupString(&e.xkey, &buf[0], len(buf), nil, nil);
				   count == 1 && buf[0] >= 0x20 && buf[0] != 0x7f {
					push_event(w, Text_Event{rune(buf[0])})
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
