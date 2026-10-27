package platform

import "core:testing"

@(test)
test_pad_family :: proc(t: ^testing.T) {
	testing.expect_value(t, pad_family(0x045e, 0x028e, ""), Pad_Family.Xbox)
	testing.expect_value(t, pad_family(0x054c, 0x0ce6, ""), Pad_Family.PlayStation)
	testing.expect_value(t, pad_family(0x057e, 0x2009, ""), Pad_Family.Switch)
	testing.expect_value(t, pad_family(0x057e, 0x2006, ""), Pad_Family.Generic)
	testing.expect_value(t, pad_family(0x28de, 0x1205, ""), Pad_Family.Steam_Deck)
	testing.expect_value(
		t,
		pad_family(0x28de, 0x11ff, "Steam Virtual Gamepad"),
		Pad_Family.Generic,
	)
	testing.expect_value(t, pad_family(0x1234, 1, "Generic X-Box pad"), Pad_Family.Xbox)
	testing.expect_value(t, pad_family(0x1234, 1, "Super XBOX clone"), Pad_Family.Xbox)
	testing.expect_value(t, pad_family(0x1234, 1, "Plain pad"), Pad_Family.Generic)
}

@(test)
test_pad_ignored :: proc(t: ^testing.T) {
	steam := "0x045E/0x028E,0x054C/0x0CE6"
	testing.expect(t, pad_ignored(0x045e, 0x028e, steam, ""))
	testing.expect(t, pad_ignored(0x054c, 0x0ce6, steam, ""))
	testing.expect(t, pad_ignored(0x054c, 0x0ce6, "0x054c/0x0ce6", ""))
	testing.expect(t, pad_ignored(0x054c, 0x0ce6, " 0x045e/0x028e , 0x054c/0x0ce6 ", ""))
	testing.expect(t, !pad_ignored(0x057e, 0x2009, steam, ""))
	testing.expect(t, !pad_ignored(0x045e, 0x028e, "", ""))
	testing.expect(t, !pad_ignored(0x045e, 0x028e, steam, "0x045e/0x028e"))
	testing.expect(t, pad_ignored(0x054c, 0x0ce6, steam, "0x045e/0x028e"))
	testing.expect(t, !pad_ignored(0x045e, 0x028e, "garbage,0x/0x,", ""))
}

@(private = "file")
bits :: proc($N: int, codes: ..int) -> (out: [N]u8) {
	for c in codes {
		out[c / 8] |= 1 << uint(c % 8)
	}
	return
}

@(test)
test_evdev_is_pad :: proc(t: ^testing.T) {
	// Xbox, DualSense and Switch Pro: buttons plus the two stick axes.
	pad_keys := bits(96, BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST, BTN_TL, BTN_TR)
	pad_abs := bits(8, ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ)
	testing.expect(t, evdev_is_pad(pad_keys, pad_abs))
	// A keyboard has keys (KEY_A = 30) and no axes.
	testing.expect(t, !evdev_is_pad(bits(96, 30, 31, 32), {}))
	// A mouse: BTN_LEFT/BTN_RIGHT (0x110, 0x111) and relative axes only.
	testing.expect(t, !evdev_is_pad(bits(96, 0x110, 0x111), {}))
	// A touchpad: BTN_TOUCH (0x14a) and absolute x, y but no BTN_SOUTH.
	testing.expect(t, !evdev_is_pad(bits(96, 0x14a, 0x145), bits(8, ABS_X, ABS_Y)))
	// A motion-sensor node: axes, no buttons.
	testing.expect(t, !evdev_is_pad({}, bits(8, ABS_X, ABS_Y, ABS_Z)))
}

@(test)
test_evdev_buttons :: proc(t: ^testing.T) {
	testing.expect_value(t, evdev_button(BTN_NORTH, evdev_layout(0x045e)), Pad_Button.X)
	testing.expect_value(t, evdev_button(BTN_WEST, evdev_layout(0x045e)), Pad_Button.Y)
	testing.expect_value(t, evdev_button(BTN_NORTH, evdev_layout(0x054c)), Pad_Button.Y)
	testing.expect_value(t, evdev_button(BTN_WEST, evdev_layout(0x054c)), Pad_Button.X)
	testing.expect_value(t, evdev_button(BTN_NORTH, evdev_layout(0x057e)), Pad_Button.Y)
	testing.expect_value(t, evdev_button(BTN_WEST, evdev_layout(0x057e)), Pad_Button.X)
	testing.expect_value(t, evdev_button(BTN_NORTH, evdev_layout(0x1234)), Pad_Button.X)
	testing.expect_value(t, evdev_button(BTN_SOUTH, .Xpad), Pad_Button.A)
	testing.expect_value(t, evdev_button(BTN_THUMBR, .Xpad), Pad_Button.Right_Stick)
	testing.expect_value(t, evdev_button(BTN_SELECT, .Xpad), Pad_Button.Back)
	testing.expect_value(t, evdev_button(BTN_START, .Xpad), Pad_Button.Start)
	testing.expect_value(t, evdev_button(0x1, .Xpad), Pad_Button.None)
}

@(test)
test_evdev_axis :: proc(t: ^testing.T) {
	testing.expect_value(t, evdev_axis(-32768, -32768, 32767, false), -1)
	testing.expect_value(t, evdev_axis(32767, -32768, 32767, false), 1)
	testing.expect(t, abs(evdev_axis(0, -32768, 32767, false)) < 0.001)
	testing.expect_value(t, evdev_axis(32767, -32768, 32767, true), -1) // y: down is positive
	testing.expect(t, abs(evdev_axis(128, 0, 255, false)) < 0.01) // an 8-bit stick
	testing.expect_value(t, evdev_axis(0, 0, 255, false), -1)
	testing.expect_value(t, evdev_axis(1000, 0, 255, false, true), 1) // clamped
	testing.expect_value(t, evdev_axis(-5, 0, 255, false, true), 0)
	testing.expect(t, abs(evdev_axis(255, 0, 1023, false, true) - 0.249) < 0.001)
}

@(private = "file")
make_pad :: proc(vendor: u16, rx: bool) -> Evdev_Pad {
	d: Evdev_Pad
	abs := bits(8, ABS_X, ABS_Y, ABS_Z, ABS_RZ, ABS_HAT0X, ABS_HAT0Y)
	if rx {abs = bits(8, ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_RZ, ABS_HAT0X, ABS_HAT0Y)} else {
		abs = bits(8, ABS_X, ABS_Y, ABS_Z, ABS_RZ, ABS_BRAKE, ABS_GAS, ABS_HAT0X, ABS_HAT0Y)
	}
	ranges: [ABS_COUNT]Evdev_Abs
	for &r in ranges {r = {-32768, 32767}}
	ranges[ABS_Z] = {0, 255}
	ranges[ABS_RZ] = {0, 255}
	ranges[ABS_BRAKE] = {0, 255}
	ranges[ABS_GAS] = {0, 255}
	if !rx {ranges[ABS_Z] = {-32768, 32767}; ranges[ABS_RZ] = {-32768, 32767}}
	evdev_setup(&d, vendor, 1, "pad", abs, ranges)
	return d
}

@(test)
test_evdev_events :: proc(t: ^testing.T) {
	d := make_pad(0x045e, true)
	testing.expect_value(t, d.pending.family, Pad_Family.Xbox)
	evdev_event(&d, EV_KEY, BTN_NORTH, 1)
	testing.expect(t, .X in d.pending.buttons)
	evdev_event(&d, EV_KEY, BTN_NORTH, 0)
	testing.expect(t, .X not_in d.pending.buttons)
	evdev_event(&d, EV_ABS, ABS_RZ, 255)
	testing.expect_value(t, d.pending.axes[.Right_Trigger], 1)
	evdev_event(&d, EV_ABS, ABS_RY, -32768) // up on evdev's y: negative
	testing.expect_value(t, d.pending.axes[.Right_Y], 1)
	evdev_event(&d, EV_KEY, BTN_TR2, 1)
	testing.expect_value(t, d.pending.axes[.Right_Trigger], 1)
	evdev_event(&d, EV_KEY, BTN_TL2, 1)
	evdev_event(&d, EV_KEY, BTN_TL2, 0)
	testing.expect_value(t, d.pending.axes[.Left_Trigger], 0)
	// The hat becomes the D-pad.
	evdev_event(&d, EV_ABS, ABS_HAT0X, -1)
	evdev_event(&d, EV_ABS, ABS_HAT0Y, 1)
	testing.expect(t, d.pending.buttons == {.Dpad_Left, .Dpad_Down})
	evdev_event(&d, EV_ABS, ABS_HAT0X, 0)
	evdev_event(&d, EV_ABS, ABS_HAT0Y, -1)
	testing.expect(t, d.pending.buttons == {.Dpad_Up})
	// A pad without RX: the right stick is on Z and RZ, triggers on brake and gas.
	e := make_pad(0x1234, false)
	evdev_event(&e, EV_ABS, ABS_Z, 32767)
	testing.expect_value(t, e.pending.axes[.Right_X], 1)
	evdev_event(&e, EV_ABS, ABS_GAS, 255)
	testing.expect_value(t, e.pending.axes[.Right_Trigger], 1)
}

@(test)
test_xinput_to_state :: proc(t: ^testing.T) {
	for e in XINPUT_BUTTONS {
		s := xinput_to_state(e.mask, 0, 0, 0, 0, 0, 0)
		testing.expect(t, s.buttons == {e.button}, "one mask bit, one button")
	}
	s := xinput_to_state(0, 255, 51, -32768, 32767, 0, -16384)
	testing.expect_value(t, s.axes[.Left_X], -1)
	testing.expect_value(t, s.axes[.Left_Y], 1)
	testing.expect_value(t, s.axes[.Left_Trigger], 1)
	testing.expect_value(t, s.axes[.Right_Trigger], 0.2)
	testing.expect(t, abs(s.axes[.Right_Y] + 0.5) < 0.001)
	testing.expect_value(t, s.family, Pad_Family.Xbox)
}

@(test)
test_pad_state_diff :: proc(t: ^testing.T) {
	events: [dynamic]Event
	defer delete(events)
	old: Pad_State
	n := Pad_State {
		connected = true,
		family    = .Xbox,
		buttons   = {.A},
	}
	n.axes[.Left_X] = 0.5
	pad_state_diff(&old, n, 2, &events)
	testing.expect_value(t, len(events), 3)
	c, is_connect := events[0].(Pad_Connect_Event)
	testing.expect(
		t,
		is_connect && c.connected && c.pad == 2 && c.family == .Xbox,
		"connect first",
	)
	_, is_button := events[1].(Pad_Button_Event)
	testing.expect(t, is_button)
	clear(&events)
	// A small axis move is not sent; a large one is.
	n.axes[.Left_X] = 0.5 + 0.001
	pad_state_diff(&old, n, 2, &events)
	testing.expect_value(t, len(events), 0)
	n.axes[.Left_X] = 0.6
	pad_state_diff(&old, n, 2, &events)
	testing.expect_value(t, len(events), 1)
	clear(&events)
	// A disconnect releases what was held, zeroes the axes, then disconnects.
	pad_state_diff(&old, {}, 2, &events)
	testing.expect_value(t, len(events), 3)
	b, rel := events[0].(Pad_Button_Event)
	testing.expect(t, rel && b.button == .A && !b.pressed)
	a, zero := events[1].(Pad_Axis_Event)
	testing.expect(t, zero && a.value == 0)
	c, is_connect = events[2].(Pad_Connect_Event)
	testing.expect(t, is_connect && !c.connected)
	testing.expect(t, !old.connected)
}

@(test)
test_pads_focus :: proc(t: ^testing.T) {
	p: Pads
	events: [dynamic]Event
	defer delete(events)
	p.state[0] = {
		connected = true,
		buttons   = {.B},
	}
	p.state[0].axes[.Right_X] = 1
	// Unfocused: state kept, nothing sent (native_pads_poll is the backend's
	// own: here pads_poll's diff is driven directly).
	for i in 0 ..< MAX_PADS {pad_state_diff(&p.sent[i], p.state[i], u8(i), &events)}
	testing.expect_value(t, len(events), 3)
	clear(&events)
	pads_focus_lost(&p)
	for i in 0 ..< MAX_PADS {pad_state_diff(&p.sent[i], p.state[i], u8(i), &events)}
	testing.expect_value(t, len(events), 2) // the held button and axis again, no new connect
	_, again := events[0].(Pad_Button_Event)
	testing.expect(t, again)
}
