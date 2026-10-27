package client

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"

import "platform"

// Input actions: one layer between the platform's events (keys, mouse
// buttons, gamepads) and everything that reads controls. Call sites ask
// "is Jump down", never "is Space held"; the bindings (controls.odin) say
// which keys and pad buttons make an action, per device.

Action :: enum u8 {
	None,
	Forward,
	Back,
	Left,
	Right,
	Jump, // twice quickly: fly
	Sneak,
	Sprint,
	Attack,
	Use,
	Pick,
	Inventory,
	Stats, // also closes it
	Drop,
	Chat,
	Command,
	Hotbar_1,
	Hotbar_2,
	Hotbar_3,
	Hotbar_4,
	Hotbar_5,
	Hotbar_Next,
	Hotbar_Previous,
	Pause,
	Menu_Up,
	Menu_Down,
	Menu_Left,
	Menu_Right,
	Menu_Confirm,
	Menu_Back,
	Menu_Secondary,
	Menu_Tertiary,
	Tab_Prev,
	Tab_Next,
	Screenshot,
	Fullscreen,
}

// Action_Context: where an action is read. World is game_controls(app);
// Menu is everything else (menu screens, overlays that take the keyboard or
// mouse, the loading screen).
Action_Context :: enum u8 {
	World,
	Menu,
}

Action_Info :: struct {
	contexts:   bit_set[Action_Context],
	label:      string,
	fixed_keys: [2]platform.Key, // not rebindable
	fixed_pad:  [2]platform.Pad_Button,
}

// ACTION_INFO: where each action is read and what is fixed about it. The
// rebindable sources are fields (action_key, action_pad); the movement and
// look actions' pad sources (the sticks) are handled in actions_update.
ACTION_INFO := [Action]Action_Info {
	.None            = {},
	.Forward         = {{.World}, "Walk forward", {}, {}},
	.Back            = {{.World}, "Walk backward", {}, {}},
	.Left            = {{.World}, "Strafe left", {}, {}},
	.Right           = {{.World}, "Strafe right", {}, {}},
	.Jump            = {{.World}, "Jump", {}, {}},
	.Sneak           = {{.World}, "Sneak", {}, {}},
	.Sprint          = {{.World}, "Sprint", {}, {}},
	.Attack          = {{.World}, "Attack / Break", {}, {}},
	.Use             = {{.World}, "Use / Place", {}, {}},
	.Pick            = {{.World}, "Pick Block", {}, {}},
	.Inventory       = {{.World}, "Inventory", {}, {}},
	.Stats           = {{.World, .Menu}, "Statistics", {}, {}},
	.Drop            = {{.World}, "Drop item", {}, {}},
	.Chat            = {{.World}, "Open chat", {}, {}},
	.Command         = {{.World}, "Open command", {}, {}},
	.Hotbar_1        = {{.World}, "Hotbar slot 1", {}, {}},
	.Hotbar_2        = {{.World}, "Hotbar slot 2", {}, {}},
	.Hotbar_3        = {{.World}, "Hotbar slot 3", {}, {}},
	.Hotbar_4        = {{.World}, "Hotbar slot 4", {}, {}},
	.Hotbar_5        = {{.World}, "Hotbar slot 5", {}, {}},
	.Hotbar_Next     = {{.World}, "Next hotbar slot", {}, {}},
	.Hotbar_Previous = {{.World}, "Previous hotbar slot", {}, {}},
	.Pause           = {{.World, .Menu}, "Game menu", {}, {.Start, .None}},
	.Menu_Up         = {{.Menu}, "Up", {.Up, .Unknown}, {.Dpad_Up, .None}},
	.Menu_Down       = {{.Menu}, "Down", {.Down, .Unknown}, {.Dpad_Down, .None}},
	.Menu_Left       = {{.Menu}, "Left", {.Left, .Unknown}, {.Dpad_Left, .None}},
	.Menu_Right      = {{.Menu}, "Right", {.Right, .Unknown}, {.Dpad_Right, .None}},
	.Menu_Confirm    = {{.Menu}, "Confirm", {.Enter, .Space}, {}},
	.Menu_Back       = {{.Menu}, "Back", {.Escape, .Unknown}, {}},
	.Menu_Secondary  = {{.Menu}, "Second action", {}, {}},
	.Menu_Tertiary   = {{.Menu}, "Third action", {}, {}},
	.Tab_Prev        = {{.Menu}, "Previous tab", {}, {}},
	.Tab_Next        = {{.Menu}, "Next tab", {}, {}},
	.Screenshot      = {{.World, .Menu}, "Take screenshot", {}, {}},
	.Fullscreen      = {{.World, .Menu}, "Toggle fullscreen", {}, {}},
}

// PAD_COVERED_BY, KEY_COVERED_BY: why an action has no rebindable source on
// a device (every action must be reachable on both; the test checks).
PAD_COVERED_BY :: [?]struct {
	action: Action,
	reason: string,
} {
	{.Forward, "the left stick"},
	{.Back, "the left stick"},
	{.Left, "the left stick"},
	{.Right, "the left stick"},
	{.Hotbar_1, "the bumpers cycle the hotbar"},
	{.Hotbar_2, "the bumpers cycle the hotbar"},
	{.Hotbar_3, "the bumpers cycle the hotbar"},
	{.Hotbar_4, "the bumpers cycle the hotbar"},
	{.Hotbar_5, "the bumpers cycle the hotbar"},
	{.Command, "the chat, then a slash (menus with a pad: M42)"},
	{.Screenshot, "not on pads"},
	{.Fullscreen, "not on pads"},
}

KEY_COVERED_BY :: [?]struct {
	action: Action,
	reason: string,
} {
	{.Pause, "Escape backs out (escape): it opens the game menu too"},
	{.Hotbar_Next, "the wheel"},
	{.Hotbar_Previous, "the wheel"},
	{.Menu_Secondary, "menus with a pad only"},
	{.Menu_Tertiary, "menus with a pad only"},
}

// action_key: the rebindable key of a, nil where it is fixed or none.
action_key :: proc(b: ^Bindings, a: Action) -> ^platform.Key {
	switch a {
	case .None,
	     .Pause,
	     .Menu_Up,
	     .Menu_Down,
	     .Menu_Left,
	     .Menu_Right,
	     .Menu_Confirm,
	     .Menu_Back,
	     .Menu_Secondary,
	     .Menu_Tertiary:
		return nil
	case .Forward:
		return &b.forward
	case .Back:
		return &b.back
	case .Left:
		return &b.left
	case .Right:
		return &b.right
	case .Jump:
		return &b.jump
	case .Sneak:
		return &b.sneak
	case .Sprint:
		return &b.sprint
	case .Attack:
		return &b.attack
	case .Use:
		return &b.use
	case .Pick:
		return &b.pick
	case .Inventory:
		return &b.inventory
	case .Stats:
		return &b.stats
	case .Drop:
		return &b.drop
	case .Chat:
		return &b.chat
	case .Command:
		return &b.command
	case .Hotbar_1:
		return &b.hotbar_1
	case .Hotbar_2:
		return &b.hotbar_2
	case .Hotbar_3:
		return &b.hotbar_3
	case .Hotbar_4:
		return &b.hotbar_4
	case .Hotbar_5:
		return &b.hotbar_5
	case .Hotbar_Next:
		return &b.hotbar_next
	case .Hotbar_Previous:
		return &b.hotbar_previous
	case .Tab_Prev:
		return &b.tab_prev
	case .Tab_Next:
		return &b.tab_next
	case .Screenshot:
		return &b.screenshot
	case .Fullscreen:
		return &b.fullscreen
	}
	return nil
}

// action_pad: the rebindable pad button of a, nil where it is fixed or none.
action_pad :: proc(p: ^Pad_Bindings, a: Action) -> ^platform.Pad_Button {
	switch a {
	case .None,
	     .Forward,
	     .Back,
	     .Left,
	     .Right,
	     .Hotbar_1,
	     .Hotbar_2,
	     .Hotbar_3,
	     .Hotbar_4,
	     .Hotbar_5,
	     .Pause,
	     .Menu_Up,
	     .Menu_Down,
	     .Menu_Left,
	     .Menu_Right,
	     .Fullscreen:
		return nil
	case .Jump:
		return &p.jump
	case .Sneak:
		return &p.sneak
	case .Sprint:
		return &p.sprint
	case .Attack:
		return &p.attack
	case .Use:
		return &p.use
	case .Pick:
		return &p.pick
	case .Inventory:
		return &p.inventory
	case .Stats:
		return &p.stats
	case .Drop:
		return &p.drop
	case .Chat:
		return &p.chat
	case .Command:
		return &p.command
	case .Hotbar_Next:
		return &p.hotbar_next
	case .Hotbar_Previous:
		return &p.hotbar_previous
	case .Screenshot:
		return &p.screenshot
	case .Menu_Confirm:
		return &p.menu_confirm
	case .Menu_Back:
		return &p.menu_back
	case .Menu_Secondary:
		return &p.menu_secondary
	case .Menu_Tertiary:
		return &p.menu_tertiary
	case .Tab_Prev:
		return &p.tab_prev
	case .Tab_Next:
		return &p.tab_next
	}
	return nil
}

// action_field: the name of a's field in Bindings and Pad_Bindings.
action_field :: proc(a: Action) -> string {
	name, _ := reflect.enum_name_from_value(a)
	return strings.to_lower(name, context.temp_allocator)
}

// action_keys: every key (bound, then fixed) that makes a.
action_keys :: proc(b: ^Bindings, a: Action) -> (out: [3]platform.Key) {
	if k := action_key(b, a); k != nil {out[0] = k^}
	out[1], out[2] = ACTION_INFO[a].fixed_keys[0], ACTION_INFO[a].fixed_keys[1]
	return
}

action_pads :: proc(p: ^Pad_Bindings, a: Action) -> (out: [3]platform.Pad_Button) {
	if b := action_pad(p, a); b != nil {out[0] = b^}
	out[1], out[2] = ACTION_INFO[a].fixed_pad[0], ACTION_INFO[a].fixed_pad[1]
	return
}

// binding_conflicts: the actions that share a source (fixed ones included)
// with another action in a context they share, on the keyboard and on the pad.
binding_conflicts :: proc(
	keys: ^Bindings,
	pad: ^Pad_Bindings,
) -> (
	key_clash, pad_clash: bit_set[Action],
) {
	for a in Action {
		if a == .None {continue}
		for b in Action {
			if b == .None || b <= a {continue}
			if ACTION_INFO[a].contexts & ACTION_INFO[b].contexts == {} {continue}
			ka, kb := action_keys(keys, a), action_keys(keys, b)
			for x in ka {
				if x == .Unknown {continue}
				for y in kb {
					if x == y {key_clash += {a, b}}
				}
			}
			pa, pb := action_pads(pad, a), action_pads(pad, b)
			for x in pa {
				if x == .None {continue}
				for y in pb {
					if x == y {pad_clash += {a, b}}
				}
			}
		}
	}
	return
}

Device :: enum u8 {
	Keyboard,
	Pad,
}

PAD_STICK_OUTER :: 0.95
PAD_YAW_RATE :: 4.7 // radians a second at full deflection: about 270 degrees
PAD_PITCH_RATE :: 3.5 // about 200
NAV_REPEAT_DELAY :: 0.4
NAV_REPEAT_INTERVAL :: 0.1
TRIGGER_DOWN :: 0.5
TRIGGER_UP :: 0.4

Actions :: struct {
	context_:     Action_Context,
	ready:        bool, // the first update has set context_
	down:         bit_set[Action],
	pressed:      bit_set[Action],
	released:     bit_set[Action],
	latched:      bit_set[Action], // held across a context change: up until released
	move:         [2]f32, // World: length at most 1
	look:         [2]f32, // World: the pad's turning, radians a second (yaw, pitch)
	nav:          bit_set[Action], // Menu: up, down, left, right this frame, with repeat
	trigger_down: [2]bool, // left, right
	device:       Device, // the last used
	pad_family:   platform.Pad_Family, // of the pad used last
	pad_product:  u16,
	key_down:     bit_set[Action], // keyboard sources only, in any context (over-slot keys)
	key_pressed:  bit_set[Action],
	prev_raw:     bit_set[Action], // last frame's sources held, any context
	prev_down:    bit_set[Action],
	nav_held:     [4]bool,
	nav_timer:    [4]f32,
	mouse:        [2]f32,
	// The merged pad this frame.
	pad_buttons:  bit_set[platform.Pad_Button],
	pad_pressed:  bit_set[platform.Pad_Button], // presses this frame, triggers included
	pad_axes:     [platform.Pad_Axis]f32,
}

// stick_shape: a radial dead zone, `inner` inside and PAD_STICK_OUTER
// outside; the direction is kept.
stick_shape :: proc(raw: [2]f32, inner: f32) -> [2]f32 {
	m := math.sqrt(raw.x * raw.x + raw.y * raw.y)
	if m <= inner || m == 0 {return {}}
	scaled := clamp((m - inner) / (PAD_STICK_OUTER - inner), 0, 1)
	return raw / m * scaled
}

// pad_merge: every connected pad together: buttons united, each stick from
// the pad whose stick is deflected most, triggers the largest.
@(private = "file")
pad_merge :: proc(
	pads: ^[platform.MAX_PADS]platform.Pad_State,
) -> (
	buttons: bit_set[platform.Pad_Button],
	axes: [platform.Pad_Axis]f32,
) {
	best: [2]f32
	for p in pads {
		if !p.connected {continue}
		buttons += p.buttons
		for s in 0 ..< 2 {
			x, y := platform.Pad_Axis(2 * s), platform.Pad_Axis(2 * s + 1)
			m := p.axes[x] * p.axes[x] + p.axes[y] * p.axes[y]
			if m > best[s] {
				best[s] = m
				axes[x], axes[y] = p.axes[x], p.axes[y]
			}
		}
		axes[.Left_Trigger] = max(axes[.Left_Trigger], p.axes[.Left_Trigger])
		axes[.Right_Trigger] = max(axes[.Right_Trigger], p.axes[.Right_Trigger])
	}
	return
}

// actions_update: this frame's actions from the input, in context ctx.
// typing: a text field has the keyboard (bound keys then do nothing).
actions_update :: proc(
	a: ^Actions,
	input: ^Input_State,
	settings: ^Settings,
	ctx: Action_Context,
	typing: bool,
	dt: f32,
) {
	// The merged pad and the triggers.
	a.pad_buttons, a.pad_axes = pad_merge(&input.pads)
	was_trigger := a.trigger_down
	triggers := [2]f32{a.pad_axes[.Left_Trigger], a.pad_axes[.Right_Trigger]}
	for i in 0 ..< 2 {
		a.trigger_down[i] =
			triggers[i] >= TRIGGER_DOWN || (a.trigger_down[i] && triggers[i] >= TRIGGER_UP)
	}
	held_pad := a.pad_buttons
	pressed_pad := input.pad_pressed
	if a.trigger_down[0] {held_pad += {.Left_Trigger}}
	if a.trigger_down[1] {held_pad += {.Right_Trigger}}
	if a.trigger_down[0] && !was_trigger[0] {pressed_pad += {.Left_Trigger}}
	if a.trigger_down[1] && !was_trigger[1] {pressed_pad += {.Right_Trigger}}
	a.pad_pressed = pressed_pad

	// Every action's sources, whatever the context.
	raw_down, raw_pressed: bit_set[Action]
	a.key_down, a.key_pressed = {}, {}
	for act in Action {
		if act == .None {continue}
		keys := action_keys(&settings.keys, act)
		for k, i in keys {
			if k == .Unknown || (typing && i == 0) {continue}
			if k in input.held {raw_down, a.key_down = raw_down + {act}, a.key_down + {act}}
			if k in
			   input.pressed {raw_pressed, a.key_pressed = raw_pressed + {act}, a.key_pressed + {act}}
		}
		pads := action_pads(&settings.pad, act)
		for b in pads {
			if b == .None {continue}
			if b in held_pad {raw_down += {act}}
			if b in pressed_pad {raw_pressed += {act}}
		}
	}

	// A context change latches what is held: the A that closes a menu does
	// not jump. (Walking is not latched: it is not a press.)
	if !a.ready {
		a.ready = true
		a.context_ = ctx
	} else if ctx != a.context_ {
		a.context_ = ctx
		a.latched = (raw_down & a.prev_raw) - {.Forward, .Back, .Left, .Right}
	}
	a.prev_raw = raw_down
	a.latched &= raw_down
	in_ctx: bit_set[Action]
	for act in Action {
		if ctx in ACTION_INFO[act].contexts {in_ctx += {act}}
	}
	usable := in_ctx - a.latched
	a.down = raw_down & usable
	a.pressed = raw_pressed & usable
	a.released = a.prev_down - a.down
	a.prev_down = a.down

	// Which device was used last.
	moved := abs(input.mouse.x - a.mouse.x) + abs(input.mouse.y - a.mouse.y) > 4
	a.mouse = input.mouse
	look_mag := abs(input.look.x) + abs(input.look.y)
	if input.pressed != {} || moved || look_mag > 4 {a.device = .Keyboard}
	stick_pushed :=
		max(
			abs(a.pad_axes[.Left_X]),
			abs(a.pad_axes[.Left_Y]),
			abs(a.pad_axes[.Right_X]),
			abs(a.pad_axes[.Right_Y]),
		) >
			0.5 ||
		a.trigger_down[0] ||
		a.trigger_down[1]
	if input.pad_pressed != {} || stick_pushed {
		a.device = .Pad
		if input.pad_last >= 0 && input.pad_last < platform.MAX_PADS {
			p := input.pads[input.pad_last]
			a.pad_family, a.pad_product = p.family, p.product
		}
	}

	// Movement and looking.
	a.move, a.look, a.nav = {}, {}, {}
	if ctx == .World {
		left := [2]f32{a.pad_axes[.Left_X], a.pad_axes[.Left_Y]}
		right := [2]f32{a.pad_axes[.Right_X], a.pad_axes[.Right_Y]}
		if settings.stick_swap {left, right = right, left}
		m := stick_shape(left, settings.stick_dead_zone)
		kbd := [2]f32{}
		if .Forward in a.down {kbd.y += 1}
		if .Back in a.down {kbd.y -= 1}
		if .Right in a.down {kbd.x += 1}
		if .Left in a.down {kbd.x -= 1}
		m += kbd
		if l := math.sqrt(m.x * m.x + m.y * m.y); l > 1 {m /= l}
		a.move = m
		v := stick_shape(right, settings.stick_dead_zone)
		if mag := math.sqrt(v.x * v.x + v.y * v.y); mag > 0 {
			v = v / mag * math.pow(mag, f32(max(settings.stick_response, 1)))
		}
		a.look.x = -v.x * PAD_YAW_RATE * settings.stick_look_speed
		a.look.y =
			v.y * PAD_PITCH_RATE * settings.stick_look_speed * (-1 if settings.stick_invert else 1)
	} else {
		nav_update(a, input, settings, dt)
	}
}

// nav_update: the menu directions: the arrows on each press (the OS repeats
// them); the D-pad and the left stick once, again after NAV_REPEAT_DELAY
// held, then every NAV_REPEAT_INTERVAL.
@(private = "file")
nav_update :: proc(a: ^Actions, input: ^Input_State, settings: ^Settings, dt: f32) {
	arrows := [4]platform.Key{.Up, .Down, .Left, .Right}
	dirs := [4]Action{.Menu_Up, .Menu_Down, .Menu_Left, .Menu_Right}
	dpad := [4]platform.Pad_Button{.Dpad_Up, .Dpad_Down, .Dpad_Left, .Dpad_Right}
	sx, sy := a.pad_axes[.Left_X], a.pad_axes[.Left_Y]
	for i in 0 ..< 4 {
		if arrows[i] in input.pressed {a.nav += {dirs[i]}}
		axis: f32
		switch i {
		case 0:
			axis = sy
		case 1:
			axis = -sy
		case 2:
			axis = -sx
		case 3:
			axis = sx
		}
		// The stick counts past 0.5 on its larger axis, until below 0.35.
		larger := abs(sx) >= abs(sy) if i >= 2 else abs(sy) >= abs(sx)
		on := a.nav_held[i]
		stick := larger && (axis > 0.5 || (on && axis > 0.35))
		held := dpad[i] in a.pad_buttons || stick
		if held && !a.nav_held[i] {
			a.nav += {dirs[i]}
			a.nav_timer[i] = NAV_REPEAT_DELAY
		} else if held {
			a.nav_timer[i] -= dt
			if a.nav_timer[i] <= 0 {
				a.nav += {dirs[i]}
				a.nav_timer[i] = NAV_REPEAT_INTERVAL
			}
		}
		a.nav_held[i] = held
	}
}

action_down :: proc(a: ^Actions, x: Action) -> bool {return x in a.down}
action_pressed :: proc(a: ^Actions, x: Action) -> bool {return x in a.pressed}
// key_action_pressed, key_action_down: by the keyboard alone, in any context
// (the inventory's over-slot keys: a number swaps, the drop key drops).
key_action_pressed :: proc(a: ^Actions, x: Action) -> bool {return x in a.key_pressed}
key_action_down :: proc(a: ^Actions, x: Action) -> bool {return x in a.key_down}
action_released :: proc(a: ^Actions, x: Action) -> bool {return x in a.released}

// hotbar_actions: the hotbar slots' actions, in order.
HOTBAR_ACTIONS :: [5]Action{.Hotbar_1, .Hotbar_2, .Hotbar_3, .Hotbar_4, .Hotbar_5}

// actions_sync: update the actions from the app's input as app_frame does
// (zero time passes).
actions_sync :: proc(app: ^App, dt: f32 = 0) {
	ctx: Action_Context = .World if game_controls(app) else .Menu
	actions_update(&app.actions, &app.input, &app.settings, ctx, app.ui.edit.active, dt)
}

// action_label: what to call action a on screen, for the device last used.
action_label :: proc(app: ^App, a: Action) -> string {
	if app.actions.device == .Pad {
		pads := action_pads(&app.settings.pad, a)
		for b in pads {
			if b !=
			   .None {return pad_button_name(app.actions.pad_family, app.actions.pad_product, b)}
		}
	}
	keys := action_keys(&app.settings.keys, a)
	for k in keys {
		if k != .Unknown {return key_label(&app.window, k)}
	}
	return fmt.tprint(a)
}
