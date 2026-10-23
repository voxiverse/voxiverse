package ui

import "core:log"
import "core:strings"
import "core:testing"

import "../font"

// Behaviour tests: real frames with scripted input, no window or GPU.

@(private = "file")
FONT_DATA := #load("../assets/fonts/jetbrains_mono_regular.ttf")

@(private = "file")
SCREEN :: Vec2{800, 600}

@(private = "file")
Fixture :: struct {
	font: font.Font,
	ctx:  Context,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> ^Fixture {
	fx := new(Fixture)
	ok: bool
	fx.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, init(&fx.ctx, &fx.font))
	return fx
}

@(private = "file")
teardown :: proc(fx: ^Fixture) {
	destroy(&fx.ctx)
	free(fx)
}

@(private = "file")
at :: proc(p: Vec2) -> Input {
	return {mouse = p}
}

@(private = "file")
press :: proc(p: Vec2) -> Input {
	return {mouse = p, mouse_down = {.Left}, mouse_pressed = {.Left}}
}

@(private = "file")
hold :: proc(p: Vec2) -> Input {
	return {mouse = p, mouse_down = {.Left}}
}

@(private = "file")
release :: proc(p: Vec2) -> Input {
	return {mouse = p, mouse_released = {.Left}}
}

@(private = "file")
keys :: proc(k: bit_set[Key], mods: bit_set[Modifier] = {}) -> Input {
	return {mouse = {-100, -100}, keys_pressed = k, modifiers = mods}
}

@(private = "file")
BUTTON_A :: Rect{100, 100, 200, 40}
@(private = "file")
BUTTON_B :: Rect{100, 160, 200, 40}
@(private = "file")
INSIDE_A :: Vec2{150, 120}
@(private = "file")
OUTSIDE :: Vec2{600, 500}

// two_buttons runs one frame with buttons A and B; returns which clicked.
@(private = "file")
two_buttons :: proc(ctx: ^Context, input: Input) -> (a, b: bool) {
	begin_frame(ctx, input, SCREEN, 1)
	a = button(ctx, "A", BUTTON_A)
	b = button(ctx, "B", BUTTON_B)
	end_frame(ctx)
	return
}

@(test)
test_click_fires_on_release :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	two_buttons(ctx, at(INSIDE_A)) // hover is resolved at end of frame
	a, _ := two_buttons(ctx, press(INSIDE_A))
	testing.expect(t, !a, "a press alone must not click")
	a, _ = two_buttons(ctx, hold(INSIDE_A))
	testing.expect(t, !a)
	a, _ = two_buttons(ctx, release(INSIDE_A))
	testing.expect(t, a, "release over the button clicks")
	a, _ = two_buttons(ctx, at(INSIDE_A))
	testing.expect(t, !a, "one click per release")
}

@(test)
test_dragging_off_cancels_click :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	two_buttons(ctx, at(INSIDE_A))
	two_buttons(ctx, press(INSIDE_A))
	two_buttons(ctx, hold(OUTSIDE))
	a, b := two_buttons(ctx, release(OUTSIDE))
	testing.expect(t, !a && !b, "releasing elsewhere cancels")
	// Pressing elsewhere and releasing over A doesn't click A either.
	two_buttons(ctx, press(OUTSIDE))
	two_buttons(ctx, hold(INSIDE_A))
	a, _ = two_buttons(ctx, release(INSIDE_A))
	testing.expect(t, !a, "a press that started elsewhere doesn't click")
}

// modal_frame: a base button covering the screen and a modal dialog with
// one button.
@(private = "file")
MODAL_BUTTON :: Rect{300, 250, 200, 40}

@(private = "file")
modal_frame :: proc(
	ctx: ^Context,
	input: Input,
	show_modal: bool,
) -> (
	base_clicked, modal_clicked: bool,
	base_hovered: bool,
) {
	begin_frame(ctx, input, SCREEN, 1)
	base_clicked = button(ctx, "background", {0, 0, 800, 600})
	base_hovered = ctx.hot == get_id(ctx, "background")
	if show_modal {
		prev := begin_layer(ctx, .Modal)
		backdrop(ctx)
		modal_clicked = button(ctx, "OK", MODAL_BUTTON)
		end_layer(ctx, prev)
	}
	end_frame(ctx)
	return
}

@(test)
test_modal_blocks_lower_layers :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	over_modal := Vec2{350, 260}
	away_from_modal := Vec2{50, 50}

	// Without the modal the background button works.
	modal_frame(ctx, at(away_from_modal), false)
	modal_frame(ctx, press(away_from_modal), false)
	base, _, _ := modal_frame(ctx, release(away_from_modal), false)
	testing.expect(t, base, "background clickable without modal")

	// With it, the modal button wins where they overlap...
	modal_frame(ctx, at(over_modal), true)
	modal_frame(ctx, press(over_modal), true)
	ok: bool
	base, ok, _ = modal_frame(ctx, release(over_modal), true)
	testing.expect(t, ok, "modal button clicks")
	testing.expect(t, !base, "the button under it doesn't")

	// ...and the background is inert even where the modal doesn't cover it.
	_, _, hovered := modal_frame(ctx, at(away_from_modal), true)
	modal_frame(ctx, press(away_from_modal), true)
	base, _, _ = modal_frame(ctx, release(away_from_modal), true)
	testing.expect(t, !hovered && !base, "lower layers are inert while a modal is open")
}

@(test)
test_keyboard_focus :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	id_a, id_b := get_id(ctx, "A"), get_id(ctx, "B")
	two_buttons(ctx, at(OUTSIDE))
	testing.expect_value(t, ctx.focused, Id(0))

	two_buttons(ctx, keys({.Tab}))
	testing.expect_value(t, ctx.focused, id_a)
	testing.expect(t, ctx.focus_visible)
	two_buttons(ctx, keys({.Tab}))
	testing.expect_value(t, ctx.focused, id_b)
	two_buttons(ctx, keys({.Tab}))
	testing.expect_value(t, ctx.focused, id_a) // wraps
	two_buttons(ctx, keys({.Tab}, {.Shift}))
	testing.expect_value(t, ctx.focused, id_b)
	two_buttons(ctx, keys({.Up}))
	testing.expect_value(t, ctx.focused, id_a)

	a, b := two_buttons(ctx, keys({.Enter}))
	testing.expect(t, a && !b, "Enter activates the focused button only")

	// Hovering B doesn't steal focus from A; clicking B does.
	two_buttons(ctx, at({150, 180}))
	two_buttons(ctx, at({150, 180}))
	testing.expect_value(t, ctx.focused, id_a)
	two_buttons(ctx, press({150, 180}))
	testing.expect_value(t, ctx.focused, id_b)
	testing.expect(t, !ctx.focus_visible, "mouse use hides the focus ring")
}

// A widget focused before a modal opened keeps focus underneath it, but the
// keyboard must not activate it while the modal is up.
@(test)
test_modal_blocks_keyboard_on_lower_layers :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	modal_frame(ctx, at(OUTSIDE), false)
	modal_frame(ctx, keys({.Tab}), false)
	testing.expect_value(t, ctx.focused, get_id(ctx, "background"))
	modal_frame(ctx, at(OUTSIDE), true)
	base, _, _ := modal_frame(ctx, keys({.Enter}), true)
	testing.expect(t, !base, "Enter must not reach a widget under a modal")
}

@(test)
test_focus_stays_in_modal :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	modal_frame(ctx, at(OUTSIDE), true)
	for _ in 0 ..< 3 {
		modal_frame(ctx, keys({.Tab}), true)
		testing.expect_value(t, ctx.focused, get_id(ctx, "OK"))
	}
}

@(private = "file")
text_frame :: proc(ctx: ^Context, input: Input, text: ^[dynamic]u8) -> (submitted: bool) {
	begin_frame(ctx, input, SCREEN, 1)
	submitted = text_input(ctx, "name", text, {100, 100, 300, 36})
	button(ctx, "after", {100, 150, 100, 36})
	end_frame(ctx)
	return
}

@(test)
test_text_input_editing :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	text := make([dynamic]u8)
	defer delete(text)
	field := Vec2{150, 115}

	text_frame(ctx, at(field), &text)
	text_frame(ctx, press(field), &text) // click focuses
	text_frame(ctx, release(field), &text)
	typed := []rune{'h', 'é', 'l', 'l', 'o'}
	text_frame(ctx, {mouse = field, text = typed}, &text)
	testing.expect_value(t, string(text[:]), "héllo")

	text_frame(ctx, keys({.Backspace}), &text)
	text_frame(ctx, keys({.Backspace}), &text)
	testing.expect_value(t, string(text[:]), "hél")
	text_frame(ctx, keys({.Left}), &text)
	text_frame(ctx, keys({.Left}), &text) // over the 2-byte é
	text_frame(ctx, {mouse = {-100, -100}, text = []rune{'X'}}, &text)
	testing.expect_value(t, string(text[:]), "hXél")

	// Arrows edit text instead of moving widget focus.
	text_frame(ctx, keys({.Down}), &text)
	testing.expect_value(t, ctx.focused, get_id(ctx, "name"))

	text_frame(ctx, keys({.A}, {.Ctrl}), &text)
	text_frame(ctx, {mouse = {-100, -100}, text = []rune{'o', 'k'}}, &text)
	testing.expect_value(t, string(text[:]), "ok")
	testing.expect(t, text_frame(ctx, keys({.Enter}), &text), "Enter submits")
}

@(test)
test_clipping_and_culling :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	begin_frame(ctx, at(OUTSIDE), SCREEN, 1)
	push_clip_rect(ctx, {50, 50, 40, 30})
	draw_text(
		ctx,
		{50, 50, 400, 30},
		"a long line that runs far past the clip rect",
		16,
		{255, 255, 255, 255},
	)
	pop_clip_rect(ctx)
	end_frame(ctx)
	out := ctx.output
	testing.expect_value(t, len(out.commands), 1)
	testing.expect_value(t, out.commands[0].scissor, [4]i32{50, 50, 40, 30})
	glyphs := len(out.vertices) / 4
	testing.expect(t, glyphs > 0 && glyphs <= 6, "glyphs outside the clip are culled")
}

@(test)
test_layers_draw_in_order :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	begin_frame(ctx, at(OUTSIDE), SCREEN, 1)
	prev := begin_layer(ctx, .Tooltip)
	fill_rect(ctx, {0, 0, 10, 10}, {1, 1, 1, 255})
	end_layer(ctx, prev)
	fill_rect(ctx, {0, 0, 10, 10}, {2, 2, 2, 255}) // base, drawn later in code
	end_frame(ctx)
	out := ctx.output
	testing.expect_value(t, len(out.vertices), 8)
	testing.expect_value(t, out.vertices[0].color.r, 2) // base first
	testing.expect_value(t, out.vertices[4].color.r, 1) // tooltip on top
}

@(test)
test_glyph_atlas_uploads_once :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	frame :: proc(ctx: ^Context) -> [2]int {
		begin_frame(ctx, at(OUTSIDE), SCREEN, 1)
		draw_text(ctx, {0, 0, 300, 30}, "Voxiverse", 16, {255, 255, 255, 255})
		end_frame(ctx)
		return ctx.output.atlas_dirty_rows
	}
	first := frame(ctx)
	testing.expect(t, first[1] > first[0], "new glyphs mark rows dirty")
	second := frame(ctx)
	testing.expect(t, second[1] <= second[0], "cached glyphs need no upload")
	testing.expect_value(t, len(ctx.output.vertices), 4 * len("Voxiverse"))
}

@(test)
test_layout_cuts :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	begin_frame(ctx, at(OUTSIDE), SCREEN, 1)
	layout_begin(ctx, {10, 20, 200, 300}, .Vertical, 5)
	a := next(ctx, 40)
	b := next(ctx, 40)
	layout_end(ctx)
	end_frame(ctx)
	testing.expect_value(t, a, Rect{10, 20, 200, 40})
	testing.expect_value(t, b, Rect{10, 65, 200, 40})
}

// The bug found by hand in M2: the title screen's "Quit" and the quit
// dialog's "Quit" shared an id; the inert one under the modal consumed the
// mouse release, so the dialog's button never clicked.
@(private = "file")
quit_frames :: proc(ctx: ^Context, input: Input, scope_dialog: bool) -> (dialog_quit: bool) {
	begin_frame(ctx, input, SCREEN, 1)
	button(ctx, "Quit", {100, 400, 200, 40}) // title screen
	prev := begin_layer(ctx, .Modal)
	if scope_dialog {push_id(ctx, "quit dialog")}
	dialog_quit = button(ctx, "Quit", MODAL_BUTTON)
	if scope_dialog {pop_id(ctx)}
	end_layer(ctx, prev)
	end_frame(ctx)
	return
}

@(test)
test_duplicate_ids_are_reported :: proc(t: ^testing.T) {
	context.logger = expect_duplicate_id_errors(context.logger)
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	quit_frames(ctx, at(OUTSIDE), false)
	testing.expect(t, ctx.errors > 0, "two widgets with one id must be reported")
	errors := ctx.errors
	quit_frames(ctx, at(OUTSIDE), true)
	testing.expect_value(t, ctx.errors, errors) // scoped: no new errors
}

@(test)
test_modal_button_clicks_despite_same_label_below :: proc(t: ^testing.T) {
	context.logger = expect_duplicate_id_errors(context.logger)
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	over := Vec2{350, 260}
	for scoped in ([]bool{false, true}) {
		quit_frames(ctx, at(over), scoped)
		quit_frames(ctx, press(over), scoped)
		testing.expectf(
			t,
			quit_frames(ctx, release(over), scoped),
			"dialog Quit must click (scoped=%v)",
			scoped,
		)
	}
}

// expect_duplicate_id_errors drops the (deliberately triggered) duplicate-id
// error and forwards everything else: the test runner learns of failed
// expectations through the logger, so swallowing all of it would hide them.
@(private = "file")
expect_duplicate_id_errors :: proc(next: log.Logger) -> log.Logger {
	@(static) forward: log.Logger
	forward = next
	return log.Logger {
		procedure = proc(
			data: rawptr,
			level: log.Level,
			text: string,
			options: log.Options,
			location := #caller_location,
		) {
			if strings.has_prefix(text, "ui duplicate widget id") {return}
			forward.procedure(forward.data, level, text, options, location)
		},
		lowest_level = next.lowest_level,
		options = next.options,
	}
}
