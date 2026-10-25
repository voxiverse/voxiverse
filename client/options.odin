package client

import "core:fmt"
import "core:math"
import "core:strings"

import "../base"
import "../platform"
import "../ui"

// Options (PLAN.md M20): the player's settings in tabs, the same from the
// title and in a game (there docked left, the world in view, so changes show
// as they are made). Changes apply at once and are saved on leaving.
// Developer switches stay in F4 and the console, never here.

Options_Tab :: enum u8 {
	Video,
	Sound,
	Controls,
	Accessibility,
	Profile,
}

// OPTIONS_TABS: each tab's settings, in order (fields of SETTINGS_VARS);
// Controls adds the key bindings.
@(rodata)
OPTIONS_TABS := [Options_Tab][]string {
	.Video         = {
		"fullscreen",
		"vsync",
		"max_fps",
		"fov",
		"render_distance",
		"gui_scale",
		"brightness",
		"clouds",
		"show_fps",
	},
	.Sound         = {"volume"},
	.Controls      = {"mouse_sensitivity", "invert_mouse", "sneak_toggle", "sprint_toggle"},
	.Accessibility = {"reduce_motion", "chat_text_size"},
	.Profile       = {"name", "share_data"},
}

Options_View :: struct {
	tab:       Options_Tab,
	scroll:    f32, // pixels
	listening: int, // the binding waiting for its key, plus one (0: none)
}

OPTIONS_WIDTH :: 600

// options_screen: Options over the title's stars.
options_screen :: proc(app: ^App, ctx: ^ui.Context) {
	if options_panel(app, ctx, false) {app.screen = .Title}
}

// options_panel: Options, with Done (true when pressed, the settings
// saved). In a game it sits on a panel docked left, without dimming the
// world.
options_panel :: proc(app: ^App, ctx: ^ui.Context, in_game: bool) -> (done: bool) {
	ui.push_id(ctx, "options")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	area := ui.rect_center(ctx.screen, OPTIONS_WIDTH, min(ctx.screen.h - 40, 640))
	if in_game {
		prev := ui.begin_layer(ctx, .Modal)
		defer ui.end_layer(ctx, prev)
		r := ctx.screen
		panel := ui.cut_left(&r, OPTIONS_WIDTH + 4 * t.padding)
		ui.panel(ctx, panel)
		return options_body(app, ctx, ui.rect_shrink(panel, 2 * t.padding))
	}
	return options_body(app, ctx, area)
}

// options_cancel_listening: Escape while a binding waits for its key
// leaves it as it was (true if one was waiting).
options_cancel_listening :: proc(app: ^App) -> bool {
	if app.options.listening == 0 {return false}
	app.options.listening = 0
	return true
}

@(private = "file")
options_body :: proc(app: ^App, ctx: ^ui.Context, area: ui.Rect) -> (done: bool) {
	t := &ctx.theme
	o := &app.options
	column := area
	ui.title(ctx, "Options", ui.cut_top(&column, 64))

	// The tabs: the open one lit, the others buttons.
	// Each as wide as its name, the room left shared out.
	tabs := ui.cut_top(&column, t.row_height)
	gap :: 4
	text_w: [Options_Tab]f32
	total: f32
	for tab in Options_Tab {
		text_w[tab] = ui.measure_text(ctx, tab_name(tab), t.font_size) + 2 * t.padding
		total += text_w[tab] + gap
	}
	extra := max(0, tabs.w - total) / f32(len(Options_Tab))
	for tab in Options_Tab {
		r := ui.cut_left(&tabs, text_w[tab] + extra + gap)
		r.w -= gap
		name := tab_name(tab)
		if tab == o.tab {
			ui.fill_rect(ctx, r, t.hover)
			ui.stroke_rect(ctx, r, t.border_width, t.border)
			ui.draw_text(ctx, r, name, t.font_size, t.hover_text, .Center)
		} else if ui.button(ctx, name, r) {
			o.tab, o.scroll, o.listening = tab, 0, 0
		}
	}
	ui.cut_top(&column, 2 * t.spacing)

	bottom := ui.cut_bottom(&column, t.row_height)
	ui.cut_bottom(&column, 2 * t.spacing)
	if ui.button(ctx, "Done", ui.rect_center(bottom, 200, t.row_height)) {
		o.listening = 0
		if app.settings_dirty {settings_save(app)}
		return true
	}

	// The tab's rows, scrolled by the wheel when they do not fit.
	step := t.row_height + t.spacing
	rows := len(OPTIONS_TABS[o.tab])
	if o.tab == .Controls {rows += 2 + len(BINDING_VARS) + 1} 	// a gap, a heading, the keys, Reset
	overflow := max(0, f32(rows) * step - column.h)
	if ui.rect_contains(column, ctx.input.mouse) && ctx.input.wheel.y != 0 {
		o.scroll -= ctx.input.wheel.y * step
	}
	o.scroll = clamp(o.scroll, 0, overflow)
	ui.push_clip_rect(ctx, column)
	defer ui.pop_clip_rect(ctx)
	ui.layout_begin(ctx, {column.x, column.y - o.scroll, column.w, f32(rows) * step})
	defer ui.layout_end(ctx)

	table := settings_table()
	for field in OPTIONS_TABS[o.tab] {
		v, _ := base.var_find(table, field)
		if var_widget(ctx, table, &app.settings, v) {settings_changed(app)}
	}
	if o.tab == .Controls {
		ui.next(ctx)
		ui.label(ctx, "Key Bindings", ui.next(ctx), .Center, t.text_muted)
		if bindings_list(app, ctx) {settings_changed(app)}
		if ui.button(ctx, "Reset Keys", ui.next(ctx)) {
			app.settings.keys = DEFAULT_BINDINGS
			settings_changed(app)
		}
	}
	return false
}

@(private = "file")
tab_name :: proc(tab: Options_Tab) -> string {
	switch tab {
	case .Video:
		return "Video"
	case .Sound:
		return "Sound"
	case .Controls:
		return "Controls"
	case .Accessibility:
		return "Accessibility"
	case .Profile:
		return "Profile"
	}
	return ""
}

// bindings_list: a row per action, its key a button; pressed, the next key
// or mouse button pressed is bound (Escape: unchanged). A key bound twice
// is marked on both rows.
@(private = "file")
bindings_list :: proc(app: ^App, ctx: ^ui.Context) -> (changed: bool) {
	t := &ctx.theme
	o := &app.options
	table := bindings_table()
	keys := &app.settings.keys
	ui.push_id(ctx, "keys")
	defer ui.pop_id(ctx)
	// Waiting for a key: the first pressed (Escape is escape's: unchanged).
	if o.listening != 0 {
		for k in platform.Key {
			if k == .Unknown || k == .Escape || k not_in app.input.pressed {continue}
			base.var_set_f64(table, keys, &BINDING_VARS[o.listening - 1], f64(k))
			o.listening = 0
			changed = true
			break
		}
	}
	for &v, i in BINDING_VARS {
		r := ui.next(ctx)
		ui.label(ctx, var_label(table, &v), ui.cut_left(&r, r.w * 0.5))
		key := platform.Key(base.var_get_f64(table, keys, &v))
		text := key_label(&app.window, key)
		if o.listening == i + 1 {text = fmt.tprintf("> %s <", text)}
		ui.push_id_int(ctx, i)
		if ui.button(ctx, text, r) {o.listening = i + 1}
		ui.pop_id(ctx)
		twice := false
		for &other in BINDING_VARS {
			k := platform.Key(base.var_get_f64(table, keys, &other))
			twice ||= &other != &v && k == key && key != .Unknown
		}
		if twice {ui.stroke_rect(ctx, ui.rect_shrink(r, 3), 2, {220, 90, 70, 255})}
	}
	if o.listening == 0 {return}

	// Waiting: a dialog over everything takes the clicks, so the button
	// pressed binds and presses nothing.
	v := &BINDING_VARS[o.listening - 1]
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 460, 2 * t.row_height + 4 * t.padding)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(
		ctx,
		fmt.tprintf("Press a key for %s", var_label(table, v)),
		ui.cut_top(&inner, t.row_height),
		.Center,
	)
	ui.label(
		ctx,
		"Escape: leave it as it is",
		ui.cut_top(&inner, t.row_height),
		.Center,
		t.text_muted,
	)
	_ = ui.interact(ctx, ui.get_id(ctx, "listening"), ctx.screen)
	return
}

// var_widget draws one variable in the current layout: a button cycling
// through its choices, a checkbox, a slider or a text field; true if it
// changed.
var_widget :: proc(
	ctx: ^ui.Context,
	table: base.Var_Table,
	data: rawptr,
	v: ^base.Var,
) -> (
	changed: bool,
) {
	label := var_label(table, v)
	if i, ok := base.var_choice(table, data, v); ok {
		if ui.button(ctx, fmt.tprintf("%s: %s", label, v.choices[i].label), ui.next(ctx)) {
			base.var_set_f64(table, data, v, v.choices[(i + 1) % len(v.choices)].value)
			changed = true
		}
		return
	}
	kind, _ := base.var_kind(table, v)
	switch kind {
	case .Bool:
		value := base.var_get_f64(table, data, v) != 0
		if ui.checkbox(ctx, label, &value, ui.next(ctx)) {
			base.var_set_f64(table, data, v, 1 if value else 0)
			changed = true
		}
	case .Int, .F32:
		value := f32(base.var_get_f64(table, data, v))
		step := f32(v.step)
		if kind == .Int {step = max(step, 1)}
		format := "%.0f" if kind == .Int || step >= 1 else "%.2f"
		if ui.slider(
			ctx,
			label,
			&value,
			f32(v.min),
			f32(v.max),
			ui.next(ctx),
			step = step,
			format = format,
		) {
			if step > 0 {value = f32(math.round(f64(value) / f64(step)) * f64(step))}
			base.var_set_f64(table, data, v, f64(value))
			changed = true
		}
	case .Enum:
		// (Bindings have their own list; elsewhere, the value's name.)
		r := ui.next(ctx)
		ui.label(ctx, label, ui.cut_left(&r, r.w * 0.45))
		ui.label(ctx, base.var_format(table, data, v), r)
	case .Text:
		// Edited in place; a keystroke that makes it invalid is refused.
		r := ui.next(ctx)
		ui.label(ctx, label, ui.cut_left(&r, r.w * 0.45))
		_, offset := base.var_kind(table, v)
		value := (^base.Var_Text)(uintptr(data) + offset)
		text := make([dynamic]u8, context.temp_allocator)
		append(&text, base.var_text(value))
		ui.text_input(ctx, v.field, &text, r, placeholder = v.hint)
		if string(text[:]) != base.var_text(value) &&
		   base.var_set(table, data, base.var_name(table, v), string(text[:])) == .None {
			changed = true
		}
	}
	return
}

// var_widgets draws every variable of the table (the tuning panel); true
// if any changed.
var_widgets :: proc(ctx: ^ui.Context, table: base.Var_Table, data: rawptr) -> (changed: bool) {
	ui.push_id(ctx, table.prefix)
	defer ui.pop_id(ctx)
	for &v in table.vars {changed = var_widget(ctx, table, data, &v) || changed}
	return
}

// var_label: the menu's label, or one from the field ("mouse_sensitivity"
// -> "Mouse sensitivity").
var_label :: proc(table: base.Var_Table, v: ^base.Var) -> string {
	if v.label != "" {return v.label}
	s := strings.to_upper(v.field[:1], context.temp_allocator)
	rest, _ := strings.replace_all(v.field[1:], "_", " ", context.temp_allocator)
	return strings.concatenate({s, rest}, context.temp_allocator)
}
