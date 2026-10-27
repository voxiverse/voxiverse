package ui

import "core:testing"

// The on-screen keyboard, driven by pad events only.

@(private = "file")
Kb :: struct {
	fx:        ^Fixture,
	text:      [dynamic]u8,
	submitted: bool,
	lower:     int, // clicks on a button under the keyboard
}

@(private = "file")
kb_frame :: proc(k: ^Kb, in_: Input) {
	ctx := &k.fx.ctx
	begin_frame(ctx, in_, SCREEN, 1)
	if text_input(ctx, "name", &k.text, {100, 20, 300, 36}) {k.submitted = true}
	if button(ctx, "lower", {100, 80, 100, 30}) {k.lower += 1}
	end_frame(ctx)
}

@(private = "file")
kb_open :: proc(t: ^testing.T, k: ^Kb) {
	kb_frame(k, nav({}))
	kb_frame(k, nav({.Confirm}))
	kb_frame(k, nav({}))
	kb_frame(k, nav({}))
	testing.expect(t, osk_is_open(&k.fx.ctx))
}

// kb_press moves to the key saying label by directions and presses Confirm.
@(private = "file")
kb_press :: proc(t: ^testing.T, k: ^Kb, label: string, loc := #caller_location) {
	ctx := &k.fx.ctx
	for _ in 0 ..< 40 {
		if focused_label(ctx) == label {break}
		target, found := find_widget(ctx, label)
		if !testing.expectf(t, found, "no key %q", label, loc = loc) {return}
		// The way the pad goes: the direction nav_pick would take toward it.
		from, _ := find_widget(ctx, focused_label(ctx))
		dir: Nav
		switch {
		case target.y > from.y + 1:
			dir = .Down
		case target.y < from.y - 1:
			dir = .Up
		case target.x > from.x:
			dir = .Right
		case:
			dir = .Left
		}
		kb_frame(k, nav({dir}))
	}
	testing.expectf(
		t,
		focused_label(ctx) == label,
		"could not reach %q (at %q)",
		label,
		focused_label(ctx),
		loc = loc,
	)
	kb_frame(k, nav({.Confirm}))
	kb_frame(k, nav({}))
}

@(private = "file")
kb_type :: proc(t: ^testing.T, k: ^Kb, s: string) {
	for i in 0 ..< len(s) {kb_press(t, k, s[i:i + 1])}
}

@(test)
test_keyboard_types_by_nav_and_confirm :: proc(t: ^testing.T) {
	k := Kb {
		fx = setup(t),
	}
	defer teardown(k.fx)
	defer delete(k.text)
	kb_open(t, &k)
	testing.expect_value(t, focused_label(&k.fx.ctx), "h") // opens on h the first time
	kb_type(t, &k, "ad1")
	testing.expect_value(t, string(k.text[:]), "ad1")

	// X is Backspace, Y a space.
	kb_frame(&k, nav({.Secondary}))
	testing.expect_value(t, string(k.text[:]), "ad")
	kb_frame(&k, nav({.Tertiary}))
	testing.expect_value(t, string(k.text[:]), "ad ")
	kb_press(t, &k, "Backspace")
	testing.expect_value(t, string(k.text[:]), "ad")

	// Shift: capitals until pressed again; the stick press is Shift too.
	kb_press(t, &k, "Shift")
	kb_type(t, &k, "P") // (the labels are capitals now)
	testing.expect_value(t, string(k.text[:]), "adP")
}

@(test)
test_keyboard_pages_done_and_cancel :: proc(t: ^testing.T) {
	k := Kb {
		fx = setup(t),
	}
	defer teardown(k.fx)
	defer delete(k.text)
	kb_open(t, &k)
	ctx := &k.fx.ctx
	kb_press(t, &k, "&123")
	kb_press(t, &k, "@")
	kb_press(t, &k, "abc")
	kb_press(t, &k, "_")
	testing.expect_value(t, string(k.text[:]), "@_")
	kb_frame(&k, {mouse = {-100, -100}, pad = true, osk_shift = true})
	kb_press(t, &k, "A")
	testing.expect_value(t, string(k.text[:]), "@_A")
	kb_press(t, &k, "Shift") // off again

	// The bumpers move the cursor: the next key goes before the last.
	kb_frame(&k, {mouse = {-100, -100}, pad = true, osk_cursor = -1})
	kb_press(t, &k, "b")
	testing.expect_value(t, string(k.text[:]), "@_bA")

	// Real typing works while it is open; Backspace and Enter too.
	kb_frame(&k, {mouse = {-100, -100}, text = {'z'}})
	testing.expect_value(t, string(k.text[:]), "@_bzA")
	kb_frame(&k, keys({.Backspace}))
	testing.expect_value(t, string(k.text[:]), "@_bA")

	// B closes it, the text kept.
	testing.expect(t, osk_cancel(ctx))
	for _ in 0 ..< 3 {kb_frame(&k, nav({}))}
	testing.expect(t, !osk_is_open(ctx))
	testing.expect_value(t, string(k.text[:]), "@_bA")
	testing.expect(t, !k.submitted)
	testing.expect_value(t, focused_label(ctx), "name") // focus is back on the field

	// Done submits.
	kb_frame(&k, nav({.Confirm}))
	for _ in 0 ..< 2 {kb_frame(&k, nav({}))}
	testing.expect(t, osk_is_open(ctx))
	kb_press(t, &k, "Done")
	testing.expect(t, k.submitted)
	for _ in 0 ..< 2 {kb_frame(&k, nav({}))}
	testing.expect(t, !osk_is_open(ctx))

	// Start is Done as well.
	kb_frame(&k, nav({.Confirm}))
	for _ in 0 ..< 2 {kb_frame(&k, nav({}))}
	k.submitted = false
	kb_frame(&k, nav({.Start}))
	testing.expect(t, k.submitted && !osk_is_open(ctx))
}

@(test)
test_keyboard_makes_lower_layers_inert :: proc(t: ^testing.T) {
	k := Kb {
		fx = setup(t),
	}
	defer teardown(k.fx)
	defer delete(k.text)
	kb_open(t, &k)
	ctx := &k.fx.ctx
	p := Vec2{150, 95}
	kb_frame(&k, at(p))
	kb_frame(&k, press(p))
	kb_frame(&k, release(p))
	testing.expect_value(t, k.lower, 0)
	// It opens where it was left: the key used last.
	kb_press(t, &k, "q")
	testing.expect(t, osk_cancel(ctx))
	for _ in 0 ..< 3 {kb_frame(&k, nav({}))}
	kb_frame(&k, nav({.Confirm}))
	for _ in 0 ..< 2 {kb_frame(&k, nav({}))}
	testing.expect_value(t, focused_label(ctx), "q")
	// And with the keyboard gone, the lower button clicks again.
	osk_cancel(ctx)
	for _ in 0 ..< 3 {kb_frame(&k, at(p))}
	kb_frame(&k, press(p))
	kb_frame(&k, release(p))
	testing.expect_value(t, k.lower, 1)
}
