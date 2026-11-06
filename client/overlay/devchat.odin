package overlay

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "client:engine"
import "client:ui"
import "common:base"
import "common:game"
import "server:collector"

// Developer chat (docs/telemetry.md, "Developer chat"): the conversation with
// the developers, opened from the title screen or the game menu while the
// `devchat` setting names a collector. Enter sends the line; the replies come
// in on their own (every 30 s while it is open). A reply that arrives while it
// is closed shows a small notice in the corner until it is opened.

DEVCHAT_WIDTH :: 760

// devchat_context: what a message carries besides its text: the version
// always, and where the player is when they chose to attach it.
devchat_context :: proc(app: ^engine.App, attach: bool) -> collector.Chat_Context {
	ctx := collector.Chat_Context {
		version = base.version_text(),
	}
	s := app.session
	if !attach || s == nil {return ctx}
	if s.config.save_dir != "" {ctx.universe = filepath.base(s.config.save_dir)}
	ctx.world = game.address_text(s.welcome.address)
	ctx.has_tick, ctx.tick = true, u64(max(s.render_clock.time, 0))
	p := s.prediction.state.position
	ctx.has_pos, ctx.pos = true, {i32(p.x), i32(p.y), i32(p.z)}
	return ctx
}

// devchat_ui: the open chat (an overlay over the title screen or the game).
devchat_ui :: proc(app: ^engine.App, ctx: ^ui.Context, top: bool) {
	if !app.devchat.running {
		engine.overlay_close(&app.overlays, .Devchat)
		return
	}
	ui.push_id(ctx, "devchat")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	chat := &app.devchat.chat
	entries, status, waiting, _ := collector.chat_view(chat)
	app.devchat_seen = collector.chat_replies(chat) // (open: every reply is seen)

	area := ui.rect_center(
		ctx.screen,
		min(DEVCHAT_WIDTH, ctx.screen.w - 2 * t.padding),
		ctx.screen.h - (60 if ctx.screen.h >= 600 else 2 * t.padding),
	)
	ui.title(
		ctx,
		engine.tr(.Devchat_Title),
		ui.cut_top(&area, 60 if ctx.screen.h >= 600 else t.row_height),
	)
	state := engine.tr(.Devchat_Connected)
	switch status {
	case .Unknown:
		state = engine.tr(.Devchat_Connecting)
	case .Offline:
		state = engine.tr(.Devchat_Offline)
	case .Connected:
	}
	if waiting > 0 {state = fmt.tprintf("%s · %s", state, engine.tr(.Devchat_Waiting, waiting))}
	ui.label(ctx, state, ui.cut_top(&area, t.row_height), .Left, t.text_muted)

	buttons := ui.cut_bottom(&area, t.row_height)
	ui.cut_bottom(&area, t.spacing)
	input_rect := ui.cut_bottom(&area, (3 if ctx.screen.h >= 600 else 1.5) * t.row_height)
	ui.cut_bottom(&area, t.spacing)
	attach_rect := ui.cut_bottom(&area, t.row_height)
	ui.cut_bottom(&area, t.spacing)

	devchat_lines(app, ctx, area, entries)

	ui.checkbox(ctx, engine.tr(.Devchat_Attach), &app.devchat_attach, attach_rect)
	counter := fmt.tprintf("%d / %d", len(app.devchat_line.text), game.MAX_DEV_TEXT)
	counter_rect := ui.cut_right(&input_rect, 110)
	ui.label(ctx, counter, counter_rect, .Right, t.text_muted)
	submitted := ui.text_input(
		ctx,
		"devchat input",
		&app.devchat_line.text,
		input_rect,
		engine.tr(.Devchat_Hint),
		multiline = true,
	)
	if top && !ui.osk_is_open(ctx) {ctx.focused = ui.get_id(ctx, "devchat input")}
	send := submitted
	close_rect := ui.cut_right(&buttons, 180)
	ui.cut_right(&buttons, t.spacing)
	send_rect := ui.cut_right(&buttons, 180)
	if ui.button(ctx, engine.tr(.Devchat_Send), send_rect) {send = true}
	if ui.button(ctx, engine.tr(.Devchat_Close), close_rect) {engine.devchat_close(app)}
	if send {
		line := string(app.devchat_line.text[:])
		if collector.chat_send(chat, line, devchat_context(app, app.devchat_attach)) {
			clear(&app.devchat_line.text)
		}
	}
}

// devchat_lines draws the conversation up from the bottom of area, wrapped,
// the newest last; the wheel scrolls.
@(private = "file")
devchat_lines :: proc(
	app: ^engine.App,
	ctx: ^ui.Context,
	area: ui.Rect,
	entries: []collector.Chat_Entry,
) {
	t := &ctx.theme
	ui.fill_rect(ctx, area, t.list_fill)
	ui.stroke_rect(ctx, area, 1, t.list_border)
	if len(entries) == 0 {
		ui.label(
			ctx,
			engine.tr(.Devchat_Empty),
			ui.rect_shrink(area, t.padding),
			.Center,
			t.text_muted,
		)
		return
	}
	if ui.rect_contains(area, ctx.input.mouse) {app.devchat_scroll += ctx.input.wheel.y * 3}
	app.devchat_scroll = clamp(app.devchat_scroll, 0, f32(max(len(entries) - 1, 0)))
	size := t.font_size
	line_h := size * 1.35
	width := area.w - 2 * t.padding
	ui.push_clip_rect(ctx, area)
	defer ui.pop_clip_rect(ctx)
	y := area.y + area.h - t.padding
	for i := len(entries) - 1 - int(app.devchat_scroll); i >= 0 && y > area.y; i -= 1 {
		e := entries[i]
		who := engine.tr(.Devchat_You) if e.from_me else engine.tr(.Devchat_Developers)
		when_ := time.unix(e.time / 1000, 0)
		hh, mm, _ := time.clock_from_time(when_)
		head := fmt.tprintf("%s  %02d:%02d", who, hh, mm)
		if e.from_me &&
		   e.refused !=
			   "" {head = fmt.tprintf("%s  (%s)", head, e.refused)} else if e.from_me && !e.sent {
			head = fmt.tprintf("%s  · %s", head, engine.tr(.Devchat_Not_Sent))
		}
		body := e.text
		if e.link != "" {body = strings.concatenate({body, "\n", e.link}, context.temp_allocator)}
		wrapped := make([dynamic]string, context.temp_allocator)
		paragraphs := body
		for paragraph in strings.split_lines_iterator(&paragraphs) {
			append(&wrapped, ..ui.wrap_words(ctx, paragraph, size, width))
		}
		y -= f32(len(wrapped) + 1) * line_h + t.spacing
		ui.label(
			ctx,
			head,
			{area.x + t.padding, y, width, line_h},
			.Left,
			t.text if !e.from_me else t.text_muted,
		)
		for line, k in wrapped {
			ui.label(
				ctx,
				line,
				{area.x + t.padding, y + f32(k + 1) * line_h, width, line_h},
				.Left,
				t.text,
			)
		}
	}
}

// devchat_notice: a reply came while the chat was closed: a toast (never in
// the way of play), once per reply, naming the key that opens the chat.
devchat_notice :: proc(app: ^engine.App) {
	if !app.devchat.running {return}
	replies := collector.chat_replies(&app.devchat.chat)
	if engine.overlay_is_open(&app.overlays, .Devchat) {
		app.devchat_seen = replies
		return
	}
	if replies <= app.devchat_seen {return}
	app.devchat_seen = replies
	engine.toast(app, .Devchat_Notice, engine.action_label(app, .Dev_Chat))
}
