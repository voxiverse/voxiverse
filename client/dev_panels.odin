package client

import "core:fmt"
import "core:math"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"

import "../base"
import "../common/game"
import "../server"
import "ui"
import "audio"

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
	a := audio.stats(app.mixer)
	append(
		&lines,
		fmt.tprintf(
			"audio: %s, %d voices (%d real), %d sounds played, %d dropped, %.1f LUFS",
			fmt.tprintf("%d Hz", app.mixer.rate) if app.audio_device.open else "no device (silent)",
			a.voices,
			a.real,
			a.played,
			sync.atomic_load(&app.mixer.dropped),
			a.momentary,
		),
	)
	t := &ctx.theme
	r := ctx.screen
	r = ui.cut_top(&r, f32(len(lines)) * t.row_height + 8)
	ui.fill_rect(ctx, r, t.menu_fill)
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

fps_overlay :: proc(app: ^App, ctx: ^ui.Context) {
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

