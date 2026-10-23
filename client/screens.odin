package client

import "core:fmt"
import "core:math"
import "core:net"
import "core:strings"
import "core:sync"

import "../audio"
import "../base"
import "../game"
import "../server"
import "../ui"

// Screens. Escape backs out one level: console, quit dialog, options; in a
// world it toggles the pause menu; on the title it asks to quit.

handle_global_keys :: proc(app: ^App, input: ^ui.Input) {
	if app.input.console_toggle {
		app.console.open = !app.console.open
	}
	if .F3 in app.input.pressed {app.debug.overlay = !app.debug.overlay}
	if .F4 in app.input.pressed {app.tuning = !app.tuning}
	if .F2 in app.input.pressed {screenshot_request(app, "")}
	if .F11 in app.input.pressed {
		app.settings.fullscreen = !app.settings.fullscreen
		if !app.scripted {app.settings_dirty = true}
	}
	if app.input.escape {
		switch {
		case app.console.open:
			app.console.open = false
		case app.tuning:
			app.tuning = false
		case app.quit_dialog:
			app.quit_dialog = false
		case app.screen == .Options, app.screen == .Worlds:
			app.screen = .Title
		case app.screen == .Multiplayer:
			multiplayer_close(&app.multiplayer)
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
	case .Worlds:
		worlds_screen(app, ctx)
	case .Multiplayer:
		multiplayer_screen(app, ctx)
	case .Game:
		game_screen(app, ctx)
	}
	if app.debug.overlay {debug_overlay(app, ctx)}
	if app.tuning {tuning_panel(app, ctx)}
	if app.quit_dialog {quit_dialog(app, ctx)}
	if app.settings.show_fps {fps_overlay(app, ctx)}
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
	if ui.button(ctx, "Singleplayer", ui.next(ctx)) {
		worlds_refresh(&app.worlds)
		app.screen = .Worlds
	}
	if ui.button(ctx, "Multiplayer", ui.next(ctx)) {multiplayer_open(app)}
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
	name_tags(app, ctx)
	if !app.paused {
		// Crosshair.
		c := ui.rect_center(ctx.screen, 0, 0)
		ui.fill_rect(ctx, {c.x - 8, c.y - 1, 16, 2}, {255, 255, 255, 200})
		ui.fill_rect(ctx, {c.x - 1, c.y - 8, 2, 16}, {255, 255, 255, 200})
		hotbar(ctx, s)
		return
	}
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	column := ui.rect_center(ctx.screen, 320, 3 * t.row_height + 2 * t.spacing + 80)
	ui.title(ctx, "Paused", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	if ui.button(ctx, "Resume", ui.next(ctx)) {app.paused = false}
	if session_hosting(s) {
		port := server.stats(&s.server).port
		label := fmt.tprintf("Open to LAN: port %d", port) if port != 0 else "Open to LAN"
		if ui.button(ctx, label, ui.next(ctx), disabled = port != 0) {session_open_lan(app)}
	}
	if ui.button(
		ctx,
		"Save and Leave" if app.session.config.save_dir != "" else "Leave World",
		ui.next(ctx),
	) {
		leave_world(app)
	}
}

// net_line: round trip, traffic per second each way, the busiest kind.
@(private = "file")
net_line :: proc(s: ^Session) -> string {
	n := &s.net
	total :: proc(t: game.Traffic) -> (bytes: int) {
		for b in t.bytes {bytes += b}
		return
	}
	busiest :: proc(t: game.Traffic, sender: game.Side) -> string {
		best := 0
		for m, k in t.messages {if m > t.messages[best] {best = k}}
		if t.messages[best] == 0 {return "-"}
		return fmt.tprintf("%s %d/s", game.message_kind_name(sender, u8(best)), t.messages[best])
	}
	return fmt.tprintf(
		"net: rtt %.0f ms, down %.1f KB/s (%s), up %.2f KB/s (%s)%s",
		n.rtt_ms,
		f64(total(n.rates[.Server])) / 1000,
		busiest(n.rates[.Server], .Server),
		f64(total(n.rates[.Client])) / 1000,
		busiest(n.rates[.Client], .Client),
		", tracing" if game.pipe_tracing(&s.pipe) else "",
	)
}

// hotbar: the placeable blocks along the bottom, the selected one framed.
@(private = "file")
hotbar :: proc(ctx: ^ui.Context, s: ^Session) {
	t := &ctx.theme
	SLOT :: 96
	r := ctx.screen
	row := ui.cut_bottom(&r, t.row_height + 24)
	row = ui.rect_center(row, f32(len(HOTBAR)) * (SLOT + t.spacing), t.row_height)
	for b, i in HOTBAR {
		slot := ui.cut_left(&row, SLOT)
		ui.cut_left(&row, t.spacing)
		ui.fill_rect(ctx, slot, {0, 0, 0, 150})
		if i == s.hotbar {ui.stroke_rect(ctx, slot, 2, t.text)}
		label := fmt.tprintf("%d %s", i + 1, game.BLOCK_INFO[b].name)
		ui.label(ctx, label, slot, .Center, t.text if i == s.hotbar else t.text_muted)
	}
}

// debug_overlay (F3): where we are and what the world costs.
debug_overlay :: proc(app: ^App, ctx: ^ui.Context) {
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	lines := make([dynamic]string, context.temp_allocator)
	append(
		&lines,
		fmt.tprintf(
			"%.0f FPS, frame %.2f ms, GPU %.2f ms, vsync %s (%v)",
			app.fps.fps,
			app.fps.frame_ms,
			app.fps.gpu_ms,
			"on" if app.g.swapchain.vsync else "off",
			app.g.swapchain.present_mode,
		),
	)
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
		if s.remote {
			c := &s.link.conn
			append(
				&lines,
				fmt.tprintf(
					"server: %s, %d other players, link rtt %.0f ms, packets %d out / %d in, %d resent, %d duplicates",
					net.endpoint_to_string(s.link.server),
					len(s.others),
					c.rtt_ms,
					c.stats.packets_sent,
					c.stats.packets_received,
					c.stats.resent,
					c.stats.duplicates,
				),
			)
		} else {
			st := server.stats(&s.server)
			append(
				&lines,
				fmt.tprintf(
					"server: tick %.2f ms, %d chunks (%d generating), arrays %.1f MiB, arena %.1f MiB, %d players%s",
					st.tick_ms,
					st.chunks_loaded,
					st.chunks_generating,
					f64(st.arrays_bytes) / (1 << 20),
					f64(st.arena_used) / (1 << 20),
					st.clients,
					fmt.tprintf(", LAN port %d", st.port) if st.port != 0 else "",
				),
			)
		}
		append(&lines, net_line(s))
		pr := &s.prediction
		append(
			&lines,
			fmt.tprintf(
				"player: %s%s, inputs in flight %d, corrections %d (now %.2f blocks off)",
				"flying" if pr.state.flying else "walking",
				", on ground" if pr.state.on_ground else "",
				pr.count,
				pr.corrections,
				math.sqrt(
					pr.error.x * pr.error.x + pr.error.y * pr.error.y + pr.error.z * pr.error.z,
				),
			),
		)
	}
	a := audio.stats(&app.mixer)
	append(
		&lines,
		fmt.tprintf(
			"audio: %s, %d voices, %d sounds played, %d dropped",
			fmt.tprintf("%d Hz", app.mixer.rate) if app.audio_device.open else "no device (silent)",
			a.voices,
			a.played,
			sync.atomic_load(&app.mixer.dropped),
		),
	)
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
	rows := f32(len(SETTINGS_VARS) + 1)
	column := ui.rect_center(ctx.screen, 560, rows * (t.row_height + t.spacing) + 90)
	ui.title(ctx, "Options", ui.cut_top(&column, 80))
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	if var_widgets(ctx, settings_table(), &app.settings) {settings_changed(app)}
	ui.next(ctx, 10)
	if ui.button(ctx, "Back", ui.next(ctx)) {
		app.screen = .Title
		if app.settings_dirty {settings_save(app)}
	}
}

// var_widgets draws a checkbox or slider per variable of the table, in the
// current layout; true if any changed.
var_widgets :: proc(ctx: ^ui.Context, table: base.Var_Table, data: rawptr) -> (changed: bool) {
	ui.push_id(ctx, table.prefix)
	defer ui.pop_id(ctx)
	for &v in table.vars {
		label := var_label(table, &v)
		kind, _ := base.var_kind(table, &v)
		switch kind {
		case .Bool:
			value := base.var_get_f64(table, data, &v) != 0
			if ui.checkbox(ctx, label, &value, ui.next(ctx)) {
				base.var_set_f64(table, data, &v, 1 if value else 0)
				changed = true
			}
		case .Int, .F32:
			value := f32(base.var_get_f64(table, data, &v))
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
				base.var_set_f64(table, data, &v, f64(value))
				changed = true
			}
		case .Text:
			// Edited in place; a keystroke that makes it invalid is refused.
			r := ui.next(ctx)
			ui.label(ctx, label, ui.cut_left(&r, r.w * 0.45))
			_, offset := base.var_kind(table, &v)
			value := (^base.Var_Text)(uintptr(data) + offset)
			text := make([dynamic]u8, context.temp_allocator)
			append(&text, base.var_text(value))
			ui.text_input(ctx, v.field, &text, r, placeholder = v.help)
			if string(text[:]) != base.var_text(value) &&
			   base.var_set(table, data, base.var_name(table, &v), string(text[:])) == .None {
				changed = true
			}
		}
	}
	return
}

// var_label: "mouse_sensitivity" -> "Mouse sensitivity".
@(private = "file")
var_label :: proc(table: base.Var_Table, v: ^base.Var) -> string {
	if v.label != "" {return v.label}
	s := strings.to_upper(v.field[:1], context.temp_allocator)
	rest, _ := strings.replace_all(v.field[1:], "_", " ", context.temp_allocator)
	return strings.concatenate({s, rest}, context.temp_allocator)
}

// tuning_panel (F4): every variable, live; for tuning by feel.
tuning_panel :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "tuning")
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Popup)
	defer ui.end_layer(ctx, prev)
	t := &ctx.theme
	vars := app_variables(app)
	rows := 0
	for v in vars {rows += len(v.table.vars) + 1}
	r := ctx.screen
	panel := ui.cut_right(&r, 460)
	panel.h = min(panel.h, f32(rows) * (t.row_height + t.spacing) + 2 * t.padding)
	ui.panel(ctx, panel)
	ui.layout_begin(ctx, ui.rect_shrink(panel, t.padding))
	defer ui.layout_end(ctx)
	for v in vars {
		ui.label(
			ctx,
			strings.trim_suffix(v.table.prefix, ".") if v.table.prefix != "" else "settings",
			ui.next(ctx),
			.Left,
			t.text_muted,
		)
		if v.table.type == game.Rules {
			// The server's: edit a copy, ask for each change.
			edited := app.session.rules
			if var_widgets(ctx, v.table, &edited) {
				for &var in v.table.vars {
					if base.var_get_f64(v.table, &edited, &var) !=
					   base.var_get_f64(v.table, v.data, &var) {
						session_set_rule(
							app.session,
							base.var_name(v.table, &var),
							base.var_format(v.table, &edited, &var),
						)
					}
				}
			}
		} else if var_widgets(ctx, v.table, v.data) && v.data == &app.settings {
			settings_changed(app)
		}
	}
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

// fps_overlay: frames per second, big enough to read at a glance, and
// under it the frame time and the GPU's share of it.
fps_overlay :: proc(app: ^App, ctx: ^ui.Context) {
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	f := app.fps
	t := &ctx.theme
	r := ctx.screen
	r = ui.cut_top(&r, 2 * t.row_height + 8)
	r = ui.cut_right(&r, 260)
	ui.fill_rect(ctx, r, {0, 0, 0, 235}) // nearly opaque: readable over bright clouds
	inner := ui.rect_shrink(r, 4)
	ui.label(ctx, fmt.tprintf("%.0f FPS", f.fps), ui.cut_top(&inner, t.row_height), .Right)
	detail :=
		fmt.tprintf("%.2f ms, GPU %.2f ms", f.frame_ms, f.gpu_ms) if f.gpu_ms > 0 else fmt.tprintf("%.2f ms", f.frame_ms)
	ui.label(ctx, detail, ui.cut_top(&inner, t.row_height), .Right, t.text_muted)
}
