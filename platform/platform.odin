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

// Key_Event: key is where the key is on the keyboard (bindings: WASD stays
// together on any layout); symbol is what the layout says it is (shortcuts:
// Ctrl+Z is the key marked Z).
Key_Event :: struct {
	key:     Key,
	symbol:  Key,
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

// Key: a key's place on the keyboard, named by what a US keyboard prints
// there (key_symbol says what the player's layout prints); text input goes
// through Text_Event instead. The mouse buttons come last, so a binding can
// name one (their events stay Mouse_Button_Events).
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
	Minus,
	Equals,
	Left_Bracket,
	Right_Bracket,
	Backslash,
	Semicolon,
	Apostrophe,
	Comma,
	Period,
	Slash,
	Caps_Lock,
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
	Mouse_Left,
	Mouse_Right,
	Mouse_Middle,
	Mouse_4,
	Mouse_5,
}

// MOUSE_KEYS: each mouse button as a Key (bindings).
MOUSE_KEYS := [Mouse_Button]Key {
	.Left   = .Mouse_Left,
	.Right  = .Mouse_Right,
	.Middle = .Mouse_Middle,
	.X1     = .Mouse_4,
	.X2     = .Mouse_5,
}

// SCANCODES: each key's PC scan code (set 1, which Linux's evdev codes
// follow): 0xE0xx for the extended ones; 0 for none.
@(rodata)
SCANCODES := [Key]u16 {
	.Unknown       = 0,
	.Escape        = 0x01,
	.Num_1         = 0x02,
	.Num_2         = 0x03,
	.Num_3         = 0x04,
	.Num_4         = 0x05,
	.Num_5         = 0x06,
	.Num_6         = 0x07,
	.Num_7         = 0x08,
	.Num_8         = 0x09,
	.Num_9         = 0x0A,
	.Num_0         = 0x0B,
	.Minus         = 0x0C,
	.Equals        = 0x0D,
	.Backspace     = 0x0E,
	.Tab           = 0x0F,
	.Q             = 0x10,
	.W             = 0x11,
	.E             = 0x12,
	.R             = 0x13,
	.T             = 0x14,
	.Y             = 0x15,
	.U             = 0x16,
	.I             = 0x17,
	.O             = 0x18,
	.P             = 0x19,
	.Left_Bracket  = 0x1A,
	.Right_Bracket = 0x1B,
	.Enter         = 0x1C,
	.Left_Control  = 0x1D,
	.A             = 0x1E,
	.S             = 0x1F,
	.D             = 0x20,
	.F             = 0x21,
	.G             = 0x22,
	.H             = 0x23,
	.J             = 0x24,
	.K             = 0x25,
	.L             = 0x26,
	.Semicolon     = 0x27,
	.Apostrophe    = 0x28,
	.Grave         = 0x29,
	.Left_Shift    = 0x2A,
	.Backslash     = 0x2B,
	.Z             = 0x2C,
	.X             = 0x2D,
	.C             = 0x2E,
	.V             = 0x2F,
	.B             = 0x30,
	.N             = 0x31,
	.M             = 0x32,
	.Comma         = 0x33,
	.Period        = 0x34,
	.Slash         = 0x35,
	.Right_Shift   = 0x36,
	.Left_Alt      = 0x38,
	.Space         = 0x39,
	.Caps_Lock     = 0x3A,
	.F1            = 0x3B,
	.F2            = 0x3C,
	.F3            = 0x3D,
	.F4            = 0x3E,
	.F5            = 0x3F,
	.F6            = 0x40,
	.F7            = 0x41,
	.F8            = 0x42,
	.F9            = 0x43,
	.F10           = 0x44,
	.F11           = 0x57,
	.F12           = 0x58,
	.Right_Control = 0xE01D,
	.Right_Alt     = 0xE038,
	.Home          = 0xE047,
	.Up            = 0xE048,
	.Page_Up       = 0xE049,
	.Left          = 0xE04B,
	.Right         = 0xE04D,
	.End           = 0xE04F,
	.Down          = 0xE050,
	.Page_Down     = 0xE051,
	.Insert        = 0xE052,
	.Delete        = 0xE053,
	.Mouse_Left    = 0,
	.Mouse_Right   = 0,
	.Mouse_Middle  = 0,
	.Mouse_4       = 0,
	.Mouse_5       = 0,
}

// key_from_scancode: the key at scan code code (extended: 0xE0 prefixed).
key_from_scancode :: proc(code: u32, extended: bool) -> Key {
	want := u16(code) | (0xE000 if extended else 0)
	if code == 0x1C && extended {return .Enter} 	// the keypad's Enter
	for c, k in SCANCODES {
		if c == want && c != 0 {return k}
	}
	return .Unknown
}

// key_symbol: the key the player's layout puts at key's place (what to call
// it on screen: the Z key of a French keyboard sits where W is here).
key_symbol :: proc(w: ^Window, key: Key) -> Key {
	printed := key >= .A && key <= .Num_9 || key >= .Grave && key <= .Slash
	if !printed || w == nil {return key}
	if k := native_key_symbol(w, key); k != .Unknown {return k}
	return key
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
