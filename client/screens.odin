package client

import "core:fmt"
import "core:math"

import "../gpu"
import "../server"
import "../ui"

// Screens. Escape backs out one level: console, quit dialog, options; in a
// world it toggles the pause menu; on the title it asks to quit.

handle_global_keys :: proc(app: ^App, input: ^ui.Input) {
	if app.input.console_toggle {
		app.console.open = !app.console.open
	}
	if .F3 in app.input.pressed {app.show_debug = !app.show_debug}
	if app.input.escape {
		switch {
		case app.console.open:
			app.console.open = false
		case app.quit_dialog:
			app.quit_dialog = false
		case app.screen == .Options:
			app.screen = .Title
		case app.screen == .Game:
			app.paused = !app.paused
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
	case .Game:
		game_screen(app, ctx)
	}
	if app.show_debug {debug_overlay(app, ctx)}
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
	if ui.button(ctx, "Singleplayer", ui.next(ctx)) {enter_world(app)}
	ui.button(ctx, "Multiplayer", ui.next(ctx), disabled = true) // arrives in M7
	if ui.button(ctx, "Options", ui.next(ctx)) {app.screen = .Options}
	if ui.button(ctx, "Quit", ui.next(ctx)) {app.quit_dialog = true}
	if app.message != "" {
		ui.label(ctx, app.message, ui.next(ctx), .Center, t.text_muted)
	}
}

game_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	if s.state == .Connecting {
		ui.label(
			ctx,
			"Joining the world...",
			ui.rect_center(ctx.screen, 400, t.row_height),
			.Center,
		)
		return
	}
	if !app.paused {
		// Crosshair.
		c := ui.rect_center(ctx.screen, 0, 0)
		ui.fill_rect(ctx, {c.x - 8, c.y - 1, 16, 2}, {255, 255, 255, 200})
		ui.fill_rect(ctx, {c.x - 1, c.y - 8, 2, 16}, {255, 255, 255, 200})
		return
	}
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	column := ui.rect_center(ctx.screen, 320, 2 * t.row_height + t.spacing + 80)
	ui.title(ctx, "Paused", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	if ui.button(ctx, "Resume", ui.next(ctx)) {app.paused = false}
	if ui.button(ctx, "Leave World", ui.next(ctx)) {leave_world(app)}
}

// debug_overlay (F3): where we are and what the world costs.
debug_overlay :: proc(app: ^App, ctx: ^ui.Context) {
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, fmt.tprintf("frame %.2f ms", app.last_frame_ms))
	if s := app.session; s != nil && s.state == .Playing {
		p := s.camera.position
		append(
			&lines,
			fmt.tprintf(
				"position %.1f %.1f %.1f  chunk %v  yaw %.0f pitch %.0f",
				p.x,
				p.y,
				p.z,
				camera_chunk(&s.camera),
				s.camera.yaw * math.DEG_PER_RAD,
				s.camera.pitch * math.DEG_PER_RAD,
			),
		)
		w := &s.world
		append(
			&lines,
			fmt.tprintf(
				"client: %d/%d chunks, arrays %.1f MiB, meshing %d (%d waiting), session arena %.1f MiB",
				w.chunks.count,
				len(w.chunks.items) - 1,
				f64(w.arrays.committed) / (1 << 20),
				w.stats.mesh_jobs_busy,
				len(w.to_mesh),
				f64(s.arena.total_used) / (1 << 20),
			),
		)
		ws := &app.world_pass.stats
		append(
			&lines,
			fmt.tprintf(
				"render: %d meshes, %d drawn, vertices %.1f%% of %d M",
				ws.meshes,
				ws.drawn,
				100 * f64(ws.vertices_used) / f64(CHUNK_VERTEX_CAPACITY),
				CHUNK_VERTEX_CAPACITY >> 20,
			),
		)
		st := server.stats(&s.server)
		append(
			&lines,
			fmt.tprintf(
				"server: tick %.2f ms, %d chunks (%d generating), arrays %.1f MiB, arena %.1f MiB",
				st.tick_ms,
				st.chunks_loaded,
				st.chunks_generating,
				f64(st.arrays_bytes) / (1 << 20),
				f64(st.arena_used) / (1 << 20),
			),
		)
	}
	t := &ctx.theme
	r := ctx.screen
	r = ui.cut_top(&r, f32(len(lines)) * t.row_height + 8)
	ui.fill_rect(ctx, r, {0, 0, 0, 170})
	r = ui.rect_shrink(r, 4)
	for line in lines {ui.label(ctx, line, ui.cut_top(&r, t.row_height), .Left)}
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
