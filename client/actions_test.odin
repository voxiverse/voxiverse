package client

import "core:math"
import "core:os"
import "core:reflect"
import "core:testing"

import "../common/game"
import "platform"

@(private = "file")
Rig :: struct {
	in_:      Input_State,
	a:        Actions,
	settings: Settings,
}

@(private = "file")
rig_make :: proc() -> ^Rig {
	r := new(Rig)
	r.settings = SETTINGS_DEFAULTS
	return r
}

@(private = "file")
rig_free :: proc(r: ^Rig) {
	input_destroy(&r.in_)
	free(r)
}

// frame: one frame of events, then the actions.
@(private = "file")
frame :: proc(
	r: ^Rig,
	ctx: Action_Context,
	events: ..platform.Event,
	typing := false,
	dt: f32 = 1.0 / 60,
) {
	input_update(&r.in_, events)
	actions_update(&r.a, &r.in_, &r.settings, ctx, typing, dt)
}

@(private = "file")
key :: proc(k: platform.Key, pressed: bool) -> platform.Event {
	return platform.Key_Event{key = k, symbol = k, pressed = pressed}
}

@(private = "file")
axis :: proc(a: platform.Pad_Axis, v: f32) -> platform.Event {
	return platform.Pad_Axis_Event{pad = 0, axis = a, value = v}
}

@(private = "file")
button :: proc(b: platform.Pad_Button, pressed: bool) -> platform.Event {
	return platform.Pad_Button_Event{pad = 0, button = b, pressed = pressed}
}

@(private = "file")
connect :: proc() -> platform.Event {
	return platform.Pad_Connect_Event{pad = 0, connected = true, family = .Xbox}
}

@(test)
test_actions_keys :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	frame(r, .World, key(.W, true))
	testing.expect_value(t, r.a.move, [2]f32{0, 1})
	frame(r, .World, key(.W, false))
	testing.expect_value(t, r.a.move, [2]f32{0, 0})

	// Q is drop in the world and the tab step in a menu, never both.
	frame(r, .World, key(.Q, true))
	testing.expect(t, action_pressed(&r.a, .Drop) && !action_pressed(&r.a, .Tab_Prev))
	frame(r, .World, key(.Q, false))
	frame(r, .Menu, key(.Q, true))
	testing.expect(t, !action_pressed(&r.a, .Drop) && action_pressed(&r.a, .Tab_Prev))
	frame(r, .Menu, key(.Q, false))

	// Typing: bound keys do nothing, Escape still backs out.
	frame(r, .Menu, key(.Q, true), typing = true)
	testing.expect(t, !action_pressed(&r.a, .Tab_Prev))
	frame(r, .Menu, key(.Q, false), typing = true)
	frame(r, .Menu, key(.K, true), typing = true)
	testing.expect(t, !action_pressed(&r.a, .Stats))
	frame(r, .Menu, key(.K, false), typing = true)
	frame(r, .Menu, key(.Escape, true), typing = true)
	testing.expect(t, action_pressed(&r.a, .Menu_Back))
}

@(test)
test_actions_latch :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	frame(r, .Menu)
	frame(r, .Menu, key(.Space, true))
	testing.expect(t, action_pressed(&r.a, .Menu_Confirm) && !action_pressed(&r.a, .Jump))
	// Space still held as the menu closes: no jump until released and pressed again.
	frame(r, .World)
	testing.expect(t, !action_down(&r.a, .Jump))
	frame(r, .World)
	testing.expect(t, !action_down(&r.a, .Jump) && !action_pressed(&r.a, .Jump))
	frame(r, .World, key(.Space, false))
	frame(r, .World, key(.Space, true))
	testing.expect(t, action_pressed(&r.a, .Jump) && action_down(&r.a, .Jump))
	// The pad's A the same.
	frame(r, .World, key(.Space, false), connect(), button(.A, true))
	frame(r, .Menu)
	testing.expect(t, !action_pressed(&r.a, .Menu_Confirm) && !action_down(&r.a, .Menu_Confirm))
}

@(test)
test_stick_shape :: proc(t: ^testing.T) {
	near :: proc(t: ^testing.T, got, want: [2]f32, loc := #caller_location) {
		testing.expectf(
			t,
			abs(got.x - want.x) < 1e-4 && abs(got.y - want.y) < 1e-4,
			"got %v want %v",
			got,
			want,
			loc = loc,
		)
	}
	near(t, stick_shape({0.1, 0}, 0.15), {0, 0})
	near(t, stick_shape({0, 0.96}, 0.15), {0, 1})
	m := f32(0.35 / 0.8) // (0.5 - 0.15) / 0.8
	near(t, stick_shape({0.3, 0.4}, 0.15), {0.6 * m, 0.8 * m})
}

@(test)
test_actions_sticks :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	r.settings.stick_dead_zone = 0.05 // half deflection then shapes to exactly half
	frame(r, .World, connect(), axis(.Right_X, 0.5))
	// Response 2: a quarter of the full rate; yaw turns the other way from x.
	want := f32(-0.25 * PAD_YAW_RATE)
	testing.expectf(
		t,
		abs(r.a.look.x - want) < 1e-4 && r.a.look.y == 0,
		"look %v want %v",
		r.a.look,
		want,
	)
	r.settings.stick_response = 1
	frame(r, .World)
	testing.expectf(t, abs(r.a.look.x + 0.5 * PAD_YAW_RATE) < 1e-4, "linear look %v", r.a.look)
	r.settings.stick_response = 2
	r.settings.stick_look_speed = 2
	frame(r, .World)
	testing.expectf(t, abs(r.a.look.x + 0.5 * PAD_YAW_RATE) < 1e-4, "double speed %v", r.a.look)
	r.settings.stick_look_speed = 1

	// Pitch: up looks up, inverted down.
	frame(r, .World, axis(.Right_X, 0), axis(.Right_Y, 1))
	testing.expect(t, r.a.look.y > 0)
	r.settings.stick_invert = true
	frame(r, .World)
	testing.expect(t, r.a.look.y < 0)
	r.settings.stick_invert = false

	// Swapped: the left stick looks and the right one moves.
	r.settings.stick_swap = true
	frame(r, .World, axis(.Right_Y, 0), axis(.Left_X, 1), axis(.Right_X, 0))
	testing.expect(t, r.a.look.x < 0 && r.a.move == {0, 0})
	frame(r, .World, axis(.Left_X, 0), axis(.Right_Y, 1))
	testing.expect(t, r.a.move.y > 0.99 && r.a.look == {0, 0})
	r.settings.stick_swap = false
	frame(r, .World, axis(.Right_Y, 0))

	// A stick and W together stay at length 1.
	frame(r, .World, key(.W, true), axis(.Left_X, 1))
	l := math.sqrt(r.a.move.x * r.a.move.x + r.a.move.y * r.a.move.y)
	testing.expectf(t, abs(l - 1) < 1e-4 && r.a.move.x > 0 && r.a.move.y > 0, "move %v", r.a.move)
}

@(test)
test_actions_triggers :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	frame(r, .World, connect(), axis(.Right_Trigger, 0.55))
	testing.expect(t, action_down(&r.a, .Attack) && action_pressed(&r.a, .Attack))
	frame(r, .World, axis(.Right_Trigger, 0.45))
	testing.expect(t, action_down(&r.a, .Attack) && !action_pressed(&r.a, .Attack))
	frame(r, .World, axis(.Right_Trigger, 0.35))
	testing.expect(t, !action_down(&r.a, .Attack) && action_released(&r.a, .Attack))
	frame(r, .World, axis(.Left_Trigger, 1))
	testing.expect(t, action_pressed(&r.a, .Use))
}

@(test)
test_actions_pad_to_player :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	s := new(Session)
	defer free(s)
	frame(r, .World, connect(), axis(.Left_Y, 1), button(.Left_Stick, true), button(.A, true))
	in_ := player_input(&r.a, s)
	q := game.quantize_input(in_)
	testing.expect_value(t, q.move, [2]f32{0, 1})
	testing.expect(t, .Sprint in in_.buttons && .Jump in in_.buttons)
	frame(r, .World, axis(.Left_Y, 0), button(.Left_Stick, false), button(.A, false))
	in_ = player_input(&r.a, s)
	testing.expect(t, in_.move == {0, 0} && in_.buttons == {})
	// A disconnect clears the pad's held state.
	frame(r, .World, axis(.Left_Y, 1))
	frame(r, .World, platform.Pad_Connect_Event{pad = 0, connected = false})
	testing.expect_value(t, r.a.move, [2]f32{0, 0})
}

@(test)
test_actions_device :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	frame(r, .World, key(.W, true))
	testing.expect_value(t, r.a.device, Device.Keyboard)
	frame(r, .World, connect(), button(.B, true))
	testing.expect_value(t, r.a.device, Device.Pad)
	testing.expect_value(t, r.a.pad_family, platform.Pad_Family.Xbox)
	frame(r, .World, button(.B, false), key(.E, true))
	testing.expect_value(t, r.a.device, Device.Keyboard)
	frame(r, .World, key(.E, false), axis(.Right_X, 0.8))
	testing.expect_value(t, r.a.device, Device.Pad)
}

@(test)
test_actions_nav :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_free(r)
	frame(r, .Menu, connect(), button(.Dpad_Down, true))
	testing.expect(t, .Menu_Down in r.a.nav)
	frame(r, .Menu, dt = 0.3)
	testing.expect(t, r.a.nav == {})
	frame(r, .Menu, dt = 0.2) // past the delay
	testing.expect(t, .Menu_Down in r.a.nav)
	frame(r, .Menu, dt = 0.05)
	testing.expect(t, r.a.nav == {})
	frame(r, .Menu, dt = 0.06) // the interval
	testing.expect(t, .Menu_Down in r.a.nav)
	frame(r, .Menu, button(.Dpad_Down, false), axis(.Left_X, 0.8))
	testing.expect(t, .Menu_Right in r.a.nav)
	frame(r, .Menu, axis(.Left_X, 0.4), dt = 0.01)
	testing.expect(t, r.a.nav == {}) // still held (hysteresis), no repeat yet
	frame(r, .Menu, key(.Up, true))
	testing.expect(t, .Menu_Up in r.a.nav)
}

@(test)
test_actions_coverage :: proc(t: ^testing.T) {
	keys, pad := DEFAULT_BINDINGS, DEFAULT_PAD_BINDINGS
	pad_covered, key_covered: bit_set[Action]
	for c in PAD_COVERED_BY {pad_covered += {c.action}}
	for c in KEY_COVERED_BY {key_covered += {c.action}}
	for a in Action {
		if a == .None {continue}
		info := ACTION_INFO[a]
		on_key := action_key(&keys, a) != nil || info.fixed_keys[0] != .Unknown
		on_pad := action_pad(&pad, a) != nil || info.fixed_pad[0] != .None
		testing.expectf(t, on_key || a in key_covered, "%v is not reachable on the keyboard", a)
		testing.expectf(t, on_pad || a in pad_covered, "%v is not reachable on a pad", a)
		testing.expectf(t, info.label != "", "%v has no label", a)
	}
	// Every field of both binding structs belongs to some action.
	for f in reflect.struct_fields_zipped(Bindings) {
		found := false
		for a in Action {
			if k := action_key(&keys, a);
			   k != nil && uintptr(k) - uintptr(&keys) == f.offset {found = true}
		}
		testing.expectf(t, found, "Bindings.%s is no action's key", f.name)
	}
	for f in reflect.struct_fields_zipped(Pad_Bindings) {
		found := false
		for a in Action {
			if b := action_pad(&pad, a);
			   b != nil && uintptr(b) - uintptr(&pad) == f.offset {found = true}
		}
		testing.expectf(t, found, "Pad_Bindings.%s is no action's button", f.name)
		testing.expect(t, find_pad_var(f.name), "no variable")
	}
	// Each action's field name is what the tables call it.
	for a in Action {
		if k := action_key(&keys, a); k != nil {
			f := reflect.struct_field_by_name(Bindings, action_field(a))
			testing.expectf(
				t,
				f.type != nil && uintptr(k) - uintptr(&keys) == f.offset,
				"%v: the field name",
				a,
			)
		}
	}
	// The defaults clash with nothing.
	kc, pc := binding_conflicts(&keys, &pad)
	testing.expectf(t, kc == {} && pc == {}, "default bindings clash: %v %v", kc, pc)
}

@(private = "file")
find_pad_var :: proc(name: string) -> bool {
	for v in PAD_BINDING_VARS {
		if v.field == name {return true}
	}
	return false
}

@(test)
test_binding_conflicts :: proc(t: ^testing.T) {
	keys, pad := DEFAULT_BINDINGS, DEFAULT_PAD_BINDINGS
	pad.jump = .X // drop's button, in the same context
	_, pc := binding_conflicts(&keys, &pad)
	testing.expect(t, .Jump in pc && .Drop in pc)
	testing.expect(t, .Menu_Confirm not_in pc, "A is jump's too, but in another context")
	pad = DEFAULT_PAD_BINDINGS
	pad.sneak = .Start // the fixed pause button
	_, pc = binding_conflicts(&keys, &pad)
	testing.expect(t, .Sneak in pc && .Pause in pc)
	keys.attack = .Space
	kc, _ := binding_conflicts(&keys, &pad)
	testing.expect(t, .Attack in kc && .Jump in kc)
}

@(test)
test_pad_button_names :: proc(t: ^testing.T) {
	testing.expect_value(t, pad_button_name(.Xbox, 0, .Back), "View")
	testing.expect_value(t, pad_button_name(.Generic, 0, .Left_Bumper), "LB")
	testing.expect_value(t, pad_button_name(.PlayStation, 0x0ce6, .Back), "Create")
	testing.expect_value(t, pad_button_name(.PlayStation, 0x09cc, .Back), "Share")
	testing.expect_value(t, pad_button_name(.PlayStation, 0, .A), "Cross")
	testing.expect_value(t, pad_button_name(.Switch, 0, .A), "B")
	testing.expect_value(t, pad_button_name(.Switch, 0, .Right_Trigger), "ZR")
	testing.expect_value(t, pad_button_name(.Steam_Deck, 0, .Right_Stick), "R3")
	testing.expect_value(t, pad_button_name(.Xbox, 0, .Dpad_Up), "D-pad Up")
	testing.expect_value(t, pad_button_name(.Xbox, 0, .None), "(none)")
}

@(test)
test_pad_settings_round_trip :: proc(t: ^testing.T) {
	path := "build/test/pad_settings_test.cfg"
	os.make_directory_all("build/test")
	os.set_env("VX_SETTINGS", path)
	defer os.unset_env("VX_SETTINGS")
	defer os.remove(path)

	// An older file: no pad. or stick_ lines; defaults, nothing odd.
	_ = os.write_entire_file(path, transmute([]u8)string("fov = 90\nkey.jump = g\n"))
	old: App
	settings_load(&old)
	testing.expect(t, old.settings.pad == DEFAULT_PAD_BINDINGS)
	testing.expect_value(t, old.settings.fov, 90)
	testing.expect_value(t, old.settings.keys.jump, platform.Key.G)

	a: App
	a.settings = SETTINGS_DEFAULTS
	a.settings.pad.jump, a.settings.pad.hotbar_next, a.settings.pad.attack = .X, .Dpad_Right, .None
	a.settings.stick_look_speed, a.settings.stick_dead_zone = 1.75, 0.2
	a.settings.stick_response, a.settings.stick_invert, a.settings.stick_swap = 3, true, true
	settings_save(&a)
	b: App
	settings_load(&b)
	testing.expect(t, a.settings == b.settings)
	testing.expect_value(t, b.settings.pad.jump, platform.Pad_Button.X)
	testing.expect_value(t, b.settings.pad.attack, platform.Pad_Button.None)
	testing.expect_value(t, b.settings.stick_response, 3)
	free_all(context.temp_allocator)
}
