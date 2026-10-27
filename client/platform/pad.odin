package platform

import "core:strings"

// Gamepads: the types and the logic every backend shares. A backend
// (pad_linux.odin, pad_windows.odin, pad_darwin.odin) only fills p.state;
// pads_poll turns the difference to what was last sent into events.

MAX_PADS :: 4

// Pad_Button: named by place, as on an Xbox pad (A is the bottom face button
// on every pad). None is "unbound" in bindings. The triggers are reported as
// axes; the buttons exist for bindings, and the client makes presses of them.
Pad_Button :: enum u8 {
	None,
	A,
	B,
	X,
	Y,
	Left_Bumper,
	Right_Bumper,
	Left_Trigger,
	Right_Trigger,
	Back,
	Start,
	Left_Stick,
	Right_Stick,
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
}

// Pad_Axis: sticks -1..1 with y positive up; triggers 0..1. Raw: no dead zone.
Pad_Axis :: enum u8 {
	Left_X,
	Left_Y,
	Right_X,
	Right_Y,
	Left_Trigger,
	Right_Trigger,
}

Pad_Family :: enum u8 {
	Generic,
	Xbox,
	PlayStation,
	Switch,
	Steam_Deck,
}

Pad_State :: struct {
	connected:       bool,
	family:          Pad_Family,
	vendor, product: u16,
	buttons:         bit_set[Pad_Button],
	axes:            [Pad_Axis]f32,
}

Pad_Connect_Event :: struct {
	pad:             u8,
	connected:       bool,
	family:          Pad_Family,
	vendor, product: u16,
}

Pad_Button_Event :: struct {
	pad:     u8,
	button:  Pad_Button,
	pressed: bool,
}

Pad_Axis_Event :: struct {
	pad:   u8,
	axis:  Pad_Axis,
	value: f32,
}

// Pads: state is what the backend last read, sent what the events said.
Pads :: struct {
	state, sent: [MAX_PADS]Pad_State,
	native:      Native_Pads,
}

// PAD_AXIS_STEP: smaller axis moves are not worth an event.
PAD_AXIS_STEP :: 1.0 / 256

pads_open :: proc(p: ^Pads) {
	native_pads_open(p)
}

pads_close :: proc(p: ^Pads) {
	native_pads_close(p)
}

// pads_poll reads the pads and appends the changes to events. Unfocused
// (deliver false) the state is kept and nothing is sent; when focus comes
// back, sent is at rest so every held value is sent again.
pads_poll :: proc(p: ^Pads, events: ^[dynamic]Event, deliver: bool) {
	native_pads_poll(p)
	if !deliver {
		pads_focus_lost(p)
		return
	}
	for i in 0 ..< MAX_PADS {
		pad_state_diff(&p.sent[i], p.state[i], u8(i), events)
	}
}

// pads_focus_lost puts what was sent back to rest (the connections stay), so
// every held value is sent again when focus returns.
pads_focus_lost :: proc(p: ^Pads) {
	for &s in p.sent {
		if s.connected {s = Pad_State {
				connected = true,
				family    = s.family,
				vendor    = s.vendor,
				product   = s.product,
			}}
	}
}

// pad_state_diff appends the events that take old to new, and makes old new:
// the connect first, then buttons, then axes that moved more than
// PAD_AXIS_STEP. A disconnect releases what was held and zeroes the axes.
pad_state_diff :: proc(old: ^Pad_State, new: Pad_State, pad: u8, events: ^[dynamic]Event) {
	if !new.connected {
		if !old.connected {return}
		for b in old.buttons {
			append(events, Pad_Button_Event{pad, b, false})
		}
		for v, a in old.axes {
			if v != 0 {append(events, Pad_Axis_Event{pad, a, 0})}
		}
		append(
			events,
			Pad_Connect_Event {
				pad = pad,
				connected = false,
				family = old.family,
				vendor = old.vendor,
				product = old.product,
			},
		)
		old^ = {}
		return
	}
	if !old.connected ||
	   old.vendor != new.vendor ||
	   old.product != new.product ||
	   old.family != new.family {
		if old.connected {
			pad_state_diff(old, {}, pad, events)
		}
		append(
			events,
			Pad_Connect_Event {
				pad = pad,
				connected = true,
				family = new.family,
				vendor = new.vendor,
				product = new.product,
			},
		)
		old^ = {
			connected = true,
			family    = new.family,
			vendor    = new.vendor,
			product   = new.product,
		}
	}
	for b in Pad_Button {
		if b == .None {continue}
		was, now := b in old.buttons, b in new.buttons
		if was != now {
			append(events, Pad_Button_Event{pad, b, now})
			if now {old.buttons += {b}} else {old.buttons -= {b}}
		}
	}
	for a in Pad_Axis {
		v := new.axes[a]
		if abs(v - old.axes[a]) > PAD_AXIS_STEP || (v == 0 && old.axes[a] != 0) {
			append(events, Pad_Axis_Event{pad, a, v})
			old.axes[a] = v
		}
	}
}

// pad_family: what kind of pad has this USB vendor and product, going by
// name where the ids say nothing.
pad_family :: proc(vendor, product: u16, name: string) -> Pad_Family {
	switch vendor {
	case 0x045e:
		return .Xbox
	case 0x054c:
		return .PlayStation
	case 0x057e:
		if product == 0x2009 {return .Switch}
	case 0x28de:
		if product == 0x1205 {return .Steam_Deck}
		if product == 0x11ff {return .Generic} 	// Steam Input's virtual pad
	}
	lower := strings.to_lower(name, context.temp_allocator)
	if strings.contains(lower, "xbox") || strings.contains(lower, "x-box") {return .Xbox}
	return .Generic
}

// pad_ignored: whether Steam asked games to leave this pad alone
// (SDL_GAMECONTROLLER_IGNORE_DEVICES, listing the physical pads it already
// presents as its virtual one, and ..._EXCEPT, the exceptions).
pad_ignored :: proc(vendor, product: u16, env_ignore, env_except: string) -> bool {
	return pad_in_list(vendor, product, env_ignore) && !pad_in_list(vendor, product, env_except)
}

@(private)
pad_in_list :: proc(vendor, product: u16, list: string) -> bool {
	rest := list
	for item in strings.split_iterator(&rest, ",") {
		s := strings.trim_space(item)
		if len(s) > 2 && (s[:2] == "0x" || s[:2] == "0X") {s = s[2:]}
		slash := strings.index_byte(s, '/')
		if slash < 0 {continue}
		v, vok := parse_hex(s[:slash])
		pr, pok := parse_hex(s[slash + 1:])
		if vok && pok && v == u32(vendor) && pr == u32(product) {return true}
	}
	return false
}

@(private)
parse_hex :: proc(s: string) -> (v: u32, ok: bool) {
	t := strings.trim_space(s)
	if len(t) > 2 && (t[:2] == "0x" || t[:2] == "0X") {t = t[2:]}
	if len(t) == 0 || len(t) > 8 {return}
	for c in t {
		d: u32
		switch c {
		case '0' ..= '9':
			d = u32(c - '0')
		case 'a' ..= 'f':
			d = u32(c - 'a') + 10
		case 'A' ..= 'F':
			d = u32(c - 'A') + 10
		case:
			return
		}
		v = v * 16 + d
	}
	return v, true
}
