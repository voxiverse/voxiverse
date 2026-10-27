package platform

// XInput's state, converted without any Windows call (so its tests run on
// every OS). The mirror of XINPUT_STATE is 16 bytes.

Xinput_State :: struct {
	packet:         u32,
	buttons:        u16,
	left_trigger:   u8,
	right_trigger:  u8,
	lx, ly, rx, ry: i16,
}

XINPUT_BUTTONS :: [?]struct {
	mask:   u16,
	button: Pad_Button,
} {
	{0x0001, .Dpad_Up},
	{0x0002, .Dpad_Down},
	{0x0004, .Dpad_Left},
	{0x0008, .Dpad_Right},
	{0x0010, .Start},
	{0x0020, .Back},
	{0x0040, .Left_Stick},
	{0x0080, .Right_Stick},
	{0x0100, .Left_Bumper},
	{0x0200, .Right_Bumper},
	{0x1000, .A},
	{0x2000, .B},
	{0x4000, .X},
	{0x8000, .Y},
}

xinput_stick :: proc(v: i16) -> f32 {
	return f32(max(i32(v), -32767)) / 32767
}

// xinput_to_state: a connected Xbox-family pad (XInput tells no vendor).
xinput_to_state :: proc(buttons: u16, lt, rt: u8, lx, ly, rx, ry: i16) -> Pad_State {
	s := Pad_State {
		connected = true,
		family    = .Xbox,
	}
	for e in XINPUT_BUTTONS {
		if buttons & e.mask != 0 {s.buttons += {e.button}}
	}
	s.axes[.Left_X], s.axes[.Left_Y] = xinput_stick(lx), xinput_stick(ly)
	s.axes[.Right_X], s.axes[.Right_Y] = xinput_stick(rx), xinput_stick(ry)
	s.axes[.Left_Trigger], s.axes[.Right_Trigger] = f32(lt) / 255, f32(rt) / 255
	return s
}
