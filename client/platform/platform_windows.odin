package platform

import "base:runtime"
import "core:log"
import win "core:sys/windows"
import vk "vendor:vulkan"

// Windows backend: plain Win32 from core:sys/windows; nothing to ship.

VULKAN_LOADER :: "vulkan-1.dll"

Native_Window :: struct {
	instance:       win.HINSTANCE,
	hwnd:           win.HWND,
	ctx:            runtime.Context, // for the window procedure, which Windows calls
	high_surrogate: u16, // first half of a UTF-16 surrogate pair from WM_CHAR
	captured:       bool, // raw mouse input on, cursor hidden and clipped
	windowed:       win.WINDOWPLACEMENT, // where the window was before fullscreen
}

@(private)
CLASS_NAME :: "VoxiverseWindow"

@(private)
native_open :: proc(w: ^Window, title: string) -> bool {
	n := &w.native
	n.ctx = context
	n.instance = win.HINSTANCE(win.GetModuleHandleW(nil))
	// Real pixels at any display scale (the manifest can't be relied on).
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

	class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_OWNDC,
		lpfnWndProc   = window_proc,
		hInstance     = n.instance,
		hCursor       = win.LoadCursorW(nil, win.wstring(win._IDC_ARROW)),
		lpszClassName = win.L(CLASS_NAME),
	}
	// The icon the build links in (resource 1: `build icon`) for the title
	// bar and taskbar; without it, Windows' default.
	icon_id := rawptr(uintptr(1)) // (MAKEINTRESOURCE, as _IDC_ARROW)
	class.hIcon = win.LoadIconW(n.instance, win.wstring(icon_id))
	class.hIconSm = class.hIcon
	if win.RegisterClassExW(&class) == 0 {
		log.errorf("platform RegisterClassExW failed (%d)", win.GetLastError())
		return false
	}

	// Requested size is in 96-DPI units; the window itself is in pixels.
	scale := f32(win.GetDpiForSystem()) / 96
	style := win.WS_OVERLAPPEDWINDOW
	rect := win.RECT{0, 0, i32(f32(w.width) * scale), i32(f32(w.height) * scale)}
	win.AdjustWindowRectEx(&rect, style, false, 0)

	n.hwnd = win.CreateWindowExW(
		0,
		win.L(CLASS_NAME),
		win.utf8_to_wstring(title, context.temp_allocator),
		style,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		rect.right - rect.left,
		rect.bottom - rect.top,
		nil,
		nil,
		n.instance,
		w, // reaches WM_NCCREATE, which stores it for window_proc
	)
	if n.hwnd == nil {
		log.errorf("platform CreateWindowExW failed (%d)", win.GetLastError())
		win.UnregisterClassW(win.L(CLASS_NAME), n.instance)
		return false
	}
	client: win.RECT
	win.GetClientRect(n.hwnd, &client)
	w.width, w.height = client.right, client.bottom
	win.ShowWindow(n.hwnd, win.SW_SHOWDEFAULT)
	return true
}

// SetThreadExecutionState is not in core:sys/windows.
foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	SetThreadExecutionState :: proc(flags: u32) -> u32 ---
}

@(private = "file")
ES_CONTINUOUS :: 0x80000000
@(private = "file")
ES_SYSTEM_REQUIRED :: 0x00000001
@(private = "file")
ES_DISPLAY_REQUIRED :: 0x00000002

@(private = "file")
keep_awake_warned: bool // a failure is told once per run

// The display and the system stay on while this thread says so (until
// it says ES_CONTINUOUS alone).
// The window's icon is the executable's resource.
@(private)
native_set_window_icon :: proc(w: ^Window, images: []Icon_Image) {}

@(private)
native_set_keep_awake :: proc(w: ^Window, on: bool) {
	flags := u32(ES_CONTINUOUS)
	if on {flags |= ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED}
	if SetThreadExecutionState(flags) == 0 {
		if !keep_awake_warned {
			keep_awake_warned = true
			log.warn("platform SetThreadExecutionState failed: the screen may sleep while playing")
		}
	} else {
		log.debugf("platform keep awake on=%v", on)
	}
}

@(private)
native_close :: proc(w: ^Window) {
	n := &w.native
	if n.captured {native_set_mouse_captured(w, false)}
	if n.hwnd != nil {win.DestroyWindow(n.hwnd)}
	win.UnregisterClassW(win.L(CLASS_NAME), n.instance)
}

@(private)
native_wait :: proc(w: ^Window) {
	win.WaitMessage()
}

// Captured: raw input (WM_INPUT) gives unaccelerated mouse deltas; the
// cursor is hidden and clipped to the window so clicks stay inside.
@(private)
native_set_mouse_captured :: proc(w: ^Window, captured: bool) {
	n := &w.native
	if captured == n.captured {return}
	device := win.RAWINPUTDEVICE {
		usUsagePage = win.HID_USAGE_PAGE_GENERIC,
		usUsage     = win.HID_USAGE_GENERIC_MOUSE,
		hwndTarget  = n.hwnd if captured else nil,
		dwFlags     = 0 if captured else win.RIDEV_REMOVE,
	}
	if !win.RegisterRawInputDevices(&device, 1, size_of(device)) {
		log.errorf("platform RegisterRawInputDevices failed (%d)", win.GetLastError())
		return
	}
	n.captured = captured
	win.ShowCursor(win.BOOL(!captured))
	if captured {clip_cursor(w)} else {win.ClipCursor(nil)}
}

// Fullscreen is borderless: the window loses its frame and covers its
// monitor; leaving puts frame and placement back.
@(private)
native_set_fullscreen :: proc(w: ^Window, fullscreen: bool) {
	n := &w.native
	style := win.GetWindowLongPtrW(n.hwnd, win.GWL_STYLE)
	if fullscreen {
		n.windowed.length = size_of(n.windowed)
		win.GetWindowPlacement(n.hwnd, &n.windowed)
		info := win.MONITORINFO {
			cbSize = size_of(win.MONITORINFO),
		}
		win.GetMonitorInfoW(win.MonitorFromWindow(n.hwnd, .MONITOR_DEFAULTTONEAREST), &info)
		m := info.rcMonitor
		win.SetWindowLongPtrW(
			n.hwnd,
			win.GWL_STYLE,
			style & ~win.LONG_PTR(win.WS_OVERLAPPEDWINDOW),
		)
		win.SetWindowPos(
			n.hwnd,
			win.HWND_TOP,
			m.left,
			m.top,
			m.right - m.left,
			m.bottom - m.top,
			win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED,
		)
	} else {
		win.SetWindowLongPtrW(n.hwnd, win.GWL_STYLE, style | win.LONG_PTR(win.WS_OVERLAPPEDWINDOW))
		win.SetWindowPlacement(n.hwnd, &n.windowed)
		win.SetWindowPos(
			n.hwnd,
			nil,
			0,
			0,
			0,
			0,
			win.SWP_NOMOVE |
			win.SWP_NOSIZE |
			win.SWP_NOZORDER |
			win.SWP_NOOWNERZORDER |
			win.SWP_FRAMECHANGED,
		)
	}
}

@(private = "file")
clip_cursor :: proc(w: ^Window) {
	r: win.RECT
	win.GetClientRect(w.native.hwnd, &r)
	corners := [2]win.POINT{{r.left, r.top}, {r.right, r.bottom}}
	win.ClientToScreen(w.native.hwnd, &corners[0])
	win.ClientToScreen(w.native.hwnd, &corners[1])
	clip := win.RECT{corners[0].x, corners[0].y, corners[1].x, corners[1].y}
	win.ClipCursor(&clip)
}

@(private)
native_poll :: proc(w: ^Window) {
	msg: win.MSG
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		win.TranslateMessage(&msg) // produces WM_CHAR from key messages
		win.DispatchMessageW(&msg)
	}
}

@(private)
window_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	if msg == win.WM_NCCREATE {
		create := cast(^win.CREATESTRUCTW)uintptr(lparam)
		win.SetWindowLongPtrW(
			hwnd,
			win.GWLP_USERDATA,
			win.LONG_PTR(uintptr(create.lpCreateParams)),
		)
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}
	w := cast(^Window)uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))
	if w == nil {return win.DefWindowProcW(hwnd, msg, wparam, lparam)}
	context = w.native.ctx

	mouse_pos :: proc(lparam: win.LPARAM) -> (f32, f32) {
		return f32(win.GET_X_LPARAM(lparam)), f32(win.GET_Y_LPARAM(lparam))
	}
	mouse_button :: proc(
		w: ^Window,
		hwnd: win.HWND,
		button: Mouse_Button,
		pressed: bool,
		lparam: win.LPARAM,
	) {
		// Capture so a drag that leaves the window still reports its release.
		if pressed {win.SetCapture(hwnd)} else {win.ReleaseCapture()}
		px, py := mouse_pos(lparam)
		push_event(w, Mouse_Button_Event{button, pressed, px, py})
	}

	switch msg {
	case win.WM_CLOSE:
		w.close_requested = true
		return 0
	case win.WM_SIZE:
		width, height := i32(win.LOWORD(lparam)), i32(win.HIWORD(lparam))
		if wparam == win.SIZE_MINIMIZED {width, height = 0, 0}
		if width != w.width || height != w.height {
			push_event(w, Resize_Event{width, height})
		}
		if w.native.captured {clip_cursor(w)}
		return 0
	case win.WM_MOVE:
		if w.native.captured {clip_cursor(w)}
		return 0
	case win.WM_INPUT:
		raw: win.RAWINPUT
		size := u32(size_of(raw))
		if w.native.captured &&
		   win.GetRawInputData(
			   win.HRAWINPUT(lparam),
			   win.RID_INPUT,
			   &raw,
			   &size,
			   size_of(win.RAWINPUTHEADER),
		   ) !=
			   max(u32) &&
		   raw.header.dwType == win.RIM_TYPEMOUSE &&
		   raw.data.mouse.usFlags & win.MOUSE_MOVE_ABSOLUTE == 0 {
			dx, dy := raw.data.mouse.lLastX, raw.data.mouse.lLastY
			if dx != 0 || dy != 0 {push_event(w, Mouse_Delta_Event{f32(dx), f32(dy)})}
		}
		return win.DefWindowProcW(hwnd, msg, wparam, lparam) // releases the input
	case win.WM_SETFOCUS, win.WM_KILLFOCUS:
		push_event(w, Focus_Event{msg == win.WM_SETFOCUS})
		return 0
	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_SYSKEYUP:
		pressed := msg == win.WM_KEYDOWN || msg == win.WM_SYSKEYDOWN
		repeat := pressed && (lparam & (1 << 30)) != 0
		symbol := key_from_vk(wparam, lparam)
		key := key_from_scancode(u32((lparam >> 16) & 0xff), lparam & (1 << 24) != 0)
		push_event(w, Key_Event{key if key != .Unknown else symbol, symbol, pressed, repeat})
		if msg == win.WM_SYSKEYDOWN || msg == win.WM_SYSKEYUP {
			// Let Alt+F4 and friends work.
			return win.DefWindowProcW(hwnd, msg, wparam, lparam)
		}
		return 0
	case win.WM_CHAR:
		unit := u16(wparam)
		switch {
		case unit >= 0xD800 && unit <= 0xDBFF:
			w.native.high_surrogate = unit
		case unit >= 0xDC00 && unit <= 0xDFFF:
			if high := w.native.high_surrogate; high != 0 {
				r := 0x10000 + (rune(high - 0xD800) << 10) + rune(unit - 0xDC00)
				push_event(w, Text_Event{r})
			}
			w.native.high_surrogate = 0
		case unit >= 0x20 && unit != 0x7f:
			push_event(w, Text_Event{rune(unit)})
		}
		return 0
	case win.WM_MOUSEMOVE:
		if w.native.captured {return 0} 	// WM_INPUT reports motion instead
		px, py := mouse_pos(lparam)
		push_event(w, Mouse_Move_Event{px, py})
		return 0
	case win.WM_LBUTTONDOWN, win.WM_LBUTTONUP:
		mouse_button(w, hwnd, .Left, msg == win.WM_LBUTTONDOWN, lparam)
		return 0
	case win.WM_RBUTTONDOWN, win.WM_RBUTTONUP:
		mouse_button(w, hwnd, .Right, msg == win.WM_RBUTTONDOWN, lparam)
		return 0
	case win.WM_MBUTTONDOWN, win.WM_MBUTTONUP:
		mouse_button(w, hwnd, .Middle, msg == win.WM_MBUTTONDOWN, lparam)
		return 0
	case win.WM_XBUTTONDOWN, win.WM_XBUTTONUP:
		button: Mouse_Button = .X1 if win.GET_XBUTTON_WPARAM(wparam) == win.XBUTTON1 else .X2
		mouse_button(w, hwnd, button, msg == win.WM_XBUTTONDOWN, lparam)
		return 1 // XBUTTON messages want TRUE
	case win.WM_MOUSEWHEEL:
		push_event(
			w,
			Mouse_Wheel_Event{0, f32(win.GET_WHEEL_DELTA_WPARAM(wparam)) / win.WHEEL_DELTA},
		)
		return 0
	case win.WM_MOUSEHWHEEL:
		push_event(
			w,
			Mouse_Wheel_Event{f32(win.GET_WHEEL_DELTA_WPARAM(wparam)) / win.WHEEL_DELTA, 0},
		)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

@(private)
native_vulkan_instance_extensions :: proc() -> []cstring {
	@(static, rodata)
	extensions := [?]cstring{"VK_KHR_surface", "VK_KHR_win32_surface"}
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
	info := vk.Win32SurfaceCreateInfoKHR {
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = w.native.instance,
		hwnd      = w.native.hwnd,
	}
	if vk.CreateWin32SurfaceKHR(instance, &info, nil, &surface) != .SUCCESS {return 0, false}
	return surface, true
}

// native_key_symbol: the layout's key at key's scan code.
@(private)
native_key_symbol :: proc(w: ^Window, key: Key) -> Key {
	code := u32(SCANCODES[key])
	vk_code := win.MapVirtualKeyW(code, win.MAPVK_VSC_TO_VK_EX)
	if vk_code == 0 {return .Unknown}
	return key_from_vk(win.WPARAM(vk_code), win.LPARAM((code & 0xff) << 16))
}

@(private)
key_from_vk :: proc(wparam: win.WPARAM, lparam: win.LPARAM) -> Key {
	vk_code := u32(wparam)
	extended := (lparam & (1 << 24)) != 0
	switch vk_code {
	case 'A' ..= 'Z':
		return Key(int(Key.A) + int(vk_code - 'A'))
	case '0' ..= '9':
		return Key(int(Key.Num_0) + int(vk_code - '0'))
	case win.VK_F1 ..= win.VK_F12:
		return Key(int(Key.F1) + int(vk_code - win.VK_F1))
	case win.VK_ESCAPE:
		return .Escape
	case win.VK_RETURN:
		return .Enter
	case win.VK_TAB:
		return .Tab
	case win.VK_BACK:
		return .Backspace
	case win.VK_SPACE:
		return .Space
	case win.VK_OEM_3:
		return .Grave
	case win.VK_OEM_MINUS:
		return .Minus
	case win.VK_OEM_PLUS:
		return .Equals
	case win.VK_OEM_4:
		return .Left_Bracket
	case win.VK_OEM_6:
		return .Right_Bracket
	case win.VK_OEM_5:
		return .Backslash
	case win.VK_OEM_1:
		return .Semicolon
	case win.VK_OEM_7:
		return .Apostrophe
	case win.VK_OEM_COMMA:
		return .Comma
	case win.VK_OEM_PERIOD:
		return .Period
	case win.VK_OEM_2:
		return .Slash
	case win.VK_CAPITAL:
		return .Caps_Lock
	case win.VK_LEFT:
		return .Left
	case win.VK_RIGHT:
		return .Right
	case win.VK_UP:
		return .Up
	case win.VK_DOWN:
		return .Down
	case win.VK_HOME:
		return .Home
	case win.VK_END:
		return .End
	case win.VK_PRIOR:
		return .Page_Up
	case win.VK_NEXT:
		return .Page_Down
	case win.VK_INSERT:
		return .Insert
	case win.VK_DELETE:
		return .Delete
	case win.VK_SHIFT:
		// Left and right shift share a code; the scan code tells them apart.
		scancode := u32((lparam >> 16) & 0xff)
		left := win.MapVirtualKeyW(scancode, win.MAPVK_VSC_TO_VK_EX) == win.VK_LSHIFT
		return .Left_Shift if left else .Right_Shift
	case win.VK_CONTROL:
		return .Right_Control if extended else .Left_Control
	case win.VK_MENU:
		return .Right_Alt if extended else .Left_Alt
	}
	return .Unknown
}
