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
				"client: %d/%d chunks, arrays %.1f MiB, meshing %d (%d waiting), bulk %d, arena %.1f MiB",
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
				"render: %d draws (%d calls), %dk tris; %d meshes, %d drawn (verts %.1f%%)",
				app.g.draws.calls,
				app.g.draws.api_calls,
				app.g.draws.triangles / 1000,
				ws.meshes,
				ws.drawn,
				100 * f64(ws.vertices_used) / f64(engine.CHUNK_VERTEX_CAPACITY),
			),
		)
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
					"server mem: arrays %.1f MiB, arena %.1f MiB, %d worlds",
					f64(st.arrays_bytes) / (1 << 20),
					f64(st.arena_used) / (1 << 20),
					st.worlds,
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
					"desyncs: %d detected, corrections %d (error %.2f m)",
					st.desyncs,
					pr.corrections,
					err_dist,
				),
				desync_color,
			)
		}
	}
	a := audio.stats(app.mixer)
	overlay_append(
		&left_lines,
		fmt.tprintf(
			"audio: %s, %d voices (%d real), %d played, %d dropped, %.1f LUFS",
			fmt.tprintf("%d Hz", app.mixer.rate) if app.audio_device.open else "no device (silent)",
			a.voices,
			a.real,
			a.played,
			sync.atomic_load(&app.mixer.dropped),
			a.momentary,
		),
	)

	// Left column rendering:
	if len(left_lines) > 0 {
		col_w := min(ctx.screen.w * 0.48, 540)
		r := ui.Rect {
			x = ctx.screen.x + 4,
			y = ctx.screen.y + 4,
			w = col_w,
			h = f32(len(left_lines)) * t.row_height + 8,
		}
		ui.fill_rect(ctx, r, t.menu_fill)
		inner := ui.rect_shrink(r, 4)
		for line in left_lines {
			ui.label(ctx, line.text, ui.cut_top(&inner, t.row_height), .Left, line.color)
		}
	}

	// Right column rendering:
	if len(right_lines) > 0 {
		col_w := min(ctx.screen.w * 0.48, 540)
		r := ui.Rect {
			x = ctx.screen.x + ctx.screen.w - col_w - 4,
			y = ctx.screen.y + 4,
			w = col_w,
			h = f32(len(right_lines)) * t.row_height + 8,
		}
		ui.fill_rect(ctx, r, t.menu_fill)
		inner := ui.rect_shrink(r, 4)
		for line in right_lines {
			ui.label(ctx, line.text, ui.cut_top(&inner, t.row_height), .Left, line.color)
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
	r := ctx.screen
	r = ui.cut_top(&r, 2 * t.row_height + 8)
	r = ui.cut_right(&r, 260)
	ui.fill_rect(ctx, r, t.hud_fill) // nearly opaque: readable over bright clouds
	inner := ui.rect_shrink(r, 4)
	ui.label(ctx, fmt.tprintf("%.0f FPS", f.fps), ui.cut_top(&inner, t.row_height), .Right)
	detail :=
		fmt.tprintf("%.2f ms, GPU %.2f ms", f.frame_ms, f.gpu_ms) if f.gpu_ms > 0 else fmt.tprintf("%.2f ms", f.frame_ms)
	ui.label(ctx, detail, ui.cut_top(&inner, t.row_height), .Right, t.text_muted)
}

@(private = "file", rodata)
HEART := [6]string{".XX.XX.", "XXXXXXX", "XXXXXXX", ".XXXXX.", "..XXX..", "...X..."}

// health_bar: a heart for every two health points, over the hotbar's left
// end: full, half or empty.
