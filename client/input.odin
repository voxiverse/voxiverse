package client

import "../platform"
import "../ui"

// Turns a frame's platform events into ui.Input. The platform reports key
// presses and releases; held modifiers are tracked here.

Input_State :: struct {
	mouse:          [2]f32, // pixels
	mouse_down:     bit_set[ui.Mouse_Button],
	mouse_pressed:  bit_set[ui.Mouse_Button],
	mouse_released: bit_set[ui.Mouse_Button],
	wheel:          [2]f32,
	keys_pressed:   bit_set[ui.Key],
	held:           bit_set[platform.Key], // keys currently down (modifiers)
	text:           [dynamic]rune,
	escape:         bool, // pressed this frame
	console_toggle: bool,
}

input_update :: proc(s: ^Input_State, events: []platform.Event) {
	s.mouse_pressed, s.mouse_released, s.keys_pressed = {}, {}, {}
	s.wheel = {}
	s.escape, s.console_toggle = false, false
	clear(&s.text)
	for e in events {
		switch v in e {
		case platform.Key_Event:
			if v.pressed {s.held += {v.key}} else {s.held -= {v.key}}
			if !v.pressed {continue}
			if v.key == .Escape && !v.repeat {s.escape = true}
			if v.key == .Grave && !v.repeat {s.console_toggle = true}
			if k, ok := ui_key(v.key); ok {s.keys_pressed += {k}}
		case platform.Text_Event:
			if v.char != '`' {append(&s.text, v.char)} 	// the console key types nothing
		case platform.Mouse_Move_Event:
			s.mouse = {v.x, v.y}
		case platform.Mouse_Button_Event:
			s.mouse = {v.x, v.y}
			b: ui.Mouse_Button
			switch v.button {
			case .Left:
				b = .Left
			case .Right:
				b = .Right
			case .Middle:
				b = .Middle
			case .X1, .X2:
				continue
			}
			if v.pressed {
				s.mouse_down += {b}
				s.mouse_pressed += {b}
			} else {
				s.mouse_down -= {b}
				s.mouse_released += {b}
			}
		case platform.Mouse_Wheel_Event:
			s.wheel += {v.dx, v.dy}
		case platform.Focus_Event:
			if !v.focused {s.held, s.mouse_down = {}, {}} 	// releases happen elsewhere
		case platform.Resize_Event:
		}
	}
}

// ui_input converts to the UI's units (pixels / scale).
ui_input :: proc(s: ^Input_State, scale: f32) -> ui.Input {
	mods: bit_set[ui.Modifier]
	if s.held & {.Left_Shift, .Right_Shift} != {} {mods += {.Shift}}
	if s.held & {.Left_Control, .Right_Control} != {} {mods += {.Ctrl}}
	if s.held & {.Left_Alt, .Right_Alt} != {} {mods += {.Alt}}
	return {
		mouse = s.mouse / scale,
		mouse_down = s.mouse_down,
		mouse_pressed = s.mouse_pressed,
		mouse_released = s.mouse_released,
		wheel = s.wheel,
		keys_pressed = s.keys_pressed,
		modifiers = mods,
		text = s.text[:],
	}
}

@(private)
ui_key :: proc(k: platform.Key) -> (ui.Key, bool) {
	#partial switch k {
	case .Tab:
		return .Tab, true
	case .Enter:
		return .Enter, true
	case .Escape:
		return .Escape, true
	case .Space:
		return .Space, true
	case .Backspace:
		return .Backspace, true
	case .Delete:
		return .Delete, true
	case .Left:
		return .Left, true
	case .Right:
		return .Right, true
	case .Up:
		return .Up, true
	case .Down:
		return .Down, true
	case .Home:
		return .Home, true
	case .End:
		return .End, true
	case .Page_Up:
		return .Page_Up, true
	case .Page_Down:
		return .Page_Down, true
	case .A:
		return .A, true
	case .C:
		return .C, true
	case .V:
		return .V, true
	case .X:
		return .X, true
	}
	return {}, false
}
