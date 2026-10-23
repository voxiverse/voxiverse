package client

import "core:fmt"

import "../gpu"
import "../ui"

// Front-end screens. Escape backs out one level: console, quit dialog,
// options, then (from the title) asks to quit.

handle_global_keys :: proc(app: ^App, input: ^ui.Input) {
	if app.input.console_toggle {
		app.console.open = !app.console.open
	}
	if app.input.escape {
		switch {
		case app.console.open:
			app.console.open = false
		case app.quit_dialog:
			app.quit_dialog = false
		case app.screen == .Options:
			app.screen = .Title
		case:
			app.quit_dialog = true
		}
	}
}

// Each screen and dialog draws in its own id scope, so equal labels in
// different places (the title's "Quit" and the dialog's "Quit") are distinct
// widgets.
app_ui :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "screen")
	defer ui.pop_id(ctx)
	switch app.screen {
	case .Title:
		title_screen(app, ctx)
	case .Options:
		options_screen(app, ctx)
	}
	if app.quit_dialog {quit_dialog(app, ctx)}
	if app.settings.show_frame_times {frame_times_overlay(app, ctx)}
	if app.console.open {console_ui(app, ctx)}
}

title_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "title")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 320, 5 * t.row_height + 4 * t.spacing + 120)
	ui.title(ctx, "Voxiverse", ui.cut_top(&column, 80))
	ui.cut_top(&column, 40)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.button(ctx, "Singleplayer", ui.next(ctx), disabled = true) // arrives in M3
	ui.button(ctx, "Multiplayer", ui.next(ctx), disabled = true) // arrives in M7
	if ui.button(ctx, "Options", ui.next(ctx)) {app.screen = .Options}
	if ui.button(ctx, "Quit", ui.next(ctx)) {app.quit_dialog = true}
}

options_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "options")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 520, 5 * t.row_height + 4 * t.spacing + 80)
	ui.title(ctx, "Options", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	ui.checkbox(ctx, "Show frame times", &app.settings.show_frame_times, ui.next(ctx))
	auto_scale := app.settings.ui_scale == 0
	if ui.checkbox(ctx, "Automatic UI scale", &auto_scale, ui.next(ctx)) {
		app.settings.ui_scale = 0 if auto_scale else ui_scale(app)
	}
	if !auto_scale {
		ui.slider(ctx, "UI scale", &app.settings.ui_scale, 0.75, 3, ui.next(ctx), step = 0.25)
		app.settings.ui_scale = f32(int(app.settings.ui_scale * 4 + 0.5)) / 4 // quarter steps
	}
	ui.next(ctx, 10)
	if ui.button(ctx, "Back", ui.next(ctx)) {app.screen = .Title}
}

quit_dialog :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "quit dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 360, 140)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, "Quit Voxiverse?", ui.cut_top(&inner, t.row_height), .Center)
	buttons := ui.cut_bottom(&inner, t.row_height)
	no := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	if ui.button(ctx, "Quit", buttons) {app.quit = true}
	if ui.button(ctx, "Cancel", no) {app.quit_dialog = false}
}

frame_times_overlay :: proc(app: ^App, ctx: ^ui.Context) {
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	gpu_ms: f32
	if s := gpu.gpu_frame_summary(&app.g); s.count > 0 {gpu_ms = s.avg}
	text := fmt.tprintf("frame %5.2f ms   GPU %5.2f ms avg", app.last_frame_ms, gpu_ms)
	r := ctx.screen
	r = ui.cut_top(&r, 28)
	r = ui.cut_right(&r, 330)
	ui.fill_rect(ctx, r, {0, 0, 0, 200})
	ui.label(ctx, text, ui.rect_shrink(r, 4), .Right, ctx.theme.text_muted)
}
