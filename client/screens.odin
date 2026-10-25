package client

import "core:fmt"
import "core:math"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"

import "../audio"
import "../base"
import "../game"
import "../server"
import "../ui"

// Screens, with overlays over them (overlays.odin). Escape backs out one
// level: the top overlay; else in a world it pauses, on the title it asks
// to quit.

handle_global_keys :: proc(app: ^App, input: ^ui.Input) {
	if app.options.listening != 0 {
		// The key pressed is being bound: only Escape (leave it) counts.
		if app.input.escape {escape(app)}
		return
	}
	if app.input.console_toggle {overlay_toggle(&app.overlays, .Console)}
	if .F3 in app.input.pressed {app.debug.overlay = !app.debug.overlay}
	if .F4 in app.input.pressed && app.screen == .Game {
		overlay_toggle(&app.overlays, .Tuning)
		// Tuning is watching the game respond: no game menu in the way.
		if overlay_is_open(&app.overlays, .Tuning) {
			overlay_close(&app.overlays, .Options)
			overlay_close(&app.overlays, .Game_Menu)
		}
	}
	if app.settings.keys.screenshot in app.input.pressed {screenshot_request(app, "")}
	if app.settings.keys.fullscreen in app.input.pressed {
		app.settings.fullscreen = !app.settings.fullscreen
		settings_changed(app)
	}
	if app.input.escape {escape(app)}
	chat_keys(app, input)
	inventory_keys(app)
	dial_keys(app)
}

// Each screen and dialog draws in its own id scope, so equal labels in
// different places (the title's "Quit" and the dialog's "Quit") are distinct
// widgets.
app_ui :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "screen")
	defer ui.pop_id(ctx)
	if app.screen != .Game {
		// Every menu screen over the stars.
		starfield_update(&app.stars, app.last_frame_ms / 1000, app.settings.reduce_motion)
		starfield_draw(ctx, &app.stars)
	}
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
	if app.settings.show_fps {fps_overlay(app, ctx)}
	draw_overlays(app, ctx)
}

title_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "title")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 400, 5 * t.row_height + 4 * t.spacing + 120)
	ui.title(ctx, "Voxiverse", ui.cut_top(&column, 80))
	ui.cut_top(&column, 40)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	// Minecraft's order: the two ways to play, then Options and Quit side
	// by side; Accessibility under them, straight to its tab.
	if ui.button(ctx, "Singleplayer", ui.next(ctx)) {
		worlds_refresh(&app.worlds)
		app.screen = .Worlds
	}
	if ui.button(ctx, "Multiplayer", ui.next(ctx)) {multiplayer_open(app)}
	row := ui.next(ctx)
	half := (row.w - t.spacing) / 2
	if ui.button(ctx, "Options...", ui.cut_left(&row, half)) {
		app.options.tab = .Video
		app.screen = .Options
	}
	if ui.button(ctx, "Quit Game", ui.cut_right(&row, half)) {
		overlay_open(&app.overlays, .Quit_Dialog)
	}
	if ui.button(ctx, "Accessibility", ui.rect_center(ui.next(ctx), 200, t.row_height)) {
		app.options.tab = .Accessibility
		app.screen = .Options
	}
	if app.message != "" {
		ui.label(ctx, app.message, ui.next(ctx), .Center, t.text_muted)
	}
	// The version, small and grey in the lower left (Minecraft's place for it).
	small := t.font_size * 0.75
	ui.draw_text(
		ctx,
		{ctx.screen.x + 8, ctx.screen.y + ctx.screen.h - small - 6, ctx.screen.w / 2, small},
		fmt.tprintf("Voxiverse %s", base.COMMIT),
		small,
		t.text_muted,
	)
}

game_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	switch s.state {
	case .Connecting:
		ui.label(
			ctx,
			"Joining the world...",
			ui.rect_center(ctx.screen, 400, t.row_height),
			.Center,
		)
		return
	case .Choosing:
		characters_screen(app, ctx)
		return
	case .Playing, .Failed:
	}
	name_tags(app, ctx)
	if world_paused(app) {return}
	chat_feed(app, ctx)
	// Crosshair.
	c := ui.rect_center(ctx.screen, 0, 0)
	ui.fill_rect(ctx, {c.x - 8, c.y - 1, 16, 2}, {255, 255, 255, 200})
	ui.fill_rect(ctx, {c.x - 1, c.y - 8, 2, 16}, {255, 255, 255, 200})
	hotbar(ctx, s)
}

// game_menu: over the game (alone in our own world, the world stands still
// meanwhile, and it says so; anyone else could be playing otherwise).
game_menu :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "game menu")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	column := ui.rect_center(ctx.screen, 400, 4 * t.row_height + 3 * t.spacing + 80)
	heading := ui.cut_top(&column, 80)
	if s.frozen {
		ui.label(ctx, "Game Paused", ui.cut_bottom(&heading, t.row_height), .Center, t.text_muted)
	}
	ui.title(ctx, "Game Menu", heading)
	ui.layout_begin(ctx, column)
	defer ui.layout_end(ctx)
	if ui.button(ctx, "Back to Game", ui.next(ctx)) {overlay_close(&app.overlays, .Game_Menu)}
	if ui.button(ctx, "Options...", ui.next(ctx)) {overlay_open(&app.overlays, .Options)}
	if session_hosting(s) {
		port := server.stats(&s.server).port
		label := fmt.tprintf("Open to LAN: port %d", port) if port != 0 else "Open to LAN"
		if ui.button(ctx, label, ui.next(ctx), disabled = port != 0) {session_open_lan(app)}
	}
	// Ours: saved on the way out (a scratch world has nothing to save);
	// someone else's server: we only go.
	leave := "Disconnect"
	if session_hosting(s) {
		leave = "Save and Quit to Title" if s.config.save_dir != "" else "Quit to Title"
	}
	if ui.button(ctx, leave, ui.next(ctx)) {leave_world(app)}
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

// hotbar: the inventory's first row along the bottom, the one in hand framed.
@(private = "file")
hotbar :: proc(ctx: ^ui.Context, s: ^Session) {
	t := &ctx.theme
	r := ctx.screen
	row := ui.cut_bottom(&r, SLOT_SIZE.y + 24)
	row = ui.rect_center(row, game.HOTBAR_SLOTS * (SLOT_SIZE.x + t.spacing), SLOT_SIZE.y)
	for i in 0 ..< game.HOTBAR_SLOTS {
		slot := ui.cut_left(&row, SLOT_SIZE.x)
		ui.cut_left(&row, t.spacing)
		stack_slot(ctx, slot, s.inventory.slots[i], i == s.inventory.selected, i + 1)
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
				"client: %d/%d chunks, arrays %.1f MiB, meshing %d (%d waiting), bulk edits %d whole %d late, session arena %.1f MiB",
				w.chunks.count,
				len(w.chunks.items) - 1,
				f64(w.arrays.committed) / (1 << 20),
				w.stats.mesh_jobs_busy,
				len(w.to_mesh),
				w.stats.groups_shown,
				w.stats.groups_late,
				f64(s.arena.total_used) / (1 << 20),
			),
		)
		// Work on the worker threads: meshing here, generating on our own
		// server (a remote one's is its own business).
		mesh_ms := base.frame_stats_summary(&w.stats.mesh_times)
		work := fmt.tprintf("mesh %.2f ms (p99 %.2f)", mesh_ms.avg, mesh_ms.p99)
		if session_hosting(s) {
			gen := server.stats(&s.server).generate
			work = fmt.tprintf("generate %.2f ms (p99 %.2f), %s", gen.avg, gen.p99, work)
		}
		append(&lines, fmt.tprintf("chunks: %s", work))
		ws := &app.world_pass.stats
		append(
			&lines,
			fmt.tprintf(
				"render: %d meshes, %d drawn, %dk triangles, vertices %.1f%% of %d M",
				ws.meshes,
				ws.drawn,
				ws.triangles / 1000,
				100 * f64(ws.vertices_used) / f64(CHUNK_VERTEX_CAPACITY),
				CHUNK_VERTEX_CAPACITY >> 20,
			),
		)
		if s.remote {
			c := &s.link.conn
			append(
				&lines,
				fmt.tprintf(
					"server: %s, %d other players, %d entities, link rtt %.0f ms, packets %d out / %d in, %d resent, %d duplicates",
					net.endpoint_to_string(s.link.server),
					len(s.others),
					len(s.entities),
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
					"server: tick %.2f ms, %d chunks (%d generating), %d block updates waiting, arrays %.1f MiB, arena %.1f MiB, %d players, %d entities near%s",
					st.tick_ms,
					st.chunks_loaded,
					st.chunks_generating,
					st.updates_waiting,
					f64(st.arrays_bytes) / (1 << 20),
					f64(st.arena_used) / (1 << 20),
					st.clients,
					len(s.entities),
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
		if _, servers := server_table(v.table.prefix); servers {
			// The server's: edit a copy, ask for each change.
			size := type_info_of(v.table.type).size
			edited := make([]u8, size, context.temp_allocator)
			mem.copy(raw_data(edited), v.data, size)
			if var_widgets(ctx, v.table, raw_data(edited)) {
				for &var in v.table.vars {
					if base.var_get_f64(v.table, raw_data(edited), &var) !=
					   base.var_get_f64(v.table, v.data, &var) {
						session_set_rule(
							app.session,
							base.var_name(v.table, &var),
							base.var_format(v.table, raw_data(edited), &var),
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
	if ui.button(ctx, "Cancel", no) {overlay_close(&app.overlays, .Quit_Dialog)}
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
