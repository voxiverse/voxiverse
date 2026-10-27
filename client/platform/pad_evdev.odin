package platform

// The evdev side of Linux gamepads, without any syscall (so its tests run on
// every OS): which devices are pads, and how event codes become buttons and
// axes.

EV_SYN :: 0
EV_KEY :: 1
EV_ABS :: 3
SYN_REPORT :: 0
SYN_DROPPED :: 3

BTN_SOUTH :: 0x130
BTN_EAST :: 0x131
BTN_C :: 0x132
BTN_NORTH :: 0x133 // 0x133 and 0x134 depend on the driver: see Evdev_Layout
BTN_WEST :: 0x134
BTN_TL :: 0x136
BTN_TR :: 0x137
BTN_TL2 :: 0x138
BTN_TR2 :: 0x139
BTN_SELECT :: 0x13a
BTN_START :: 0x13b
BTN_THUMBL :: 0x13d
BTN_THUMBR :: 0x13e
BTN_DPAD_UP :: 0x220
BTN_DPAD_DOWN :: 0x221
BTN_DPAD_LEFT :: 0x222
BTN_DPAD_RIGHT :: 0x223

ABS_X :: 0x00
ABS_Y :: 0x01
ABS_Z :: 0x02
ABS_RX :: 0x03
ABS_RY :: 0x04
ABS_RZ :: 0x05
ABS_GAS :: 0x09
ABS_BRAKE :: 0x0a
ABS_HAT0X :: 0x10
ABS_HAT0Y :: 0x11
ABS_COUNT :: 0x40

// Evdev_Layout: xpad and xpad-like drivers (Microsoft, Valve and every vendor
// not named below) send X as 0x133 and Y as 0x134; Sony (hid-playstation) and
// Nintendo (hid-nintendo) follow the kernel's positional rule: 0x133 the top
// button (Y) and 0x134 the left (X).
Evdev_Layout :: enum u8 {
	Xpad,
	Positional,
}

evdev_layout :: proc(vendor: u16) -> Evdev_Layout {
	return .Positional if vendor == 0x054c || vendor == 0x057e else .Xpad
}

evdev_bit :: proc(bits: []u8, n: int) -> bool {
	return n >= 0 && n / 8 < len(bits) && bits[n / 8] & (1 << uint(n % 8)) != 0
}

// evdev_is_pad: a pad has BTN_SOUTH and ABS_X and ABS_Y; this rejects
// keyboards, mice, touchpads and the PlayStation pads' motion and touchpad
// nodes.
evdev_is_pad :: proc(keys: [96]u8, abs: [8]u8) -> bool {
	keys, abs := keys, abs
	return evdev_bit(keys[:], BTN_SOUTH) && evdev_bit(abs[:], ABS_X) && evdev_bit(abs[:], ABS_Y)
}

// evdev_button: the button an evdev key code stands for (None: not one).
evdev_button :: proc(code: u16, layout: Evdev_Layout) -> Pad_Button {
	switch code {
	case BTN_SOUTH:
		return .A
	case BTN_EAST:
		return .B
	case BTN_NORTH:
		return .X if layout == .Xpad else .Y
	case BTN_WEST:
		return .Y if layout == .Xpad else .X
	case BTN_TL:
		return .Left_Bumper
	case BTN_TR:
		return .Right_Bumper
	case BTN_SELECT:
		return .Back
	case BTN_START:
		return .Start
	case BTN_THUMBL:
		return .Left_Stick
	case BTN_THUMBR:
		return .Right_Stick
	case BTN_DPAD_UP:
		return .Dpad_Up
	case BTN_DPAD_DOWN:
		return .Dpad_Down
	case BTN_DPAD_LEFT:
		return .Dpad_Left
	case BTN_DPAD_RIGHT:
		return .Dpad_Right
	}
	return .None
}

// evdev_axis: a raw axis value as -1..1 (sticks, y flipped: evdev's down is
// positive) or 0..1 (triggers, flip false and trigger true).
evdev_axis :: proc(value, min, max: i32, flip: bool, trigger := false) -> f32 {
	if max <= min {return 0}
	t := f32(value - min) / f32(max - min)
	t = clamp(t, 0, 1)
	if trigger {return t}
	v := 2 * t - 1
	return -v if flip else v
}

Evdev_Abs :: struct {
	min, max: i32,
}

// Evdev_Pad: how one device's codes map, and the state gathered since the
// last SYN_REPORT (pending).
Evdev_Pad :: struct {
	layout:  Evdev_Layout,
	has_abs: [ABS_COUNT]bool,
	abs:     [ABS_COUNT]Evdev_Abs,
	pending: Pad_State,
	hat:     [2]i32,
}

// evdev_setup records what the device has (abs bits and ranges) and its identity.
evdev_setup :: proc(
	d: ^Evdev_Pad,
	vendor, product: u16,
	name: string,
	abs_bits: [8]u8,
	ranges: [ABS_COUNT]Evdev_Abs,
) {
	abs_bits := abs_bits
	d^ = {}
	d.layout = evdev_layout(vendor)
	for i in 0 ..< ABS_COUNT {
		d.has_abs[i] = evdev_bit(abs_bits[:], i)
	}
	d.abs = ranges
	d.pending.connected = true
	d.pending.vendor, d.pending.product = vendor, product
	d.pending.family = pad_family(vendor, product, name)
}

@(private)
evdev_stick_on_rx :: proc(d: ^Evdev_Pad) -> bool {
	return d.has_abs[ABS_RX]
}

// evdev_event applies one input_event to d.pending.
evdev_event :: proc(d: ^Evdev_Pad, type: u16, code: u16, value: i32) {
	p := &d.pending
	switch type {
	case EV_KEY:
		down := value != 0
		switch code {
		case BTN_TL2:
			p.axes[.Left_Trigger] = 1 if down else 0
		case BTN_TR2:
			p.axes[.Right_Trigger] = 1 if down else 0
		case:
			b := evdev_button(code, d.layout)
			if b == .None {return}
			if down {p.buttons += {b}} else {p.buttons -= {b}}
		}
	case EV_ABS:
		if code >= ABS_COUNT {return}
		a := d.abs[code]
		stick :: proc(a: Evdev_Abs, v: i32, flip: bool) -> f32 {return evdev_axis(
				v,
				a.min,
				a.max,
				flip,
			)}
		trig :: proc(a: Evdev_Abs, v: i32) -> f32 {return evdev_axis(v, a.min, a.max, false, true)}
		rx := evdev_stick_on_rx(d)
		switch code {
		case ABS_X:
			p.axes[.Left_X] = stick(a, value, false)
		case ABS_Y:
			p.axes[.Left_Y] = stick(a, value, true)
		case ABS_RX:
			p.axes[.Right_X] = stick(a, value, false)
		case ABS_RY:
			p.axes[.Right_Y] = stick(a, value, true)
		case ABS_Z:
			if rx {p.axes[.Left_Trigger] = trig(a, value)} else {p.axes[.Right_X] = stick(a, value, false)}
		case ABS_RZ:
			if rx {p.axes[.Right_Trigger] = trig(a, value)} else {p.axes[.Right_Y] = stick(a, value, true)}
		case ABS_BRAKE:
			if !rx {p.axes[.Left_Trigger] = trig(a, value)}
		case ABS_GAS:
			if !rx {p.axes[.Right_Trigger] = trig(a, value)}
		case ABS_HAT0X:
			d.hat.x = value
			evdev_hat(p, d.hat)
		case ABS_HAT0Y:
			d.hat.y = value
			evdev_hat(p, d.hat)
		}
	}
}

// evdev_hat: the D-pad buttons from the hat (-1 left/up, +1 right/down).
evdev_hat :: proc(p: ^Pad_State, hat: [2]i32) {
	p.buttons -= {.Dpad_Left, .Dpad_Right, .Dpad_Up, .Dpad_Down}
	if hat.x < 0 {p.buttons += {.Dpad_Left}}
	if hat.x > 0 {p.buttons += {.Dpad_Right}}
	if hat.y < 0 {p.buttons += {.Dpad_Up}}
	if hat.y > 0 {p.buttons += {.Dpad_Down}}
}
