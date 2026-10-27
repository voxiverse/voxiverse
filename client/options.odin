package client

import "core:fmt"
import "core:math"
import "core:strings"

import "../base"
import "platform"
import "ui"

// Options (docs/plan.md M20): the player's settings in tabs, the same from the
// title and in a game (there docked left, the world in view, so changes show
// as they are made). Changes apply at once and are saved on leaving.
// Developer switches stay in F4 and the console, never here.

Options_Tab :: enum u8 {
	Video,
	Audio,
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
	.Audio         = {
		"volume",
		"music_volume",
		"ambience_volume",
		"music_gap",
		"effects_volume",
		"mono_audio",
		"swap_channels",
		"night_mode",
		"crossfeed",
		"ceiling_db",
	},
	.Controls      = {
		"mouse_sensitivity",
		"invert_mouse",
		"sneak_toggle",
		"sprint_toggle",
		"stick_look_speed",
		"stick_invert",
		"stick_dead_zone",
		"stick_response",
		"stick_swap",
		"button_prompts",
	},
	.Accessibility = {"reduce_motion", "prompt_bar", "chat_text_size"},
	.Profile       = {"name", "share_data"},
}

Options_View :: struct {
	tab:           Options_Tab,
	scroll:        f32, // pixels
	listening:     Action, // the binding waiting for its button (None: none)
	listening_pad: bool, // ... on the pad, not the keyboard
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
	if app.options.listening == .None {return false}
	app.options.listening = .None
	return true
}

@(private = "file")
options_body :: proc(app: ^App, ctx: ^ui.Context, area: ui.Rect) -> (done: bool) {
	t := &ctx.theme
	o := &app.options
	column := area
	ui.title(ctx, "Options", ui.cut_top(&column, 64))

	// Q and E (as bound) step through the tabs, around.
	if step := menu_tab_step(app); step != 0 {
		n := len(Options_Tab)
		o.tab = Options_Tab((int(o.tab) + step + n) % n)
		o.scroll, o.listening = 0, .None
	}

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
	// The two tab keys' glyphs at the ends of the tab row: previous left, next right.
	prev_glyph, next_glyph := prompt_glyph(app, .Tab_Prev), prompt_glyph(app, .Tab_Next)
	prev_w, next_w := prompt_glyph_width(ctx, prev_glyph), prompt_glyph_width(ctx, next_glyph)
	prev_rect := ui.cut_left(&tabs, prev_w + t.spacing)
	next_rect := ui.cut_right(&tabs, next_w + t.spacing)
	prev_rect = ui.rect_center(prev_rect, prev_w, PROMPT_BAR_HEIGHT)
	next_rect = ui.rect_center(next_rect, next_w, PROMPT_BAR_HEIGHT)
	prompt_glyph_draw(app, ctx, prev_glyph, prev_rect, t.text_muted)
	prompt_glyph_draw(app, ctx, next_glyph, next_rect, t.text_muted)
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
			o.tab, o.scroll, o.listening = tab, 0, .None
		}
	}
	ui.cut_top(&column, 2 * t.spacing)

	bottom := ui.cut_bottom(&column, t.row_height)
	ui.cut_bottom(&column, 2 * t.spacing)
	if ui.button(ctx, "Done", ui.rect_center(bottom, 200, t.row_height)) {
		o.listening = .None
		if app.settings_dirty {settings_save(app)}
		return true
	}

	// The tab's rows, scrolled by the wheel when they do not fit.
	step := t.row_height + t.spacing
	rows := len(OPTIONS_TABS[o.tab])
	if o.tab == .Controls {rows += 2 + binding_row_count(app) + 1} 	// a gap, a heading, the table, Reset
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
		ui.label(ctx, "Bindings: Keyboard and Gamepad", ui.next(ctx), .Center, t.text_muted)
		if bindings_list(app, ctx) {settings_changed(app)}
		reset := ui.next(ctx)
		if ui.button(ctx, "Reset Keys", ui.cut_left(&reset, reset.w * 0.5)) {
			app.settings.keys = DEFAULT_BINDINGS
			settings_changed(app)
		}
		if ui.button(ctx, "Reset Pad Buttons", reset) {
			app.settings.pad = DEFAULT_PAD_BINDINGS
			settings_changed(app)
		}
	}
	ui.keep_focus_visible(ctx, column, &o.scroll)
	return false
}

tab_name :: proc(tab: Options_Tab) -> string {
	switch tab {
	case .Video:
		return "Video"
	case .Audio:
		return "Audio"
	case .Controls:
		return "Controls"
	case .Accessibility:
		return "Accessibility"
	case .Profile:
		return "Profile"
	}
	return ""
}

// BINDING_GROUPS: the headings of the bindings table, and the contexts of
// the actions under each.
BINDING_GROUPS := [?]struct {
	title:    string,
	contexts: bit_set[Action_Context],
}{{"In the world", {.World}}, {"In menus", {.Menu}}, {"Anywhere", {.World, .Menu}}}

// binding_rows: the actions with a source to rebind, by group.
binding_rows :: proc(app: ^App, group: int) -> (out: [dynamic]Action) {
	out = make([dynamic]Action, context.temp_allocator)
	for a in Action {
		if a == .None || ACTION_INFO[a].contexts != BINDING_GROUPS[group].contexts {continue}
		if action_key(&app.settings.keys, a) != nil || action_pad(&app.settings.pad, a) != nil {
			append(&out, a)
		}
	}
	return
}

@(private = "file")
binding_row_count :: proc(app: ^App) -> int {
	n := 0
	for g in 0 ..< len(BINDING_GROUPS) {
		n += 1 + len(binding_rows(app, g))
	}
	return n
}

@(private = "file")
find_var :: proc(vars: []base.Var, field: string) -> ^base.Var {
	for &v in vars {
		if v.field == field {return &v}
	}
	return nil
}

// bindings_list: the bindings as a table under headings, a row per action:
// its label, its key and its pad button. Pressing a cell listens: the next
// key or mouse button, or the next pad button or trigger, is bound (Escape
// or Start: unchanged). An action sharing a source with another in the same
// context is framed on that cell.
@(private = "file")
bindings_list :: proc(app: ^App, ctx: ^ui.Context) -> (changed: bool) {
	t := &ctx.theme
	o := &app.options
	keys, pad := &app.settings.keys, &app.settings.pad
	key_table, pad_table := bindings_table(), pad_bindings_table()
	key_clash, pad_clash := binding_conflicts(keys, pad)
	ui.push_id(ctx, "keys")
	defer ui.pop_id(ctx)
	// Waiting for a button: the first pressed.
	if o.listening != .None {
		field := action_field(o.listening)
		if o.listening_pad {
			for b in platform.Pad_Button {
				if b == .None || b == .Start || b not_in app.actions.pad_pressed {continue}
				if v := find_var(PAD_BINDING_VARS[:], field); v != nil {
					base.var_set_f64(pad_table, pad, v, f64(b))
					changed = true
				}
				o.listening = .None
				break
			}
		} else {
			for k in platform.Key {
				if k == .Unknown || k == .Escape || k not_in app.input.pressed {continue}
				if v := find_var(BINDING_VARS[:], field); v != nil {
					base.var_set_f64(key_table, keys, v, f64(k))
					changed = true
				}
				o.listening = .None
				break
			}
		}
	}
	for g in 0 ..< len(BINDING_GROUPS) {
		ui.label(ctx, BINDING_GROUPS[g].title, ui.next(ctx), .Center, t.text_muted)
		for a in binding_rows(app, g) {
			r := ui.next(ctx)
			ui.push_id_int(ctx, int(a))
			defer ui.pop_id(ctx)
			ui.label(ctx, ACTION_INFO[a].label, ui.cut_left(&r, r.w * 0.4))
			kr := ui.cut_left(&r, r.w * 0.5)
			field := action_field(a)
			if k := action_key(keys, a); k != nil {
				text := key_label(&app.window, k^)
				if o.listening == a && !o.listening_pad {text = fmt.tprintf("> %s <", text)}
				if v := find_var(BINDING_VARS[:], field); v != nil {ui.tooltip(ctx, kr, v.help)}
				// (the id is not the label: the cell stays focused as its button changes)
				if ui.button(ctx, text, kr, id = "key cell") {
					o.listening, o.listening_pad = a, false
				}
				if a in key_clash {ui.stroke_rect(ctx, ui.rect_shrink(kr, 3), 2, t.warning)}
			} else {
				fixed := ACTION_INFO[a].fixed_keys[0]
				text := key_label(&app.window, fixed) if fixed != .Unknown else "-"
				ui.button(ctx, text, kr, disabled = true)
			}
			if b := action_pad(pad, a); b != nil {
				text := pad_button_name(app.actions.pad_family, app.actions.pad_product, b^)
				if o.listening == a && o.listening_pad {text = fmt.tprintf("> %s <", text)}
				if v := find_var(PAD_BINDING_VARS[:], field); v != nil {ui.tooltip(ctx, r, v.help)}
				if ui.button(ctx, text, r, id = "pad cell") {
					o.listening, o.listening_pad = a, true
				}
				if a in pad_clash {ui.stroke_rect(ctx, ui.rect_shrink(r, 3), 2, t.warning)}
			} else {
				fixed := ACTION_INFO[a].fixed_pad[0]
				text := pad_button_name(app.actions.pad_family, app.actions.pad_product, fixed)
				ui.button(ctx, text, r, disabled = true)
			}
		}
	}
	if o.listening == .None {return}

	// Waiting: a dialog over everything takes the clicks, so the button
	// pressed binds and presses nothing.
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 460, 2 * t.row_height + 4 * t.padding)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(
		ctx,
		fmt.tprintf(
			"Press a %s for %s",
			"button" if o.listening_pad else "key",
			ACTION_INFO[o.listening].label,
		),
		ui.cut_top(&inner, t.row_height),
		.Center,
	)
	ui.label(
		ctx,
		"Start or Escape: leave it as it is",
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
		r := ui.next(ctx)
		ui.tooltip(ctx, r, v.help)
		names := make([]string, len(v.choices), context.temp_allocator)
		for c, k in v.choices {names[k] = c.label}
		index := i
		if ui.choice(ctx, label, &index, names, r) {
			base.var_set_f64(table, data, v, v.choices[index].value)
			changed = true
		}
		return
	}
	kind, _ := base.var_kind(table, v)
	switch kind {
	case .Bool:
		value := base.var_get_f64(table, data, v) != 0
		r := ui.next(ctx)
		ui.tooltip(ctx, r, v.help)
		if ui.checkbox(ctx, label, &value, r) {
			base.var_set_f64(table, data, v, 1 if value else 0)
			changed = true
		}
	case .Int, .F32:
		value := f32(base.var_get_f64(table, data, v))
		step := f32(v.step)
		if kind == .Int {step = max(step, 1)}
		format := "%.0f" if kind == .Int || step >= 1 else "%.2f"
		r := ui.next(ctx)
		name_part := r
		ui.tooltip(ctx, ui.cut_left(&name_part, r.w * 0.4), v.help)
		special := ""
		for sp in v.special {
			if f64(value) == sp.value {special = sp.label}
		}
		if ui.slider(
			ctx,
			label,
			&value,
			f32(v.min),
			f32(v.max),
			r,
			step = step,
			format = format,
			value_text = special,
		) {
			if step > 0 {value = f32(math.round(f64(value) / f64(step)) * f64(step))}
			base.var_set_f64(table, data, v, f64(value))
			changed = true
		}
	case .Enum:
		// (Bindings have their own list; elsewhere, the value's name.)
		r := ui.next(ctx)
		ui.tooltip(ctx, r, v.help)
		ui.label(ctx, label, ui.cut_left(&r, r.w * 0.45))
		ui.label(ctx, base.var_format(table, data, v), r)
	case .Text:
		// Edited in place; a keystroke that makes it invalid is refused.
		r := ui.next(ctx)
		ui.tooltip(ctx, r, v.help)
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
