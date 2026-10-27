package client

import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../common/game"
import "ui"

// Chat: `t` opens it, `/` opens it with a command started; Enter says the
// line (or runs the command on the server), Escape closes it. The lines
// (what players say, and the server's notices) show over the game for a
// while, then fade; open, the chat shows them all (the wheel scrolls).

CHAT_KEEP :: 100 // lines kept
CHAT_SHOW_SECONDS :: 10 // over the game, then fading over a second
CHAT_LINES_SHOWN :: 10 // over the game, at most
CHAT_WIDTH :: 640

Chat_Entry :: struct {
	id:   u32, // the server's (0: a notice)
	text: string, // formatted (heap)
	at:   time.Tick,
}

// chat_add keeps a line (the oldest goes past CHAT_KEEP).
chat_add :: proc(s: ^Session, id: u32, text: string) {
	if len(s.chat) == CHAT_KEEP {
		delete(s.chat[0].text)
		ordered_remove(&s.chat, 0)
	}
	append(&s.chat, Chat_Entry{id, strings.clone(text), time.tick_now()})
}

// chat_delete: a moderator took line id back.
chat_delete :: proc(s: ^Session, id: u32) {
	for e, i in s.chat {
		if e.id == id {
			delete(e.text)
			ordered_remove(&s.chat, i)
			return
		}
	}
}

// chat_open opens the chat with text started.
chat_open :: proc(app: ^App, text: string) {
	overlay_open(&app.overlays, .Chat)
	clear(&app.chat.text)
	append(&app.chat.text, text)
	app.ui.edit = {} // the cursor to the end when it takes the focus
	app.chat_scroll = 0
}

chat_close :: proc(app: ^App) {
	if line_search_cancel(&app.chat) {return}
	overlay_close(&app.overlays, .Chat)
	clear(&app.chat.text)
}

// chat_keys: the chat key, or the command key (the chat starting with /),
// over the game opens the chat (the key types nothing into it).
chat_keys :: proc(app: ^App, input: ^ui.Input) {
	s := app.session
	if s == nil || s.state != .Playing || !game_controls(app) {return}
	slash := action_pressed(&app.actions, .Command)
	if action_pressed(&app.actions, .Chat) || slash {
		chat_open(app, "/" if slash else "")
		input.text = nil
	}
}

// chat_send: the line said, or (starting with /) run on the server.
@(private = "file")
chat_send :: proc(app: ^App, line: string) {
	s := app.session
	text := strings.trim_space(line)
	if text == "" || s == nil || s.state != .Playing {return}
	if strings.has_prefix(text, "/") {
		if len(text) > 1 {send_message(s, game.Command{text[1:]})}
		return
	}
	// At most what a message holds (whole letters).
	cut := min(len(text), game.MAX_CHAT_TEXT)
	for cut < len(text) && cut > 0 && !utf8.rune_start(text[cut]) {cut -= 1}
	send_message(s, game.Chat{text[:cut]})
}

// chat_ui: the open chat (an overlay): the line, and every line kept above.
chat_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil {return}
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Popup)
	defer ui.end_layer(ctx, prev)
	area := ui.rect_shrink(ctx.screen, t.padding)
	input_rect := ui.cut_bottom(&area, t.row_height)
	input_rect.w = min(input_rect.w, CHAT_WIDTH)
	ui.cut_bottom(&area, t.spacing)
	hint: ui.Rect
	if app.chat.searching {hint = ui.cut_bottom(&area, t.row_height)}
	r := line_edit(
		app,
		ctx,
		&app.chat,
		"chat input",
		input_rect,
		hint,
		"say something (/ for a command)",
		top,
		chat_candidates,
	)
	if len(r.choices) > 0 {
		notice(s, strings.join(r.choices, "   ", context.temp_allocator))
	}
	if r.submitted {
		chat_send(app, r.line)
		overlay_close(&app.overlays, .Chat)
		return
	}
	if ui.rect_contains(area, ctx.input.mouse) {app.chat_scroll += ctx.input.wheel.y * 3}
	chat_lines(app, ctx, area, true)
}

// chat_feed: the newest lines over the game, fading.
chat_feed :: proc(app: ^App, ctx: ^ui.Context) {
	if overlay_is_open(&app.overlays, .Chat) {return}
	t := &ctx.theme
	area := ui.rect_shrink(ctx.screen, t.padding)
	ui.cut_bottom(&area, 2 * t.row_height + 24) // above the hotbar
	chat_lines(app, ctx, area, false)
}

// chat_lines draws the kept lines up from the bottom of area, wrapped:
// all of them (open), or the newest few still shown.
@(private = "file")
chat_lines :: proc(app: ^App, ctx: ^ui.Context, area: ui.Rect, open: bool) {
	s := app.session
	t := &ctx.theme
	size := t.font_size * app.settings.chat_text_size
	line_h := size * 1.35
	width := min(area.w, CHAT_WIDTH)
	ascent, descent := ui.font_line_metrics(ctx, size)
	ui.push_clip_rect(ctx, area)
	defer ui.pop_clip_rect(ctx)
	if open {app.chat_scroll = clamp(app.chat_scroll, 0, f32(max(len(s.chat) - 1, 0)))}
	y := area.y + area.h
	shown := 0
	newest := len(s.chat) - 1 - (int(app.chat_scroll) if open else 0)
	for i := newest; i >= 0 && y > area.y; i -= 1 {
		e := s.chat[i]
		alpha: f32 = 1
		if !open {
			age := f32(time.duration_seconds(time.tick_since(e.at)))
			if shown == CHAT_LINES_SHOWN || age > CHAT_SHOW_SECONDS + 1 {break}
			alpha = clamp(CHAT_SHOW_SECONDS + 1 - age, 0, 1)
		}
		shown += 1
		wrapped := wrap_formatted(ctx, e.text, size, width - 2 * t.padding)
		block := f32(len(wrapped)) * line_h
		y -= block
		ui.fill_rect(ctx, {area.x, y, width, block}, {0, 0, 0, u8(140 * alpha)})
		for line, k in wrapped {
			baseline := y + f32(k) * line_h + (line_h - (ascent - descent)) / 2 + ascent
			color := t.text
			color.a = u8(255 * alpha)
			draw_formatted(ctx, {area.x + t.padding, baseline}, line, size, color)
		}
	}
}

// chat_candidates: Tab in the chat: a command's name after /, else the
// names of the players here.
@(private = "file")
chat_candidates :: proc(app: ^App, before: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	s := app.session
	if s == nil {return nil}
	line := string(app.chat.text[:])
	if len(before) == 0 && strings.has_prefix(line, "/") {
		for c in s.commands {append(&names, strings.concatenate({"/", c}, context.temp_allocator))}
		return names[:]
	}
	append(&names, s.config.name)
	for _, o in s.others {append(&names, o.name)}
	return names[:]
}
