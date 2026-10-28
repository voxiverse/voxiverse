package platform

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "core:sys/posix"
import vk "vendor:vulkan"

// macOS backend: AppKit through core:sys/darwin/Foundation (the Objective-C
// runtime through intrinsics.objc_send where it has no binding, as
// pad_darwin.odin does) and a CAMetalLayer under MoltenVK. The two classes
// AppKit needs (the delegate and the view) are made at run time; no
// Objective-C file, nothing linked that macOS does not ship.
//
// One window per process: the callbacks AppKit makes reach it through
// `active`.

@(require) foreign import _quartzcore "system:QuartzCore.framework"
foreign import carbon "system:Carbon.framework"
foreign import coregraphics "system:CoreGraphics.framework"
foreign import iokit "system:IOKit.framework"
foreign import corefoundation "system:CoreFoundation.framework"

@(private = "file")
msg :: intrinsics.objc_send

Native_Window :: struct {
	app:           ^NS.Object, // NSApplication
	window:        ^NS.Object, // NSWindow
	view:          ^NS.Object, // the NSView subclass, layer-backed
	layer:         ^NS.Object, // its CAMetalLayer
	delegate:      ^NS.Object, // application and window delegate
	scale:         f64, // backing pixels per point
	captured:      bool, // cursor hidden and frozen, deltas reported
	cursor_hidden: bool,
	saved_cursor:  NS.Point, // global position to return to on release
	held_mods:     bit_set[Key], // modifier keys down (released on losing focus)
	buttons:       bit_set[Mouse_Button], // buttons pressed inside the window
}

@(private = "file")
active: ^Window // the one window, for AppKit's callbacks

@(private = "file")
callback_ctx: runtime.Context // what the callbacks run in

// The Vulkan driver is MoltenVK's libMoltenVK.dylib, opened by path: inside
// the .app (Contents/Frameworks, beside Contents/MacOS), beside the
// executable, or where `build` unpacked it. Nothing else is looked for.
@(private)
native_vulkan_loader_name :: proc() -> string {
	dll :: "libMoltenVK.dylib"
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		candidates := [3][]string {
			{dir, "..", "Frameworks", dll},
			{dir, dll},
			{dir, "tools", "moltenvk", dll}, // build/tools/moltenvk, beside build/voxiverse
		}
		for parts in candidates {
			path, jerr := filepath.join(parts, context.temp_allocator)
			if jerr == nil && os.exists(path) {
				return strings.clone(path) // (the GPU layer keeps it for the run)
			}
		}
	}
	log.error("platform the Vulkan driver (MoltenVK) was not found next to the game; reinstall")
	return dll
}

// MoltenVK's descriptor indexing (the bindless textures) needs Metal argument
// buffers; its configuration is read at the first Vulkan call. Left alone if
// the player set it.
@(private = "file")
configure_moltenvk :: proc() {
	posix.setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", false)
}

@(private = "file")
nobj: ^NS.Object // nil, typed for a message argument

// class_of: a class by name, as a message receiver. (The class types of
// core:sys/darwin/Foundation as receivers make the compiler fail on some
// object builds of the test package, so classes are looked up here.)
@(private = "file")
class_of :: proc(name: cstring) -> ^NS.Object {
	return (^NS.Object)(NS.objc_lookUpClass(name))
}

@(private = "file")
as_object :: proc(cls: NS.Class) -> ^NS.Object {
	return (^NS.Object)(cls)
}

@(private = "file")
ns_string :: proc(s: string) -> ^NS.String {
	c := strings.clone_to_cstring(s, context.temp_allocator)
	return NS.String.alloc()->initWithCString(c, .UTF8)
}

// ---------------------------------------------------------------------------
// Keys

// MAC_KEYCODES: NSEvent.keyCode (Carbon's kVK_* numbers) to the key; Unknown
// for the rest. Both Command keys count as Control, as the UI's shortcuts
// (Ctrl+Z) read it: on a Mac the shortcut key is Command.
@(private = "file", rodata)
MAC_KEYCODES := [128]Key {
	0x00 = .A, // kVK_ANSI_A
	0x01 = .S, // kVK_ANSI_S
	0x02 = .D, // kVK_ANSI_D
	0x03 = .F, // kVK_ANSI_F
	0x04 = .H, // kVK_ANSI_H
	0x05 = .G, // kVK_ANSI_G
	0x06 = .Z, // kVK_ANSI_Z
	0x07 = .X, // kVK_ANSI_X
	0x08 = .C, // kVK_ANSI_C
	0x09 = .V, // kVK_ANSI_V
	0x0B = .B, // kVK_ANSI_B
	0x0C = .Q, // kVK_ANSI_Q
	0x0D = .W, // kVK_ANSI_W
	0x0E = .E, // kVK_ANSI_E
	0x0F = .R, // kVK_ANSI_R
	0x10 = .Y, // kVK_ANSI_Y
	0x11 = .T, // kVK_ANSI_T
	0x12 = .Num_1, // kVK_ANSI_1
	0x13 = .Num_2, // kVK_ANSI_2
	0x14 = .Num_3, // kVK_ANSI_3
	0x15 = .Num_4, // kVK_ANSI_4
	0x16 = .Num_6, // kVK_ANSI_6
	0x17 = .Num_5, // kVK_ANSI_5
	0x18 = .Equals, // kVK_ANSI_Equal
	0x19 = .Num_9, // kVK_ANSI_9
	0x1A = .Num_7, // kVK_ANSI_7
	0x1B = .Minus, // kVK_ANSI_Minus
	0x1C = .Num_8, // kVK_ANSI_8
	0x1D = .Num_0, // kVK_ANSI_0
	0x1E = .Right_Bracket, // kVK_ANSI_RightBracket
	0x1F = .O, // kVK_ANSI_O
	0x20 = .U, // kVK_ANSI_U
	0x21 = .Left_Bracket, // kVK_ANSI_LeftBracket
	0x22 = .I, // kVK_ANSI_I
	0x23 = .P, // kVK_ANSI_P
	0x24 = .Enter, // kVK_Return
	0x25 = .L, // kVK_ANSI_L
	0x26 = .J, // kVK_ANSI_J
	0x27 = .Apostrophe, // kVK_ANSI_Quote
	0x28 = .K, // kVK_ANSI_K
	0x29 = .Semicolon, // kVK_ANSI_Semicolon
	0x2A = .Backslash, // kVK_ANSI_Backslash
	0x2B = .Comma, // kVK_ANSI_Comma
	0x2C = .Slash, // kVK_ANSI_Slash
	0x2D = .N, // kVK_ANSI_N
	0x2E = .M, // kVK_ANSI_M
	0x2F = .Period, // kVK_ANSI_Period
	0x30 = .Tab, // kVK_Tab
	0x31 = .Space, // kVK_Space
	0x32 = .Grave, // kVK_ANSI_Grave
	0x33 = .Backspace, // kVK_Delete
	0x35 = .Escape, // kVK_Escape
	0x36 = .Right_Control, // kVK_RightCommand
	0x37 = .Left_Control, // kVK_Command
	0x38 = .Left_Shift, // kVK_Shift
	0x39 = .Caps_Lock, // kVK_CapsLock
	0x3A = .Left_Alt, // kVK_Option
	0x3B = .Left_Control, // kVK_Control
	0x3C = .Right_Shift, // kVK_RightShift
	0x3D = .Right_Alt, // kVK_RightOption
	0x3E = .Right_Control, // kVK_RightControl
	0x4C = .Enter, // kVK_ANSI_KeypadEnter
	0x60 = .F5, // kVK_F5
	0x61 = .F6, // kVK_F6
	0x62 = .F7, // kVK_F7
	0x63 = .F3, // kVK_F3
	0x64 = .F8, // kVK_F8
	0x65 = .F9, // kVK_F9
	0x67 = .F11, // kVK_F11
	0x6D = .F10, // kVK_F10
	0x6F = .F12, // kVK_F12
	0x72 = .Insert, // kVK_Help (the Insert position)
	0x73 = .Home, // kVK_Home
	0x74 = .Page_Up, // kVK_PageUp
	0x75 = .Delete, // kVK_ForwardDelete
	0x76 = .F4, // kVK_F4
	0x77 = .End, // kVK_End
	0x78 = .F2, // kVK_F2
	0x79 = .Page_Down, // kVK_PageDown
	0x7A = .F1, // kVK_F1
	0x7B = .Left, // kVK_LeftArrow
	0x7C = .Right, // kVK_RightArrow
	0x7D = .Down, // kVK_DownArrow
	0x7E = .Up, // kVK_UpArrow
}

// The device-dependent modifier bits of NSEvent.modifierFlags (IOKit's
// NX_DEVICE*KEYMASK), one per modifier key: a flagsChanged event says which
// key it was, and whether it is down is whether its bit is set.
@(private = "file")
modifier_mask :: proc(keycode: u16) -> u32 {
	switch keycode {
	case 0x38:
		return 0x2 // left shift
	case 0x3C:
		return 0x4 // right shift
	case 0x3B:
		return 0x1 // left control
	case 0x3E:
		return 0x2000 // right control
	case 0x3A:
		return 0x20 // left option
	case 0x3D:
		return 0x40 // right option
	case 0x37:
		return 0x8 // left command
	case 0x36:
		return 0x10 // right command
	case 0x39:
		return 0x10000 // caps lock (the device-independent bit)
	}
	return 0
}

// key_for_char: the key a typed character is printed on a US keyboard.
@(private = "file")
key_for_char :: proc(r: rune) -> Key {
	switch r {
	case 'a' ..= 'z':
		return Key(int(Key.A) + int(r - 'a'))
	case 'A' ..= 'Z':
		return Key(int(Key.A) + int(r - 'A'))
	case '1' ..= '9':
		return Key(int(Key.Num_1) + int(r - '1'))
	case '0':
		return .Num_0
	case '`':
		return .Grave
	case '-':
		return .Minus
	case '=':
		return .Equals
	case '[':
		return .Left_Bracket
	case ']':
		return .Right_Bracket
	case '\\':
		return .Backslash
	case ';':
		return .Semicolon
	case '\'':
		return .Apostrophe
	case ',':
		return .Comma
	case '.':
		return .Period
	case '/':
		return .Slash
	}
	return .Unknown
}

@(private = "file")
is_printing_key :: proc(key: Key) -> bool {
	return key >= .A && key <= .Num_9 || key >= .Grave && key <= .Slash
}

@(private = "file", default_calling_convention = "c")
foreign carbon {
	TISCopyCurrentKeyboardLayoutInputSource :: proc() -> rawptr ---
	TISGetInputSourceProperty :: proc(source: rawptr, key: rawptr) -> rawptr ---
	LMGetKbdType :: proc() -> u8 ---
	UCKeyTranslate :: proc(layout: rawptr, key_code: u16, action: u16, modifiers: u32, keyboard_type: u32, options: u32, dead_keys: ^u32, max_length: uint, actual_length: ^uint, text: [^]u16) -> i32 ---
	kTISPropertyUnicodeKeyLayoutData: rawptr
}

// The layout's character for a physical key, without modifiers and without
// dead-key state: what the key is "marked" as.
@(private)
native_key_symbol :: proc(w: ^Window, key: Key) -> Key {
	keycode := -1
	for k, code in MAC_KEYCODES {
		if k == key {
			keycode = code
			break
		}
	}
	if keycode < 0 {return .Unknown}
	source := TISCopyCurrentKeyboardLayoutInputSource()
	if source == nil {return .Unknown}
	defer CFRelease(source)
	data := TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
	if data == nil {return .Unknown}
	layout := CFDataGetBytePtr(data)
	dead: u32
	length: uint
	text: [4]u16
	// kUCKeyActionDown 0; no modifiers; kUCKeyTranslateNoDeadKeysMask 1
	status := UCKeyTranslate(
		layout,
		u16(keycode),
		0,
		0,
		u32(LMGetKbdType()),
		1,
		&dead,
		len(text),
		&length,
		raw_data(text[:]),
	)
	if status != 0 || length == 0 {return .Unknown}
	return key_for_char(rune(text[0]))
}

// ---------------------------------------------------------------------------
// The window

@(private = "file", default_calling_convention = "c")
foreign coregraphics {
	CGSessionCopyCurrentDictionary :: proc() -> rawptr ---
	CGAssociateMouseAndMouseCursorPosition :: proc(connected: u32) -> i32 ---
	CGWarpMouseCursorPosition :: proc(p: NS.Point) -> i32 ---
	CGEventCreate :: proc(source: rawptr) -> rawptr ---
	CGEventGetLocation :: proc(event: rawptr) -> NS.Point ---
	CGMainDisplayID :: proc() -> u32 ---
	CGDisplayHideCursor :: proc(display: u32) -> i32 ---
	CGDisplayShowCursor :: proc(display: u32) -> i32 ---
}

@(private = "file")
Range :: struct {
	location, length: NS.UInteger,
}

@(private = "file")
NOT_FOUND :: NS.UInteger(max(int))

@(private)
native_open :: proc(w: ^Window, title: string) -> bool {
	// Without a login session (an SSH shell) AppKit has nothing to draw on
	// and aborts; say so instead.
	session := CGSessionCopyCurrentDictionary()
	if session == nil {
		log.error("platform no window server: run the game from the desktop")
		return false
	}
	CFRelease(session)

	n := &w.native
	active = w
	callback_ctx = context
	configure_moltenvk()

	n.app = msg(^NS.Object, class_of("NSApplication"), "sharedApplication")
	msg(NS.BOOL, n.app, "setActivationPolicy:", NS.ActivationPolicy.Regular)

	delegate_class := make_delegate_class()
	view_class := make_view_class()
	if delegate_class == nil || view_class == nil {
		log.error("platform could not register the Objective-C classes")
		return false
	}
	n.delegate = msg(^NS.Object, msg(^NS.Object, as_object(delegate_class), "alloc"), "init")
	msg(nil, n.app, "setDelegate:", n.delegate)
	make_menu(n.app, title)
	msg(nil, n.app, "finishLaunching")

	// Centred, at the requested size in points, at least 640x360 and no
	// bigger than the screen's usable area.
	screen := msg(^NS.Object, class_of("NSScreen"), "mainScreen")
	visible := msg(NS.Rect, screen, "visibleFrame")
	width := clamp(f64(w.width), 640, max(640, f64(visible.width)))
	height := clamp(f64(w.height), 360, max(360, f64(visible.height)))
	style := NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}
	rect := NS.Rect{{0, 0}, {NS.Float(width), NS.Float(height)}}
	n.window = msg(
		^NS.Object,
		msg(^NS.Object, class_of("NSWindow"), "alloc"),
		"initWithContentRect:styleMask:backing:defer:",
		rect,
		style,
		NS.UInteger(2), // NSBackingStoreBuffered
		NS.BOOL(false),
	)
	if n.window == nil {
		log.error("platform could not create the window")
		return false
	}
	msg(nil, n.window, "setReleasedWhenClosed:", NS.BOOL(false))
	msg(nil, n.window, "setTitle:", ns_string(title))
	msg(nil, n.window, "setDelegate:", n.delegate)
	msg(nil, n.window, "setAcceptsMouseMovedEvents:", NS.BOOL(true))
	msg(nil, n.window, "setMinSize:", NS.Size{640, 360})
	// The green button and Enter Full Screen: a space of its own.
	msg(nil, n.window, "setCollectionBehavior:", NS.UInteger(1 << 7))
	msg(nil, n.window, "center")

	n.view = msg(
		^NS.Object,
		msg(^NS.Object, as_object(view_class), "alloc"),
		"initWithFrame:",
		NS.Rect{{0, 0}, {NS.Float(width), NS.Float(height)}},
	)
	n.layer = msg(^NS.Object, class_of("CAMetalLayer"), "layer")
	if n.layer == nil {
		log.error("platform no CAMetalLayer (QuartzCore is missing)")
		return false
	}
	msg(nil, n.view, "setLayer:", n.layer)
	msg(nil, n.view, "setWantsLayer:", NS.BOOL(true))
	msg(nil, n.window, "setContentView:", n.view)
	msg(NS.BOOL, n.window, "makeFirstResponder:", n.view)
	msg(nil, n.window, "makeKeyAndOrderFront:", nobj)
	msg(nil, n.app, "activateIgnoringOtherApps:", NS.BOOL(true))

	// Pixels (the layer's drawable and what the game renders in).
	w.width, w.height = 0, 0
	report_size(w)
	return true
}

@(private)
native_close :: proc(w: ^Window) {
	n := &w.native
	if n.captured {native_set_mouse_captured(w, false)}
	if n.window != nil {
		msg(nil, n.window, "setDelegate:", nobj)
		msg(nil, n.window, "close")
	}
	if n.app != nil {msg(nil, n.app, "setDelegate:", nobj)}
	active = nil
}

// report_size gives the framebuffer size, content size times the backing
// scale, as a Resize_Event when it changed (0x0 while minimized), and keeps
// the layer's drawable in step.
@(private = "file")
report_size :: proc(w: ^Window) {
	n := &w.native
	if n.window == nil || n.view == nil {return}
	n.scale = f64(msg(NS.Float, n.window, "backingScaleFactor"))
	bounds := msg(NS.Rect, n.view, "bounds")
	pw, ph := i32(f64(bounds.width) * n.scale), i32(f64(bounds.height) * n.scale)
	if msg(NS.BOOL, n.window, "isMiniaturized") {pw, ph = 0, 0}
	if pw > 0 && ph > 0 {
		msg(nil, n.layer, "setContentsScale:", NS.Float(n.scale))
		msg(nil, n.layer, "setDrawableSize:", NS.Size{NS.Float(pw), NS.Float(ph)})
	}
	if pw != w.width || ph != w.height {push_event(w, Resize_Event{pw, ph})}
}

// ---------------------------------------------------------------------------
// The delegate (application and window) and the view

@(private = "file")
add_method :: proc(cls: NS.Class, name: cstring, imp: rawptr, types: cstring) {
	NS.class_addMethod(cls, NS.sel_registerName(name), auto_cast imp, types)
}

@(private = "file")
make_delegate_class :: proc() -> NS.Class {
	cls := NS.objc_allocateClassPair(NS.objc_lookUpClass("NSObject"), "VoxiverseDelegate", 0)
	if cls == nil {return NS.objc_lookUpClass("VoxiverseDelegate")} 	// registered already
	// Quitting (Cmd+Q, the Dock's Quit) asks the game, as the close button
	// elsewhere: it decides when to stop.
	add_method(
		cls,
		"applicationShouldTerminate:",
		rawptr(
			proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.Object) -> NS.UInteger {
				context = callback_ctx
				if active != nil {active.close_requested = true}
				return 0 // NSTerminateCancel
			},
		),
		"Q@:@",
	)
	add_method(
		cls,
		"applicationDidBecomeActive:",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL, note: ^NS.Object) {
				context = callback_ctx
				if active != nil {push_event(active, Focus_Event{true})}
			}),
		"v@:@",
	)
	add_method(
		cls,
		"applicationDidResignActive:",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL, note: ^NS.Object) {
				context = callback_ctx
				if active == nil {return}
				release_held_modifiers(active)
				push_event(active, Focus_Event{false})
			}),
		"v@:@",
	)
	add_method(
		cls,
		"windowShouldClose:",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.Object) -> NS.BOOL {
				context = callback_ctx
				if active != nil {active.close_requested = true}
				return false
			}),
		"B@:@",
	)
	resized := rawptr(proc "c" (self: NS.id, cmd: NS.SEL, note: ^NS.Object) {
			context = callback_ctx
			if active != nil {report_size(active)}
		})
	add_method(cls, "windowDidResize:", resized, "v@:@")
	add_method(cls, "windowDidChangeBackingProperties:", resized, "v@:@")
	add_method(cls, "windowDidMiniaturize:", resized, "v@:@")
	add_method(cls, "windowDidDeminiaturize:", resized, "v@:@")
	add_method(
		cls,
		"windowDidEnterFullScreen:",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL, note: ^NS.Object) {
				context = callback_ctx
				if active == nil {return}
				active.fullscreen = true
				report_size(active)
			}),
		"v@:@",
	)
	add_method(
		cls,
		"windowDidExitFullScreen:",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL, note: ^NS.Object) {
				context = callback_ctx
				if active == nil {return}
				active.fullscreen = false
				report_size(active)
			}),
		"v@:@",
	)
	NS.objc_registerClassPair(cls)
	return cls
}

@(private = "file")
view_key_down :: proc(view: ^NS.Object, event: ^NS.Event) {
	// Command-keys are shortcuts, not text.
	if .Command in event->modifierFlags() {return}
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	events := msg(^NS.Object, class_of("NSArray"), "arrayWithObject:", event)
	msg(nil, view, "interpretKeyEvents:", events)
}

@(private = "file")
empty_array :: proc() -> ^NS.Object {
	return msg(^NS.Object, class_of("NSArray"), "array")
}

@(private = "file")
view_insert_text :: proc(text: ^NS.Object) {
	if active == nil {return}
	str := text
	if msg(NS.BOOL, text, "isKindOfClass:", class_of("NSAttributedString")) {
		str = msg(^NS.Object, text, "string")
	}
	for r in string(msg(cstring, str, "UTF8String")) {
		// Not control characters, nor the private-use codes
		// AppKit gives the arrow and function keys.
		if r < ' ' || r == 0x7F || r >= 0xF700 && r <= 0xF8FF {continue}
		push_event(active, Text_Event{r})
	}
}

// The view: first responder, key text through NSTextInputClient. Keys, the
// mouse and the wheel are read from the event queue in native_poll; the view
// only turns keyDown into text.
@(private = "file")
make_view_class :: proc() -> NS.Class {
	cls := NS.objc_allocateClassPair(NS.objc_lookUpClass("NSView"), "VoxiverseView", 0)
	if cls == nil {return NS.objc_lookUpClass("VoxiverseView")}
	add_method(
		cls,
		"acceptsFirstResponder",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL) -> NS.BOOL {return true}),
		"B@:",
	)
	add_method(cls, "keyDown:", rawptr(proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
			context = callback_ctx
			view_key_down((^NS.Object)(self), event)
		}), "v@:@")
	// Nothing to do for these; answering stops AppKit's beep.
	nothing := rawptr(proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Object) {})
	add_method(cls, "keyUp:", nothing, "v@:@")
	add_method(cls, "flagsChanged:", nothing, "v@:@")
	add_method(cls, "doCommandBySelector:", nothing, "v@:^v")

	// NSTextInputClient.
	add_method(
		cls,
		"insertText:replacementRange:",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL, text: ^NS.Object, range: Range) {
				context = callback_ctx
				view_insert_text(text)
			}),
		"v@:@{_NSRange=QQ}",
	)
	// Marked (composition) text is accepted and ignored; dead keys and
	// Option combinations arrive finished through insertText.
	add_method(
		cls,
		"setMarkedText:selectedRange:replacementRange:",
		rawptr(
			proc "c" (
				self: NS.id,
				cmd: NS.SEL,
				text: ^NS.Object,
				selected: Range,
				replacement: Range,
			) {},
		),
		"v@:@{_NSRange=QQ}{_NSRange=QQ}",
	)
	add_method(cls, "unmarkText", rawptr(proc "c" (self: NS.id, cmd: NS.SEL) {}), "v@:")
	add_method(
		cls,
		"hasMarkedText",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL) -> NS.BOOL {return false}),
		"B@:",
	)
	none := rawptr(proc "c" (self: NS.id, cmd: NS.SEL) -> Range {return {NOT_FOUND, 0}})
	add_method(cls, "selectedRange", none, "{_NSRange=QQ}@:")
	add_method(cls, "markedRange", none, "{_NSRange=QQ}@:")
	add_method(
		cls,
		"attributedSubstringForProposedRange:actualRange:",
		rawptr(
			proc "c" (
				self: NS.id,
				cmd: NS.SEL,
				range: Range,
				actual: ^Range,
			) -> ^NS.Object {return nil},
		),
		"@@:{_NSRange=QQ}^{_NSRange=QQ}",
	)
	add_method(
		cls,
		"validAttributesForMarkedText",
		rawptr(proc "c" (self: NS.id, cmd: NS.SEL) -> ^NS.Object {
				context = callback_ctx
				return empty_array()
			}),
		"@@:",
	)
	add_method(
		cls,
		"firstRectForCharacterRange:actualRange:",
		rawptr(
			proc "c" (
				self: NS.id,
				cmd: NS.SEL,
				range: Range,
				actual: ^Range,
			) -> NS.Rect {return {}},
		),
		"{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}",
	)
	add_method(
		cls,
		"characterIndexForPoint:",
		rawptr(
			proc "c" (self: NS.id, cmd: NS.SEL, point: NS.Point) -> NS.UInteger {return NOT_FOUND},
		),
		"Q@:{CGPoint=dd}",
	)
	if proto := NS.objc_getProtocol("NSTextInputClient"); proto != nil {
		NS.class_addProtocol(cls, proto)
	}
	NS.objc_registerClassPair(cls)
	return cls
}

// make_menu: Voxiverse (About, Hide, Quit) and Window (Minimize, Enter Full
// Screen). The actions go to the application and the key window.
@(private = "file")
make_menu :: proc(app: ^NS.Object, title: string) {
	new_menu :: proc(name: string) -> ^NS.Object {
		return msg(
			^NS.Object,
			msg(^NS.Object, class_of("NSMenu"), "alloc"),
			"initWithTitle:",
			ns_string(name),
		)
	}
	add_item :: proc(menu: ^NS.Object, name: string, action: cstring, key: string) -> ^NS.Object {
		return msg(
			^NS.Object,
			menu,
			"addItemWithTitle:action:keyEquivalent:",
			ns_string(name),
			NS.sel_registerName(action) if action != "" else nil,
			ns_string(key),
		)
	}
	separator :: proc(menu: ^NS.Object) {
		msg(nil, menu, "addItem:", msg(^NS.Object, class_of("NSMenuItem"), "separatorItem"))
	}
	named :: proc(verb, title: string) -> string {
		return strings.concatenate({verb, " ", title}, context.temp_allocator)
	}

	bar := new_menu("")
	app_menu := new_menu(title)
	add_item(app_menu, named("About", title), "orderFrontStandardAboutPanel:", "")
	separator(app_menu)
	add_item(app_menu, named("Hide", title), "hide:", "h")
	separator(app_menu)
	add_item(app_menu, named("Quit", title), "terminate:", "q")
	app_item := add_item(bar, title, "", "")
	msg(nil, app_item, "setSubmenu:", app_menu)

	window_menu := new_menu("Window")
	add_item(window_menu, "Minimize", "performMiniaturize:", "m")
	full := add_item(window_menu, "Enter Full Screen", "toggleFullScreen:", "f")
	// Ctrl+Cmd+F, as in other applications.
	msg(nil, full, "setKeyEquivalentModifierMask:", NS.EventModifierFlags{.Control, .Command})
	window_item := add_item(bar, "Window", "", "")
	msg(nil, window_item, "setSubmenu:", window_menu)

	msg(nil, app, "setMainMenu:", bar)
	msg(nil, app, "setWindowsMenu:", window_menu)
}

// ---------------------------------------------------------------------------
// Events

// native_poll takes every queued event, makes Events of the keys, mouse and
// wheel, and hands them on to AppKit too (title bar, menu shortcuts, text).
@(private)
native_poll :: proc(w: ^Window) {
	n := &w.native
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	past := msg(^NS.Object, class_of("NSDate"), "distantPast")
	for {
		event := msg(
			^NS.Event,
			n.app,
			"nextEventMatchingMask:untilDate:inMode:dequeue:",
			NS.EventMaskAny,
			past,
			NS.DefaultRunLoopMode,
			NS.BOOL(true),
		)
		if event == nil {break}
		handle_event(w, event)
		msg(nil, n.app, "sendEvent:", event)
	}
	msg(nil, n.app, "updateWindows")
}

// native_wait blocks until an event is queued (looking, not taking it: the
// poll after it does), or a tenth of a second has passed.
@(private)
native_wait :: proc(w: ^Window) {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	until := msg(^NS.Object, class_of("NSDate"), "dateWithTimeIntervalSinceNow:", f64(0.1))
	msg(
		^NS.Event,
		w.native.app,
		"nextEventMatchingMask:untilDate:inMode:dequeue:",
		NS.EventMaskAny,
		until,
		NS.DefaultRunLoopMode,
		NS.BOOL(false),
	)
}

@(private = "file")
handle_event :: proc(w: ^Window, event: ^NS.Event) {
	n := &w.native
	#partial switch event->type() {
	case .KeyDown:
		key := MAC_KEYCODES[event->keyCode() & 0x7F]
		if key == .Unknown {break}
		symbol := key
		if chars := event->charactersIgnoringModifiers(); chars != nil && is_printing_key(key) {
			for r in string(msg(cstring, chars, "UTF8String")) {
				if s := key_for_char(r); s != .Unknown {symbol = s}
				break
			}
		}
		push_event(
			w,
			Key_Event {
				key = key,
				symbol = symbol,
				pressed = true,
				repeat = bool(event->isARepeat()),
			},
		)
	case .KeyUp:
		key := MAC_KEYCODES[event->keyCode() & 0x7F]
		if key == .Unknown {break}
		push_event(w, Key_Event{key = key, symbol = key, pressed = false})
	case .FlagsChanged:
		keycode := event->keyCode()
		key := MAC_KEYCODES[keycode & 0x7F]
		mask := modifier_mask(keycode)
		if key == .Unknown || mask == 0 {break}
		if key == .Caps_Lock {
			// The flag is the lock's state, not the key's: a tap.
			push_event(w, Key_Event{key = key, symbol = key, pressed = true})
			push_event(w, Key_Event{key = key, symbol = key, pressed = false})
			break
		}
		down := u32(transmute(NS.UInteger)event->modifierFlags()) & mask != 0
		if down == (key in n.held_mods) {break}
		if down {n.held_mods += {key}} else {n.held_mods -= {key}}
		push_event(w, Key_Event{key = key, symbol = key, pressed = down})
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged:
		if n.captured {
			scale := f32(n.scale)
			dx, dy := f32(event->deltaX()) * scale, f32(event->deltaY()) * scale
			if dx != 0 || dy != 0 {push_event(w, Mouse_Delta_Event{dx, dy})}
		} else if x, y, inside := mouse_position(w, event); inside {
			push_event(w, Mouse_Move_Event{x, y})
		}
	case .LeftMouseDown, .RightMouseDown, .OtherMouseDown:
		button := mouse_button(event)
		x, y, inside := mouse_position(w, event)
		if inside || n.captured {
			n.buttons += {button}
			push_event(w, Mouse_Button_Event{button, true, x, y})
		}
	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		button := mouse_button(event)
		if button in n.buttons {
			n.buttons -= {button}
			x, y, _ := mouse_position(w, event)
			push_event(w, Mouse_Button_Event{button, false, x, y})
		}
	case .ScrollWheel:
		_, _, inside := mouse_position(w, event)
		if !inside && !n.captured {break}
		dx, dy := f32(event->scrollingDeltaX()), f32(event->scrollingDeltaY())
		if event->hasPreciseScrollingDeltas() {
			// Trackpads count points: about this many to a wheel's notch.
			dx /= 16
			dy /= 16
		}
		if dx != 0 || dy != 0 {push_event(w, Mouse_Wheel_Event{dx, dy})}
	}
}

@(private = "file")
mouse_button :: proc(event: ^NS.Event) -> Mouse_Button {
	switch event->buttonNumber() {
	case 0:
		return .Left
	case 1:
		return .Right
	case 2:
		return .Middle
	case 3:
		return .X1
	}
	return .X2
}

// mouse_position: the event's place in framebuffer pixels from the top left
// of the view, and whether it is on the view (a click on the title bar is
// not the game's).
@(private = "file")
mouse_position :: proc(w: ^Window, event: ^NS.Event) -> (x, y: f32, inside: bool) {
	n := &w.native
	if rawptr(event->window()) != rawptr(n.window) {return 0, 0, false}
	p := event->locationInWindow()
	bounds := msg(NS.Rect, n.view, "bounds")
	x = f32(f64(p.x) * n.scale)
	y = f32((f64(bounds.height) - f64(p.y)) * n.scale)
	inside = p.x >= 0 && p.y >= 0 && p.x < bounds.width && p.y < bounds.height
	return
}

// release_held_modifiers: a modifier let go while another application had
// the keyboard would stay down for the game.
@(private = "file")
release_held_modifiers :: proc(w: ^Window) {
	for key in w.native.held_mods {
		push_event(w, Key_Event{key = key, symbol = key, pressed = false})
	}
	w.native.held_mods = {}
}

// ---------------------------------------------------------------------------
// Mouse capture, fullscreen

// Captured: the cursor hidden and no longer following the mouse (motion
// arrives as deltas), put back where it was on release.
@(private)
native_set_mouse_captured :: proc(w: ^Window, captured: bool) {
	n := &w.native
	if captured == n.captured {return}
	n.captured = captured
	if captured {
		if e := CGEventCreate(nil); e != nil {
			n.saved_cursor = CGEventGetLocation(e)
			CFRelease(e)
		}
		CGAssociateMouseAndMouseCursorPosition(0)
		if !n.cursor_hidden {
			CGDisplayHideCursor(CGMainDisplayID())
			n.cursor_hidden = true
		}
	} else {
		CGAssociateMouseAndMouseCursorPosition(1)
		CGWarpMouseCursorPosition(n.saved_cursor)
		if n.cursor_hidden {
			CGDisplayShowCursor(CGMainDisplayID())
			n.cursor_hidden = false
		}
	}
}

// The window's own full-screen space: the state follows the delegate's
// notifications (the green button works too).
@(private)
native_set_fullscreen :: proc(w: ^Window, fullscreen: bool) {
	n := &w.native
	if n.window == nil {return}
	style := msg(NS.WindowStyleMask, n.window, "styleMask")
	if (.FullScreen in style) != fullscreen {msg(nil, n.window, "toggleFullScreen:", nobj)}
}

// ---------------------------------------------------------------------------
// Vulkan

@(private)
native_vulkan_instance_extensions :: proc() -> []cstring {
	// (VK_KHR_portability_enumeration is added by the GPU layer where the
	// driver offers it.)
	@(static, rodata)
	extensions := [?]cstring {
		"VK_KHR_surface",
		"VK_EXT_metal_surface",
		"VK_KHR_get_physical_device_properties2",
	}
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
	info := vk.MetalSurfaceCreateInfoEXT {
		sType  = .METAL_SURFACE_CREATE_INFO_EXT,
		pLayer = cast(^vk.CAMetalLayer)w.native.layer,
	}
	if vk.CreateMetalSurfaceEXT(instance, &info, nil, &surface) != .SUCCESS {return 0, false}
	return surface, true
}

// ---------------------------------------------------------------------------
// Keep awake (an IOKit power assertion keeps the display awake while held)
// and the icon

@(private = "file")
CFStringRef :: rawptr

@(private = "file", default_calling_convention = "c")
foreign corefoundation {
	CFStringCreateWithCString :: proc(alloc: rawptr, s: cstring, encoding: u32) -> CFStringRef ---
	CFRelease :: proc(cf: rawptr) ---
	CFDataGetBytePtr :: proc(data: rawptr) -> rawptr ---
}

@(private = "file", default_calling_convention = "c")
foreign iokit {
	IOPMAssertionCreateWithName :: proc(kind: CFStringRef, level: u32, name: CFStringRef, id: ^u32) -> i32 ---
	IOPMAssertionRelease :: proc(id: u32) -> i32 ---
}

@(private = "file")
assertion: u32

@(private = "file")
keep_awake_warned: bool // a failure is told once per run

// The application's icon (the Dock's, also for a run from the terminal; the
// .app has Voxiverse.icns): the largest image offered, as an NSImage.
@(private)
native_set_window_icon :: proc(w: ^Window, images: []Icon_Image) {
	best := -1
	for img, i in images {
		if len(img.rgba) == img.size * img.size * 4 && (best < 0 || img.size > images[best].size) {
			best = i
		}
	}
	if best < 0 {return}
	img := images[best]
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	NONPREMULTIPLIED :: 2 // NSBitmapFormatAlphaNonpremultiplied
	rep := msg(
		^NS.Object,
		msg(^NS.Object, class_of("NSBitmapImageRep"), "alloc"),
		"initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:",
		rawptr(nil),
		NS.Integer(img.size),
		NS.Integer(img.size),
		NS.Integer(8),
		NS.Integer(4),
		NS.BOOL(true),
		NS.BOOL(false),
		ns_string("NSDeviceRGBColorSpace"),
		NS.UInteger(NONPREMULTIPLIED),
		NS.Integer(img.size * 4),
		NS.Integer(32),
	)
	if rep == nil {return}
	pixels := msg([^]u8, rep, "bitmapData")
	if pixels == nil {
		msg(nil, rep, "release")
		return
	}
	copy(pixels[:len(img.rgba)], img.rgba)
	image := msg(^NS.Object, msg(^NS.Object, class_of("NSImage"), "alloc"), "init")
	msg(nil, image, "addRepresentation:", rep)
	msg(nil, image, "setSize:", NS.Size{NS.Float(img.size), NS.Float(img.size)})
	msg(nil, w.native.app, "setApplicationIconImage:", image)
	msg(nil, rep, "release")
	msg(nil, image, "release") // (the application keeps its own reference)
}

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
			if !keep_awake_warned {
				keep_awake_warned = true
				log.warn(
					"platform IOPMAssertionCreateWithName failed: the screen may sleep while playing",
				)
			}
			assertion = 0
		}
	} else if assertion != 0 {
		IOPMAssertionRelease(assertion)
		assertion = 0
	}
}
