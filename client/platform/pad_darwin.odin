package platform

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// macOS gamepads: the GameController framework through the Objective-C
// runtime. Controllers are matched to slots by object pointer (retained
// while in a slot); those without an extended gamepad are skipped. The
// framework's connect notifications need the run loop that M1b brings, which
// is why [GCController controllers] is polled. Compiled and its pure parts
// tested here; running it waits for a tester's Mac.
//
// M47e's decision: the list is still read each poll rather than through
// GCControllerDidConnect/DidDisconnect observers on a delegate class made at
// run time. The list is the framework's own truth (a connect or disconnect
// shows on the next frame, which is as soon as the notification would reach
// the same event list), and the observer class would be code nobody here can
// run. Slots free when a controller leaves the list.

foreign import gamecontroller "system:GameController.framework"

@(private = "file")
foreign gamecontroller {
	GCControllerDidConnectNotification: ^NS.String
}

@(private = "file")
@(objc_class = "GCController")
GC_Controller :: struct {
	using _: NS.Object,
}

@(private = "file")
msg :: intrinsics.objc_send

Native_Pads :: struct {
	slots: [MAX_PADS]^NS.Object,
}

// pad_family_from_category: GCController's productCategory names the model.
pad_family_from_category :: proc(category: string) -> Pad_Family {
	lower := strings.to_lower(category, context.temp_allocator)
	switch {
	case strings.contains(lower, "xbox"):
		return .Xbox
	case strings.contains(lower, "dualshock"), strings.contains(lower, "dualsense"):
		return .PlayStation
	case strings.contains(lower, "switch"),
	     strings.contains(lower, "pro controller"),
	     strings.contains(lower, "joy-con"):
		return .Switch
	}
	return .Generic
}

native_pads_open :: proc(p: ^Pads) {
	// Referencing a framework symbol keeps the framework linked.
	_ = GCControllerDidConnectNotification
}

native_pads_close :: proc(p: ^Pads) {
	for &c in p.native.slots {
		if c != nil {msg(nil, c, "release")}
		c = nil
	}
}

@(private = "file")
pressed :: proc(button: ^NS.Object) -> bool {
	return button != nil && bool(msg(NS.BOOL, button, "isPressed"))
}

@(private = "file")
value :: proc(input: ^NS.Object) -> f32 {
	return msg(f32, input, "value") if input != nil else 0
}

native_pads_poll :: proc(p: ^Pads) {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	n := &p.native
	list := msg(^NS.Array, GC_Controller, "controllers")
	count := int(list->count()) if list != nil else 0
	// Leaving controllers free their slot.
	for i in 0 ..< MAX_PADS {
		c := n.slots[i]
		if c == nil {continue}
		found := false
		for j in 0 ..< count {
			if rawptr(list->object(NS.UInteger(j))) == rawptr(c) {found = true}
		}
		if !found {
			msg(nil, c, "release")
			n.slots[i] = nil
			p.state[i] = {}
		}
	}
	for j in 0 ..< count {
		c := list->object(NS.UInteger(j))
		pad := msg(^NS.Object, c, "extendedGamepad")
		if pad == nil {continue}
		slot := -1
		for i in 0 ..< MAX_PADS {
			if n.slots[i] == c {slot = i}
		}
		if slot < 0 {
			for i in 0 ..< MAX_PADS {
				if n.slots[i] == nil {
					slot = i
					break
				}
			}
			if slot < 0 {continue}
			msg(nil, c, "retain")
			n.slots[slot] = c
		}
		s := Pad_State {
			connected = true,
		}
		// The family: productCategory names the model, vendorName where it
		// does not ("Xbox Wireless Controller", "DualSense Wireless Controller").
		category := msg(^NS.Object, c, "productCategory")
		if category != nil {
			s.family = pad_family_from_category(string(msg(cstring, category, "UTF8String")))
		}
		vendor := msg(^NS.Object, c, "vendorName")
		if s.family == .Generic && vendor != nil {
			s.family = pad_family_from_category(string(msg(cstring, vendor, "UTF8String")))
		}
		set :: proc(s: ^Pad_State, b: Pad_Button, on: bool) {
			if on {s.buttons += {b}}
		}
		set(&s, .A, pressed(msg(^NS.Object, pad, "buttonA")))
		set(&s, .B, pressed(msg(^NS.Object, pad, "buttonB")))
		set(&s, .X, pressed(msg(^NS.Object, pad, "buttonX")))
		set(&s, .Y, pressed(msg(^NS.Object, pad, "buttonY")))
		set(&s, .Left_Bumper, pressed(msg(^NS.Object, pad, "leftShoulder")))
		set(&s, .Right_Bumper, pressed(msg(^NS.Object, pad, "rightShoulder")))
		dpad := msg(^NS.Object, pad, "dpad")
		if dpad != nil {
			set(&s, .Dpad_Up, pressed(msg(^NS.Object, dpad, "up")))
			set(&s, .Dpad_Down, pressed(msg(^NS.Object, dpad, "down")))
			set(&s, .Dpad_Left, pressed(msg(^NS.Object, dpad, "left")))
			set(&s, .Dpad_Right, pressed(msg(^NS.Object, dpad, "right")))
		}
		s.axes[.Left_Trigger] = value(msg(^NS.Object, pad, "leftTrigger"))
		s.axes[.Right_Trigger] = value(msg(^NS.Object, pad, "rightTrigger"))
		left := msg(^NS.Object, pad, "leftThumbstick")
		if left != nil {
			s.axes[.Left_X] = value(msg(^NS.Object, left, "xAxis"))
			s.axes[.Left_Y] = value(msg(^NS.Object, left, "yAxis"))
		}
		right := msg(^NS.Object, pad, "rightThumbstick")
		if right != nil {
			s.axes[.Right_X] = value(msg(^NS.Object, right, "xAxis"))
			s.axes[.Right_Y] = value(msg(^NS.Object, right, "yAxis"))
		}
		// The optional buttons: only where the object answers the selector.
		if bool(
			msg(
				NS.BOOL,
				pad,
				"respondsToSelector:",
				intrinsics.objc_find_selector("leftThumbstickButton"),
			),
		) {
			set(&s, .Left_Stick, pressed(msg(^NS.Object, pad, "leftThumbstickButton")))
		}
		if bool(
			msg(
				NS.BOOL,
				pad,
				"respondsToSelector:",
				intrinsics.objc_find_selector("rightThumbstickButton"),
			),
		) {
			set(&s, .Right_Stick, pressed(msg(^NS.Object, pad, "rightThumbstickButton")))
		}
		if bool(
			msg(NS.BOOL, pad, "respondsToSelector:", intrinsics.objc_find_selector("buttonMenu")),
		) {
			set(&s, .Start, pressed(msg(^NS.Object, pad, "buttonMenu")))
		}
		if bool(
			msg(
				NS.BOOL,
				pad,
				"respondsToSelector:",
				intrinsics.objc_find_selector("buttonOptions"),
			),
		) {
			set(&s, .Back, pressed(msg(^NS.Object, pad, "buttonOptions")))
		}
		p.state[slot] = s
	}
}
