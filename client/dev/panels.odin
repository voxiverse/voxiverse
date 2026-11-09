package dev

import "core:fmt"
import "core:math"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"

import "client:audio"
import "client:engine"
import "client:gpu"
import "client:platform"
import "client:screen"
import "client:ui"
import "common:base"
import "common:game"
import "server:core"

net_line :: proc(s: ^engine.Session) -> string {
	n := &s.net
	total :: proc(t: game.Traffic) -> (bytes: int) {
		for b in t.bytes {bytes += b}
		return
	}
	return fmt.tprintf(
		"net: RTT %.0f ms, down %.1f KB/s, up %.1f KB/s%s",
		n.rtt_ms,
		f64(total(n.rates[.Server])) / 1000,
		f64(total(n.rates[.Client])) / 1000,
		", tracing" if game.pipe_tracing(&s.pipe) else "",
	)
}

// coordinates_shown: F3 may show where we are (rules.show_coordinates, or the
// permission debug.coordinates).
coordinates_shown :: proc(s: ^engine.Session) -> bool {
	return s.rules.show_coordinates || engine.session_allowed(s, "debug.coordinates")
}

// hotbar: the inventory's first row along the bottom, the one in hand framed.

Overlay_Line :: struct {
	text:  string,
	color: Maybe(ui.Color),
}

@(private = "file")
overlay_append :: proc(lines: ^[dynamic]Overlay_Line, text: string, color: Maybe(ui.Color) = nil) {
	append(lines, Overlay_Line{text, color})
}

debug_overlay :: proc(app: ^engine.App, ctx: ^ui.Context) {
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	t := &ctx.theme
	left_lines := make([dynamic]Overlay_Line, context.temp_allocator)
	right_lines := make([dynamic]Overlay_Line, context.temp_allocator)

	fps_color: Maybe(ui.Color) = nil
	if app.fps.fps < 30 {
		fps_color = t.log_error
	} else if app.fps.fps < 55 {
		fps_color = t.log_warn
	}

	overlay_append(
		&left_lines,
		fmt.tprintf(
			"%.0f FPS, frame %.2f ms, GPU %.2f ms, vsync %s (%v)",
			app.fps.fps,
			app.fps.frame_ms,
			app.fps.gpu_ms,
			"on" if app.g.swapchain.vsync else "off",
			app.g.swapchain.present_mode,
		),
		fps_color,
	)
	if info, ok := platform.window_display_info(&app.window); ok {
		hz_text := "refresh unknown"
		if info.refresh_hz != 0 {hz_text = fmt.tprintf("%.0f Hz", info.refresh_hz)}
		name := info.name if info.name != "" else "(unnamed display)"
		overlay_append(
			&left_lines,
			fmt.tprintf("display: %s  %dx%d @ %s", name, info.width, info.height, hz_text),
		)
	}
	if s := app.session; s != nil && s.state == .Playing {
		p := s.camera.position
		if coordinates_shown(s) {
			overlay_append(
				&left_lines,
				fmt.tprintf(
					"position %.1f %.1f %.1f  chunk %v  yaw %.0f pitch %.0f",
					p.x,
					p.y,
					p.z,
					engine.camera_chunk(&s.camera),
					s.camera.yaw * math.DEG_PER_RAD,
					s.camera.pitch * math.DEG_PER_RAD,
				),
			)
		}
		overlay_append(
			&left_lines,
			fmt.tprintf("sky: time of day %.2f", game.time_of_day(s.clock)),
		)
		w := &s.world
		overlay_append(
			&left_lines,
			fmt.tprintf(
				"client: %d/%d chunks, arrays %.1f MiB, mesh %d (%d wait), bulk %d, arena %.1f MiB",
				w.chunks.count,
				len(w.chunks.items) - 1,
				f64(w.arrays.committed) / (1 << 20),
				w.stats.mesh_jobs_busy,
				len(w.to_mesh),
				w.stats.groups_shown,
				f64(s.arena.total_used) / (1 << 20),
			),
		)
		mesh_ms := base.frame_stats_summary(&w.stats.mesh_times)
		work := fmt.tprintf("mesh %.2f ms (p99 %.2f)", mesh_ms.avg, mesh_ms.p99)
		if engine.session_hosting(s) {
			gen := core.stats(&s.server).generate
			work = fmt.tprintf("generate %.2f ms (p99 %.2f), %s", gen.avg, gen.p99, work)
		}
		overlay_append(&left_lines, fmt.tprintf("chunks: %s", work))
		ws := &app.world_pass.stats
		overlay_append(
			&left_lines,
			fmt.tprintf(
				"render: %d draws (%d calls), %dk tris; %d/%d meshes (verts %.1f%%)",
				app.g.draws.calls,
				app.g.draws.api_calls,
				app.g.draws.triangles / 1000,
				ws.drawn,
				ws.meshes,
				100 * f64(ws.vertices_used) / f64(engine.CHUNK_VERTEX_CAPACITY),
			),
		)
		if app.g.pipeline_stats_supported && app.g.pipeline_stats.vertex_invocations > 0 {
			ps := &app.g.pipeline_stats
			overlay_append(
				&left_lines,
				fmt.tprintf(
					"pipeline: vert %dk, clip %dk, frag %dk, comp %dk",
					ps.vertex_invocations / 1000,
					ps.clipping_primitives / 1000,
					ps.fragment_invocations / 1000,
					ps.compute_invocations / 1000,
				),
			)
		}
		memory := gpu.memory_report(&app.g)
		vram := fmt.tprintf("memory: ours %.0f MiB", f64(memory.ours) / (1 << 20))
		if memory.budget > 0 {
			vram = fmt.tprintf(
				"%s, process %.0f of %.0f MiB budget",
				vram,
				f64(memory.usage) / (1 << 20),
				f64(memory.budget) / (1 << 20),
			)
		}
		overlay_append(
			&left_lines,
			fmt.tprintf("%s; uploads %.1f KiB", vram, f64(ws.uploaded_bytes) / 1024),
		)

		// Right column: Server, network, prediction & desync diagnostics
		if s.remote {
			c := &s.link.conn
			overlay_append(
				&right_lines,
				fmt.tprintf(
					"server: %s (remote), %d players, %d entities",
					net.endpoint_to_string(s.link.server),
					len(s.others) + 1,
					len(s.entities),
				),
				t.meter_fill,
			)
			overlay_append(
				&right_lines,
				fmt.tprintf(
					"net: RTT %.0f ms, packets %d out / %d in, %d resent, %d dups",
					c.rtt_ms,
					c.stats.packets_sent,
					c.stats.packets_received,
					c.stats.resent,
					c.stats.duplicates,
				),
			)
		} else {
			st := core.stats(&s.server)
			tps := 1000.0 / max(st.tick_ms, 1.0)
			if tps > 20.0 {tps = 20.0}

			tick_color: Maybe(ui.Color) = t.success
			if st.tick_ms > 100.0 {
				tick_color = t.log_error
			} else if st.tick_ms > 50.0 {
				tick_color = t.log_warn
			}

			overlay_append(
				&right_lines,
				fmt.tprintf(
					"server: tick %.2f ms (%.1f TPS / 20)%s",
					st.tick_ms,
					tps,
					fmt.tprintf(", port %d", st.port) if st.port != 0 else "",
				),
				tick_color,
			)

			// Breakdown of slowest server tick phases:
			if st.slowest_phase_n > 0 {
				pb := strings.builder_make(context.temp_allocator)
				for i in 0 ..< st.slowest_phase_n {
					phase := st.slowest_phases[i]
					if i > 0 {strings.write_string(&pb, ", ")}
					fmt.sbprintf(&pb, "%s %.0fms", phase.name, phase.ms)
				}
				phase_color: Maybe(ui.Color) = t.log_warn if st.tick_ms > 50.0 else nil
				overlay_append(
					&right_lines,
					fmt.tprintf("phases: %s", strings.to_string(pb)),
					phase_color,
				)
			}

			overlay_append(
				&right_lines,
				fmt.tprintf(
					"chunks: %d loaded (%d generating), %d block updates waiting",
					st.chunks_loaded,
					st.chunks_generating,
					st.updates_waiting,
				),
			)
			overlay_append(
				&right_lines,
				fmt.tprintf(
					"server mem: arrays %.1f MiB, arena %.1f MiB",
					f64(st.arrays_bytes) / (1 << 20),
					f64(st.arena_used) / (1 << 20),
				),
			)
			overlay_append(
				&right_lines,
				fmt.tprintf("entities: %d near, %d players online", len(s.entities), st.clients),
			)
		}

		overlay_append(&right_lines, net_line(s))
		overlay_append(
			&right_lines,
			fmt.tprintf("island: %d (%d chunks)", s.island.id, s.island.chunks),
		)

		pr := &s.prediction
		err_dist := math.sqrt(
			pr.error.x * pr.error.x + pr.error.y * pr.error.y + pr.error.z * pr.error.z,
		)
		pred_color: Maybe(ui.Color) = nil
		if pr.corrections > 0 || err_dist > 0.05 {
			pred_color = t.log_warn
		}
		overlay_append(
			&right_lines,
			fmt.tprintf(
				"prediction: %s%s, in flight %d",
				"flying" if pr.state.flying else "walking",
				", on ground" if pr.state.on_ground else "",
				pr.count,
			),
			pred_color,
		)

		if !s.remote {
			st := core.stats(&s.server)
			desync_color: Maybe(ui.Color) = nil
			if st.desyncs > 0 || pr.corrections > 0 {
				desync_color = t.log_error
			}
			overlay_append(
				&right_lines,
				fmt.tprintf(
					"desyncs: %d, corrections %d (error %.2f m)",
					st.desyncs,
					pr.corrections,
					err_dist,
				),
				desync_color,
			)
		}
	}
	a := audio.stats(app.mixer)
	dsp_str := ""
	if a.cb_last_ns > 0 {
		dsp_str = fmt.tprintf(", DSP %.0f µs", f64(a.cb_last_ns) / 1000.0)
	}
	overlay_append(
		&left_lines,
		fmt.tprintf(
			"audio: %s, voices %d (%d real)%s, played %d, dropped %d, %.1f LUFS",
			fmt.tprintf("%d Hz", app.mixer.rate) if app.audio_device.open else "silent",
			a.voices,
			a.real,
			dsp_str,
			a.played,
			sync.atomic_load(&app.mixer.dropped),
			a.momentary,
		),
	)

	// Left column rendering:
	if len(left_lines) > 0 {
		max_w: f32 = 0
		for line in left_lines {
			w := ui.measure_text(ctx, line.text, t.font_size)
			if w > max_w {max_w = w}
		}
		col_w := clamp(max_w + 16, 200, ctx.screen.w * 0.48)
		r := ui.anchor_rect(
			ctx.screen,
			.Top_Left,
			{col_w, f32(len(left_lines)) * t.row_height + 8},
			{4, 4},
		)
		ui.fill_rect(ctx, r, t.menu_fill)
		ui.begin_column(ctx, ui.rect_shrink(r, 4), 0)
		defer ui.end_column(ctx)
		for line in left_lines {
			ui.label_clipped(ctx, line.text, ui.next(ctx), .Left, line.color)
		}
	}

	// Right column rendering:
	if len(right_lines) > 0 {
		max_w: f32 = 0
		for line in right_lines {
			w := ui.measure_text(ctx, line.text, t.font_size)
			if w > max_w {max_w = w}
		}
		col_w := clamp(max_w + 16, 200, ctx.screen.w * 0.48)
		r := ui.anchor_rect(
			ctx.screen,
			.Top_Right,
			{col_w, f32(len(right_lines)) * t.row_height + 8},
			{-4, 4},
		)
		ui.fill_rect(ctx, r, t.menu_fill)
		ui.begin_column(ctx, ui.rect_shrink(r, 4), 0)
		defer ui.end_column(ctx)
		for line in right_lines {
			ui.label_clipped(ctx, line.text, ui.next(ctx), .Right, line.color)
		}
	}
}

// tuning_panel (F4): every variable, live; for tuning by feel.
tuning_panel :: proc(app: ^engine.App, ctx: ^ui.Context) {
	ui.push_id(ctx, "tuning")
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Popup)
	defer ui.end_layer(ctx, prev)
	t := &ctx.theme
	vars := engine.app_variables(app)
	rows := 0
	for v in vars {rows += len(v.table.vars) + 1}
	r := ctx.screen
	panel := ui.cut_right(&r, 460)
	panel.h = min(panel.h, f32(rows) * (t.row_height + t.spacing) + 2 * t.padding)
	ui.panel(ctx, panel)
	ui.begin_column(ctx, ui.rect_shrink(panel, t.padding))
	defer ui.end_column(ctx)
	for v in vars {
		ui.label(
			ctx,
			strings.trim_suffix(v.table.prefix, ".") if v.table.prefix != "" else "settings",
			ui.next(ctx),
			.Left,
			t.text_muted,
		)
		if _, servers := engine.server_table(v.table.prefix); servers {
			// The server's: edit a copy, ask for each change.
			size := type_info_of(v.table.type).size
			edited := make([]u8, size, context.temp_allocator)
			mem.copy(raw_data(edited), v.data, size)
			if screen.var_widgets(ctx, v.table, raw_data(edited)) {
				for &var in v.table.vars {
					if base.var_get_f64(v.table, raw_data(edited), &var) !=
					   base.var_get_f64(v.table, v.data, &var) {
						engine.session_set_rule(
							app.session,
							base.var_name(v.table, &var),
							base.var_format(v.table, raw_data(edited), &var),
						)
					}
				}
			}
		} else if screen.var_widgets(ctx, v.table, v.data) && v.data == &app.settings {
			engine.settings_changed(app)
		}
	}
}

fps_overlay :: proc(app: ^engine.App, ctx: ^ui.Context) {
	prev := ui.begin_layer(ctx, .Tooltip)
	defer ui.end_layer(ctx, prev)
	f := app.fps
	t := &ctx.theme
	r := ui.anchor_rect(ctx.screen, .Top_Right, {260, 2 * t.row_height + 8})
	ui.fill_rect(ctx, r, t.hud_fill) // nearly opaque: readable over bright clouds
	ui.begin_column(ctx, ui.rect_shrink(r, 4), 0)
	defer ui.end_column(ctx)
	ui.label_clipped(ctx, fmt.tprintf("%.0f FPS", f.fps), ui.next(ctx), .Right)
	detail :=
		fmt.tprintf("%.2f ms, GPU %.2f ms", f.frame_ms, f.gpu_ms) if f.gpu_ms > 0 else fmt.tprintf("%.2f ms", f.frame_ms)
	ui.label_clipped(ctx, detail, ui.next(ctx), .Right, t.text_muted)
}

@(private = "file", rodata)
HEART := [6]string{".XX.XX.", "XXXXXXX", "XXXXXXX", ".XXXXX.", "..XXX..", "...X..."}

// health_bar: a heart for every two health points, over the hotbar's left
// end: full, half or empty.
