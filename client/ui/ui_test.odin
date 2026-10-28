package ui

import "core:log"
import "core:math"
import "core:strings"
import "core:testing"

import "../font"

// Behaviour tests: real frames with scripted input, no window or GPU.

FONT_DATA := #load("../../assets/fonts/jetbrains_mono_regular.ttf")

SCREEN :: Vec2{800, 600}

Fixture :: struct {
	font: font.Font,
	ctx:  Context,
}

setup :: proc(t: ^testing.T) -> ^Fixture {
	fx := new(Fixture)
	ok: bool
	fx.font, ok = font.load(FONT_DATA)
	testing.expect(t, ok)
	testing.expect(t, init(&fx.ctx, &fx.font))
	return fx
}

teardown :: proc(fx: ^Fixture) {
	destroy(&fx.ctx)
	free(fx)
}

at :: proc(p: Vec2) -> Input {
	return {mouse = p}
}

press :: proc(p: Vec2) -> Input {
	return {mouse = p, mouse_down = {.Left}, mouse_pressed = {.Left}}
}

hold :: proc(p: Vec2) -> Input {
	return {mouse = p, mouse_down = {.Left}}
}

release :: proc(p: Vec2) -> Input {
	return {mouse = p, mouse_released = {.Left}}
}

keys :: proc(k: bit_set[Key], mods: bit_set[Modifier] = {}) -> Input {
	return {mouse = {-100, -100}, keys_pressed = k, modifiers = mods}
}

BUTTON_A :: Rect{100, 100, 200, 40}
BUTTON_B :: Rect{100, 160, 200, 40}
INSIDE_A :: Vec2{150, 120}
OUTSIDE :: Vec2{600, 500}

// two_buttons runs one frame with buttons A and B; returns which clicked.
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
MODAL_BUTTON :: Rect{300, 250, 200, 40}

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

	// Ctrl+A: the start of the line (readline), not select-all.
	text_frame(ctx, keys({.A}, {.Ctrl}), &text)
	text_frame(ctx, {mouse = {-100, -100}, text = []rune{'>'}}, &text)
	testing.expect_value(t, string(text[:]), ">hXél")
	testing.expect(t, text_frame(ctx, keys({.Enter}), &text), "Enter submits")
}

// The readline keys: moving by characters and words, killing and yanking.
@(test)
test_text_input_readline :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	text := make([dynamic]u8)
	defer delete(text)
	field := Vec2{150, 115}
	text_frame(ctx, at(field), &text)
	text_frame(ctx, press(field), &text)
	text_frame(ctx, release(field), &text)
	type :: proc(ctx: ^Context, text: ^[dynamic]u8, s: string) {
		runes := make([dynamic]rune, context.temp_allocator)
		for r in s {append(&runes, r)}
		text_frame(ctx, {mouse = {-100, -100}, text = runes[:]}, text)
	}
	key :: proc(ctx: ^Context, text: ^[dynamic]u8, k: Key, m: bit_set[Modifier] = {}) {
		text_frame(ctx, keys({k}, m), text)
	}
	type(ctx, &text, "set view_radius 8")
	key(ctx, &text, .W, {.Ctrl}) // kill "8"
	testing.expect_value(t, string(text[:]), "set view_radius ")
	key(ctx, &text, .W, {.Ctrl}) // kill "view_radius " (back to a space)
	testing.expect_value(t, string(text[:]), "set ")
	key(ctx, &text, .Y, {.Ctrl}) // yank it back
	testing.expect_value(t, string(text[:]), "set view_radius ")
	key(ctx, &text, .Backspace, {.Alt}) // a word: "radius" (the _ is part of it)
	testing.expect_value(t, string(text[:]), "set ")

	clear(&text)
	type(ctx, &text, "one two three")
	key(ctx, &text, .A, {.Ctrl})
	key(ctx, &text, .F, {.Alt}) // after "one"
	key(ctx, &text, .F, {.Ctrl}) // past the space
	key(ctx, &text, .K, {.Ctrl}) // kill "two three"
	testing.expect_value(t, string(text[:]), "one ")
	key(ctx, &text, .E, {.Ctrl})
	key(ctx, &text, .Y, {.Ctrl})
	testing.expect_value(t, string(text[:]), "one two three")
	key(ctx, &text, .B, {.Alt}) // before "three"
	key(ctx, &text, .U, {.Ctrl}) // kill "one two "
	testing.expect_value(t, string(text[:]), "three")
	key(ctx, &text, .D, {.Alt}) // kill "three"
	testing.expect_value(t, string(text[:]), "")
	type(ctx, &text, "ab")
	key(ctx, &text, .B, {.Ctrl})
	key(ctx, &text, .D, {.Ctrl}) // delete the b
	key(ctx, &text, .H, {.Ctrl}) // and the a
	testing.expect_value(t, string(text[:]), "")
	// Alt+letter is a shortcut, not text (X11 also reports the letter).
	text_frame(
		ctx,
		{mouse = {-100, -100}, text = []rune{'f'}, keys_pressed = {.F}, modifiers = {.Alt}},
		&text,
	)
	testing.expect_value(t, string(text[:]), "")
	// AltGr (Ctrl+Alt) types.
	text_frame(ctx, {mouse = {-100, -100}, text = []rune{'@'}, modifiers = {.Ctrl, .Alt}}, &text)
	testing.expect_value(t, string(text[:]), "@")
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

// Styled text: bold is wider by a pixel a letter, and draws each glyph
// twice; italic leans; underline and strike add a line each.
@(test)
test_styled_text :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	begin_frame(ctx, {}, SCREEN, 1)
	plain := measure_text(ctx, "Admin", 16)
	testing.expect_value(t, measure_text_styled(ctx, "Admin", 16, {.Bold}), plain + 5)
	quads :: proc(ctx: ^Context) -> int {return len(ctx.output.layers[ctx.layer].vertices) / 4}
	before := quads(ctx)
	w := draw_text_styled(ctx, {10, 40}, "Admin", 16, {255, 255, 255, 255}, {.Bold, .Underline})
	testing.expect_value(t, w, plain + 5)
	testing.expect_value(t, quads(ctx) - before, 5 * 2 + 1)
	before = quads(ctx)
	draw_text_styled(ctx, {10, 80}, "I", 16, {255, 255, 255, 255}, {.Italic, .Strike})
	testing.expect_value(t, quads(ctx) - before, 2)
	v := ctx.output.layers[ctx.layer].vertices[before * 4:]
	testing.expect(t, v[0].pos.x > v[3].pos.x, "italic does not lean")
	end_frame(ctx)
}

@(test)
test_theme_scope_nests :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	{
		a := ctx.theme
		a.opacity = 0.5
		theme_scope(ctx, a)
		testing.expect_value(t, ctx.theme.opacity, 0.5)
		{
			b := ctx.theme
			b.opacity *= 0.5
			b.text = {1, 2, 3, 4}
			theme_scope(ctx, b)
			testing.expect_value(t, ctx.theme.opacity, 0.25)
		}
		testing.expect_value(t, ctx.theme.opacity, 0.5)
		testing.expect(t, ctx.theme.text == DEFAULT_THEME.text)
	}
	testing.expect(t, ctx.theme == DEFAULT_THEME, "scopes restore the theme exactly")
	testing.expect_value(t, ctx.errors, 0)
	// A ninth nested scope is an error and ignored, and unwinds cleanly.
	nest :: proc(ctx: ^Context, n: int) {
		if n == 0 {return}
		x := ctx.theme
		x.opacity *= 0.9
		theme_scope(ctx, x)
		nest(ctx, n - 1)
	}
	nest(ctx, 9)
	testing.expect(t, ctx.theme == DEFAULT_THEME)
	testing.expect_value(t, ctx.errors, 1)
}

@(test)
test_opacity_halves_alpha :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	icon, ok := add_icon(
		ctx,
		2,
		{{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {9, 9, 9, 255}},
	)
	testing.expect(t, ok)
	// Alphas of the vertices each kind of drawing makes, at an opacity.
	alphas :: proc(ctx: ^Context, icon: Icon, opacity: f32) -> (panel_a, text_a, icon_a: u8) {
		begin_frame(ctx, {}, SCREEN, 1)
		th := ctx.theme
		th.opacity = opacity
		th.background = {0, 0, 0, 200}
		theme_scope(ctx, th)
		l := &ctx.output.layers[.Base]
		n := len(l.vertices)
		panel(ctx, {10, 10, 100, 40})
		panel_a = l.vertices[n].color.a
		n = len(l.vertices)
		draw_text(ctx, {10, 60, 100, 20}, "Hi", 16, {255, 255, 255, 255})
		text_a = l.vertices[n].color.a
		n = len(l.vertices)
		draw_icon(ctx, {10, 100, 32, 32}, icon)
		icon_a = l.vertices[n].color.a
		end_frame(ctx)
		return
	}
	p1, t1, i1 := alphas(ctx, icon, 1)
	p2, t2, i2 := alphas(ctx, icon, 0.5)
	near :: proc(a, b: u8) -> bool {return abs(int(a) - int(b)) <= 1}
	testing.expect_value(t, p1, 200)
	testing.expect(t, near(p2, p1 / 2), "panel alpha")
	testing.expect(t, near(t2, t1 / 2) && t1 == 255, "text alpha")
	testing.expect(t, near(i2, i1 / 2) && i1 == 255, "icon alpha")
}

@(test)
test_tooltip_waits_then_shows :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	frame :: proc(ctx: ^Context, time: f64, mouse: Vec2) -> bool {
		begin_frame(ctx, {mouse = mouse, time = time}, SCREEN, 1)
		tooltip(ctx, BUTTON_A, "A helpful sentence")
		tooltip(ctx, BUTTON_B, "Another one")
		shown := len(ctx.texts) > 0
		end_frame(ctx)
		return shown
	}
	testing.expect(t, !frame(ctx, 0, INSIDE_A))
	testing.expect(t, !frame(ctx, 0.3, INSIDE_A), "not before the delay")
	testing.expect(t, frame(ctx, 0.5, INSIDE_A), "after it")
	testing.expect(t, !frame(ctx, 0.6, {150, 180}), "another widget restarts the delay")
	testing.expect(t, frame(ctx, 1.1, {150, 180}))
	testing.expect(t, !frame(ctx, 1.2, OUTSIDE))
	testing.expect(t, !frame(ctx, 1.3, INSIDE_A), "leaving resets")
}

// ---------------------------------------------------------------------------
// Directional navigation (M42)
// ---------------------------------------------------------------------------

nav :: proc(n: bit_set[Nav], pad := true) -> Input {
	return {mouse = {-100, -100}, nav = n, pad = pad}
}

grid_frame :: proc(ctx: ^Context, input: Input) {
	begin_frame(ctx, input, SCREEN, 1)
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			label := strings.clone(string([]u8{u8('a' + row), u8('1' + col)}), ctx.frame_alloc)
			button(ctx, label, {100 + f32(col) * 60, 100 + f32(row) * 50, 50, 40})
		}
	}
	end_frame(ctx)
}

@(test)
test_directions_move_over_a_grid :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	grid_frame(ctx, nav({}))
	testing.expect_value(t, focused_label(ctx), "a1") // a pad user always sees a focus
	step :: proc(fx: ^Fixture, t: ^testing.T, n: Nav, want: string) {
		grid_frame(&fx.ctx, nav({n}))
		testing.expect_value(t, focused_label(&fx.ctx), want)
	}
	step(fx, t, .Right, "a2")
	step(fx, t, .Down, "b2")
	step(fx, t, .Right, "b3")
	step(fx, t, .Right, "b3") // the edge: no wrapping
	step(fx, t, .Down, "c3")
	step(fx, t, .Down, "c3")
	step(fx, t, .Left, "c2")
	step(fx, t, .Up, "b2")
	step(fx, t, .Up, "a2")
	step(fx, t, .Up, "a2")
	// The keyboard's arrows do the same.
	grid_frame(ctx, keys({.Left}))
	testing.expect_value(t, focused_label(ctx), "a1")
}

@(test)
test_a_column_beside_a_wide_button_picks_the_overlapping_one :: proc(t: ^testing.T) {
	from := Rect{0, 0, 100, 40}
	candidates := []Rect {
		{0, 60, 40, 40}, // below, overlapping spans: gap 20
		{150, 50, 40, 40}, // below but to the right: farther across
		{0, 200, 300, 40}, // wide and low
	}
	testing.expect_value(t, nav_pick(from, candidates, .Down), 0)
	testing.expect_value(t, nav_pick(from, candidates, .Up), -1)
	testing.expect_value(t, nav_pick({0, 100, 40, 40}, candidates[:1], .Down), -1)
	// Right of a tall button: the one level with it beats one lower.
	tall := Rect{0, 0, 50, 200}
	side := []Rect{{100, 150, 50, 40}, {100, 20, 50, 40}}
	testing.expect_value(t, nav_pick(tall, side, .Right), 1)
}

@(test)
test_first_nav_only_focuses :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	two_buttons(ctx, keys({}))
	a, b := two_buttons(ctx, keys({.Enter}))
	testing.expect(t, !a && !b, "the first event only shows the focus")
	testing.expect_value(t, ctx.focused, get_id(ctx, "A"))
	a, b = two_buttons(ctx, keys({.Enter}))
	testing.expect(t, a)
	// A screen's default wins.
	ctx.focused = 0
	for _ in 0 ..< 2 {
		begin_frame(ctx, nav({}), SCREEN, 1)
		button(ctx, "A", BUTTON_A)
		default_focus(ctx)
		button(ctx, "B", BUTTON_B)
		end_frame(ctx)
	}
	testing.expect_value(t, focused_label(ctx), "B")
}

@(test)
test_slider_consumes_left_right :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	value: f32 = 0.5
	frame :: proc(ctx: ^Context, in_: Input, v: ^f32) {
		begin_frame(ctx, in_, SCREEN, 1)
		slider(ctx, "vol", v, 0, 1, {100, 100, 300, 30}, step = 0.1)
		button(ctx, "below", {100, 140, 300, 30})
		button(ctx, "above", {100, 60, 300, 30})
		end_frame(ctx)
	}
	frame(ctx, nav({.Down}), &value)
	frame(ctx, nav({.Down}), &value) // above, vol: the slider is the second drawn
	ctx.focused = get_id(ctx, "vol")
	frame(ctx, nav({.Right}), &value)
	testing.expect(t, abs(value - 0.6) < 0.001)
	testing.expect_value(t, focused_label(ctx), "vol")
	frame(ctx, nav({.Left}), &value)
	frame(ctx, nav({.Left}), &value)
	testing.expect(t, abs(value - 0.4) < 0.001)
	frame(ctx, nav({.Up}), &value)
	testing.expect_value(t, focused_label(ctx), "above")
}

@(test)
test_choice_cycles_both_ways :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	i := 0
	names := []string{"Low", "Medium", "High"}
	frame :: proc(ctx: ^Context, in_: Input, i: ^int, names: []string) {
		begin_frame(ctx, in_, SCREEN, 1)
		choice(ctx, "Quality", i, names, {100, 100, 300, 30})
		end_frame(ctx)
	}
	frame(ctx, nav({}), &i, names)
	testing.expect_value(t, focused_label(ctx), "Quality: Low")
	frame(ctx, nav({.Right}), &i, names)
	testing.expect_value(t, i, 1)
	frame(ctx, nav({.Left}), &i, names)
	frame(ctx, nav({.Left}), &i, names)
	testing.expect_value(t, i, 2) // wrapped
	frame(ctx, nav({.Confirm}), &i, names)
	testing.expect_value(t, i, 0)
	frame(ctx, press({150, 110}), &i, names)
	frame(ctx, release({150, 110}), &i, names)
	frame(ctx, release({150, 110}), &i, names)
	testing.expect_value(t, i, 1)
}

@(test)
test_modal_takes_focus_and_gives_it_back :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	for _ in 0 ..< 2 {modal_frame(ctx, nav({}), false)}
	testing.expect_value(t, ctx.focused, get_id(ctx, "background"))
	modal_frame(ctx, nav({}), true)
	modal_frame(ctx, nav({}), true)
	testing.expect_value(t, focused_label(ctx), "OK")
	modal_frame(ctx, nav({}), false)
	modal_frame(ctx, nav({}), false)
	testing.expect_value(t, ctx.focused, get_id(ctx, "background"))
}

@(test)
test_pointer_idles_after_nav :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	two_buttons(ctx, at(INSIDE_A))
	two_buttons(ctx, at(INSIDE_A))
	testing.expect_value(t, ctx.hot, get_id(ctx, "A"))
	two_buttons(ctx, {mouse = INSIDE_A, nav = {.Down}, pad = true})
	two_buttons(ctx, {mouse = INSIDE_A, pad = true})
	testing.expect_value(t, ctx.hot, Id(0))
	two_buttons(ctx, {mouse = INSIDE_A + {1, 0}, pad = true})
	testing.expect_value(t, ctx.hot, Id(0)) // 1 unit is a tremor
	two_buttons(ctx, {mouse = INSIDE_A + {10, 0}, pad = true})
	testing.expect_value(t, ctx.hot, get_id(ctx, "A"))
}

@(test)
test_list_nav :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	selected, first := 0, 0
	frame :: proc(ctx: ^Context, in_: Input, selected, first: ^int) -> Interaction {
		begin_frame(ctx, in_, SCREEN, 1)
		it := list_nav(ctx, "rows", {100, 100, 300, 160}, 50, selected, first, 8)
		button(ctx, "after", {100, 300, 100, 30})
		end_frame(ctx)
		return it
	}
	frame(ctx, nav({}), &selected, &first)
	testing.expect_value(t, focused_label(ctx), "rows")
	for _ in 0 ..< 20 {frame(ctx, nav({.Down}), &selected, &first)}
	testing.expect_value(t, selected, 20)
	testing.expect_value(t, first, 13)
	testing.expect_value(t, focused_label(ctx), "rows")
	it := frame(ctx, nav({.Confirm}), &selected, &first)
	testing.expect(t, it.clicked)
	for _ in 0 ..< 30 {frame(ctx, nav({.Down}), &selected, &first)}
	testing.expect_value(t, selected, 49)
	frame(ctx, nav({.Down}), &selected, &first) // the last row: leaves the list
	testing.expect_value(t, focused_label(ctx), "after")
	frame(ctx, nav({.Up}), &selected, &first)
	selected, first = 0, 0
	frame(ctx, nav({.Up}), &selected, &first) // the first row: leaves the list (nothing above)
	testing.expect_value(t, selected, 0)
	// The stick scrolls without moving the selection.
	frame(ctx, {mouse = {-100, -100}, pad = true, nav_scroll = 3}, &selected, &first)
	testing.expect_value(t, first, 3)
	testing.expect_value(t, selected, 0) // (the selection stays where it was)
}

@(test)
test_keep_focus_visible :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	scroll: f32
	view := Rect{100, 100, 300, 100}
	frame :: proc(ctx: ^Context, in_: Input, scroll: ^f32, view: Rect) {
		begin_frame(ctx, in_, SCREEN, 1)
		push_clip_rect(ctx, view)
		for i in 0 ..< 10 {
			label := strings.clone(string([]u8{u8('0' + i)}), ctx.frame_alloc)
			button(ctx, label, {view.x, view.y + f32(i) * 40 - scroll^, 300, 30})
		}
		pop_clip_rect(ctx)
		keep_focus_visible(ctx, view, scroll)
		end_frame(ctx)
	}
	frame(ctx, nav({}), &scroll, view)
	for _ in 0 ..< 5 {frame(ctx, nav({.Down}), &scroll, view)}
	frame(ctx, nav({}), &scroll, view)
	testing.expect_value(t, focused_label(ctx), "5")
	testing.expect(t, scroll > 0 && scroll <= 130, "scrolled to the row below the view")
	for _ in 0 ..< 5 {frame(ctx, nav({.Up}), &scroll, view)}
	frame(ctx, nav({}), &scroll, view)
	testing.expect_value(t, scroll, 0)
}

@(test)
test_pad_confirm_opens_the_keyboard_enter_submits :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	text := make([dynamic]u8)
	defer delete(text)
	submitted := false
	frame :: proc(ctx: ^Context, in_: Input, text: ^[dynamic]u8, submitted: ^bool) {
		begin_frame(ctx, in_, SCREEN, 1)
		if text_input(ctx, "name", text, {100, 100, 300, 36}) {submitted^ = true}
		end_frame(ctx)
	}
	frame(ctx, nav({}), &text, &submitted) // focused (the first event only shows it)
	testing.expect(t, !osk_is_open(ctx))
	frame(ctx, nav({.Confirm}), &text, &submitted)
	testing.expect(t, osk_is_open(ctx))
	testing.expect(t, !submitted)
	// A real Enter in the open keyboard's field submits.
	frame(ctx, keys({.Enter}), &text, &submitted)
	testing.expect(t, submitted)
	osk_cancel(ctx)
	submitted = false
	for _ in 0 ..< 4 {frame(ctx, nav({}), &text, &submitted)}
	frame(ctx, keys({.Enter}), &text, &submitted)
	testing.expect(t, submitted && !osk_is_open(ctx), "keyboard Enter submits, no keyboard")
}

// A text whose size changes every frame scales its quads smoothly and does
// not grow the glyph cache (it rasterizes once, at the largest size).
@(test)
test_tilted_text_scales_continuously :: proc(t: ^testing.T) {
	fx := setup(t)
	defer teardown(fx)
	ctx := &fx.ctx
	base: f32 = 20
	largest := base * 1.05
	entries := -1
	last_width: f32 = -1
	for i in 0 ..= 40 {
		size := base * (0.95 + 0.1 * f32(i) / 40)
		begin_frame(ctx, at({0, 0}), SCREEN, 1)
		draw_text_tilted(ctx, {400, 300}, "Splash", size, {255, 255, 255, 255}, -0.1, largest)
		end_frame(ctx)
		// The first glyph quad's top edge length is its (turned) width.
		v := ctx.output.layers[.Base].vertices
		testing.expect(t, len(v) >= 4)
		d := v[1].pos - v[0].pos
		width := math.sqrt(d.x * d.x + d.y * d.y)
		testing.expectf(t, width != last_width, "step %d: quad width %v repeats", i, width)
		last_width = width
		if entries < 0 {entries = len(ctx.glyphs.entries)}
		testing.expectf(t, len(ctx.glyphs.entries) == entries, "glyph cache grew at step %d", i)
	}
}
