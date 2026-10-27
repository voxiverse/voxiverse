package client

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "../common/game"
import "../common/telemetry"
import "ui"

// What the client reports about itself: the server cannot see how a client
// runs or what it opens. Three kinds (telemetry.Kind with `client` set):
// Client_Info once per world joined (OS, view distance, fov, how long from
// launch to playing), Client_Overlay when an overlay closes (how long it was
// open), Client_Perf once a minute (frame time p50 and p99). They are queued
// and sent in a Telemetry_Report every 12 seconds at most (the server takes
// a handful a minute); singleplayer reports to its own server the same way.

REPORT_EVERY :: 12 * time.Second
PERF_EVERY :: 60 * time.Second
PERF_FRAMES :: 4096

Queued_Report :: struct {
	kind: telemetry.Kind,
	text: [32]u8,
	len:  int,
	n:    [3]u32,
}

Reporter :: struct {
	queue:     [dynamic]Queued_Report,
	last_send: time.Tick,
	perf_at:   time.Tick,
	was_open:  [Overlay]bool,
	opened:    [Overlay]time.Tick,
	frames:    [PERF_FRAMES]u32, // frame times of the last minute, microseconds
	frame_n:   int,
	told:      ^Session, // the session Client_Info went out for
	asked:     bool, // the consent dialog was shown this run
}

reporter_destroy :: proc(r: ^Reporter) {
	delete(r.queue)
}

@(private = "file")
queue_report :: proc(r: ^Reporter, kind: telemetry.Kind, text: string, a, b, c: u32) {
	if len(r.queue) >= 64 {return}
	q := Queued_Report {
		kind = kind,
		n    = {a, b, c},
	}
	q.len = min(len(text), telemetry.SHORT_MAX)
	copy(q.text[:], text[:q.len])
	append(&r.queue, q)
}

// telemetry_update: once a frame while playing.
telemetry_update :: proc(app: ^App) {
	r := &app.reporter
	// The one question, the first time (not in scripts, benchmarks or checks),
	// and only while telemetry.ask is on (off by default).
	if app.telemetry.ask &&
	   !r.asked &&
	   !app.settings.share_asked &&
	   app.screen == .Title &&
	   !app.scripted &&
	   !app.benchmark {
		r.asked = true
		overlay_open(&app.overlays, .Consent)
	}
	s := app.session
	if s == nil || s.state != .Playing || s.loading != nil {
		r.told = nil
		return
	}
	if r.told != s {
		r.told = s
		radius, _ := view_size(app)
		queue_report(
			r,
			.Client_Info,
			strings.to_lower(fmt.tprint(ODIN_OS), context.temp_allocator),
			u32(radius),
			u32(app.settings.fov),
			u32(time.duration_milliseconds(time.tick_since(app.launched))),
		)
		r.last_send, r.perf_at = time.tick_now(), time.tick_now()
		r.frame_n = 0
	}
	// Overlays: how long each was open.
	for o in Overlay {
		open := overlay_is_open(&app.overlays, o)
		if open && !r.was_open[o] {r.opened[o] = time.tick_now()}
		if !open && r.was_open[o] {
			ms := time.duration_milliseconds(time.tick_since(r.opened[o]))
			queue_report(
				r,
				.Client_Overlay,
				strings.to_lower(fmt.tprint(o), context.temp_allocator),
				u32(ms),
				0,
				0,
			)
		}
		r.was_open[o] = open
	}
	// Frame times.
	if r.frame_n < PERF_FRAMES {
		r.frames[r.frame_n] = u32(app.last_frame_ms * 1000)
		r.frame_n += 1
	}
	if time.tick_since(r.perf_at) >= PERF_EVERY && r.frame_n > 10 {
		times := slice.clone(r.frames[:r.frame_n], context.temp_allocator)
		slice.sort(times)
		queue_report(
			r,
			.Client_Perf,
			"",
			times[len(times) / 2],
			times[len(times) * 99 / 100],
			u32(r.frame_n),
		)
		r.frame_n, r.perf_at = 0, time.tick_now()
	}
	// Send.
	if len(r.queue) > 0 && time.tick_since(r.last_send) >= REPORT_EVERY {
		telemetry_send(s, r)
		r.last_send = time.tick_now()
	}
}

// telemetry_send sends up to a message's worth of the queue.
telemetry_send :: proc(s: ^Session, r: ^Reporter) {
	n := min(len(r.queue), game.MAX_TELEMETRY_ENTRIES)
	report := game.Telemetry_Report {
		count = n,
	}
	for i in 0 ..< n {
		q := &r.queue[i]
		report.entries[i] = {u8(q.kind), string(q.text[:q.len]), q.n}
	}
	send_message(s, report)
	remove_range(&r.queue, 0, n)
}

// consent_dialog: the question, once: share anonymous play data?
consent_dialog :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "consent dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 520, 260)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, "Help improve Voxiverse?", ui.cut_top(&inner, t.row_height), .Center)
	ui.cut_top(&inner, t.spacing)
	lines := [?]string {
		"Share anonymous play data: what is built, broken and found,",
		"and how the game runs. Never your name, your chat or your address.",
		"You can change this any time in Options, under Profile.",
	}
	for line in lines {ui.label(ctx, line, ui.cut_top(&inner, t.row_height), .Center)}
	buttons := ui.cut_bottom(&inner, t.row_height)
	no := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	answer := -1
	if ui.button(ctx, "Share", buttons) {answer = 1}
	if ui.button(ctx, "No thanks", no) {answer = 0}
	if answer >= 0 {
		app.settings.share_data, app.settings.share_asked = answer == 1, true
		settings_changed(app)
		overlay_close(&app.overlays, .Consent)
	}
}
