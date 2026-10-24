package platform

import vk "vendor:vulkan"

// The platform layer: one window, its events and its Vulkan surface. Each OS
// has its own backend file (platform_windows.odin, platform_linux.odin,
// platform_darwin.odin) implementing the procedures declared at the bottom;
// nothing outside this package sees OS types.
//
// Window system libraries (libX11, ...) are loaded at runtime, so building
// needs no development packages.

Window :: struct {
	width, height:   i32, // framebuffer size in pixels; 0 while minimized
	focused:         bool,
	close_requested: bool,
	mouse_captured:  bool, // wanted (set_mouse_captured); held only while focused
	fullscreen:      bool, // borderless, covering the monitor (set_fullscreen)
	keep_awake:      bool, // the screen kept on (set_keep_awake)
	events:          [dynamic]Event, // this frame's events, refilled by poll_events
	native:          Native_Window, // per-OS state
}

Event :: union {
	Resize_Event,
	Focus_Event,
	Key_Event,
	Text_Event,
	Mouse_Move_Event,
	Mouse_Button_Event,
	Mouse_Wheel_Event,
	Mouse_Delta_Event,
}

Resize_Event :: struct {
	width, height: i32,
}

Focus_Event :: struct {
	focused: bool,
}

Key_Event :: struct {
	key:     Key,
	pressed: bool,
	repeat:  bool, // held-key auto-repeat (only on presses)
}

// Text_Event carries typed text (layout- and modifier-aware), separate from
// Key_Event so UI text fields and game controls don't interfere.
Text_Event :: struct {
	char: rune,
}

// Mouse positions are in framebuffer pixels from the top-left corner.
Mouse_Move_Event :: struct {
	x, y: f32,
}

Mouse_Button_Event :: struct {
	button:  Mouse_Button,
	pressed: bool,
	x, y:    f32,
}

// Mouse_Delta_Event is relative motion while the mouse is captured (pixels;
// unaccelerated where the OS provides it). Captured, the cursor is hidden and
// held inside the window, and no Mouse_Move_Events arrive.
Mouse_Delta_Event :: struct {
	dx, dy: f32,
}

Mouse_Wheel_Event :: struct {
	dx, dy: f32, // notches; positive dy scrolls up / away from the user
}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
	X1,
	X2,
}

// Key names a physical-ish key position in the US layout sense for letters
// and digits; text input goes through Text_Event instead.
Key :: enum u8 {
	Unknown,
	A,
	B,
	C,
	D,
	E,
	F,
	G,
	H,
	I,
	J,
	K,
	L,
	M,
	N,
	O,
	P,
	Q,
	R,
	S,
	T,
	U,
	V,
	W,
	X,
	Y,
	Z,
	Num_0,
	Num_1,
	Num_2,
	Num_3,
	Num_4,
	Num_5,
	Num_6,
	Num_7,
	Num_8,
	Num_9,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
	Escape,
	Enter,
	Tab,
	Backspace,
	Space,
	Grave,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
	Delete,
	Left_Shift,
	Right_Shift,
	Left_Control,
	Right_Control,
	Left_Alt,
	Right_Alt,
}

// window_open creates and shows the window. Backends implement
// native_open(w, title) and fill w.width/w.height.
window_open :: proc(
	w: ^Window,
	title: string,
	width, height: i32,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	w^ = {}
	w.events = make([dynamic]Event, 0, 64, allocator, loc)
	w.width, w.height = width, height
	w.focused = true
	if !native_open(w, title) {
		delete(w.events)
		return false
	}
	return true
}

window_close :: proc(w: ^Window) {
	set_keep_awake(w, false)
	native_close(w)
	delete(w.events)
	w^ = {}
}

// poll_events gathers everything that happened since the last call into
// w.events (also returned) without blocking.
poll_events :: proc(w: ^Window) -> []Event {
	clear(&w.events)
	native_poll(w)
	return w.events[:]
}

// wait_events blocks until at least one event arrives (used while minimized).
wait_events :: proc(w: ^Window) -> []Event {
	clear(&w.events)
	native_wait(w)
	native_poll(w)
	return w.events[:]
}

// set_mouse_captured hides the cursor and turns mouse motion into
// Mouse_Delta_Events (mouse look), or ends that. The capture is released
// while the window is unfocused and comes back with focus.
set_mouse_captured :: proc(w: ^Window, captured: bool) {
	if w.mouse_captured == captured {return}
	w.mouse_captured = captured
	native_set_mouse_captured(w, captured && w.focused)
}

// set_fullscreen makes the window cover its monitor without a frame, or
// gives it its frame and place back. The size changes arrive as
// Resize_Events.
set_fullscreen :: proc(w: ^Window, fullscreen: bool) {
	if w.fullscreen == fullscreen {return}
	w.fullscreen = fullscreen
	native_set_fullscreen(w, fullscreen)
}

// set_keep_awake keeps the screen on (no screensaver, no display sleep)
// while playing, or gives it back to the OS's idle rules. Best effort: where
// the OS offers no way, it logs so and does nothing.
set_keep_awake :: proc(w: ^Window, on: bool) {
	if w.keep_awake == on {return}
	w.keep_awake = on
	native_set_keep_awake(w, on)
}

// vulkan_instance_extensions lists the instance extensions the surface needs.
vulkan_instance_extensions :: proc() -> []cstring {
	return native_vulkan_instance_extensions()
}

vulkan_create_surface :: proc(w: ^Window, instance: vk.Instance) -> (vk.SurfaceKHR, bool) {
	return native_vulkan_create_surface(w, instance)
}

// vulkan_loader_name is the Vulkan loader library to open at runtime.
vulkan_loader_name :: proc() -> string {
	return VULKAN_LOADER
}

@(private)
push_event :: proc(w: ^Window, e: Event) {
	append(&w.events, e)
	#partial switch v in e {
	case Resize_Event:
		w.width, w.height = v.width, v.height
	case Focus_Event:
		w.focused = v.focused
		if w.mouse_captured {native_set_mouse_captured(w, v.focused)}
	}
}
