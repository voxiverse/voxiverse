package sandbox_client

import "core:fmt"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "games:sandbox"

// A conversation with one of the camps' people, as the server last put it (sandbox.Talk;
// the server is the authority, this only shows and asks). Its screen is the game's, in the
// panels' style: a name plate (the person's name, what it does and its camp), the line it
// says (from the dialogue in the session's registry, the same the server reads, with
// `{name}` and `{camp}` filled in) and the replies the player is offered there, one button
// each, numbered: a click, the number's key, or the arrows and Enter answer (a sandbox.Say).
// Leave, or Escape, leaves. The engine scales the screen down to fit a small window.

TALK_WIDTH :: 640
TALK_TITLE :: 40 // the name plate's height
TALK_BELOW :: 96 // how far over the bottom of the screen the panel stands (the hotbar's room)

// Talk_Screen: the conversation as last put (person 0: none).
Talk_Screen :: struct {
	person:   u32,
	name:     [sandbox.MAX_PERSON_NAME]u8,
	name_len: int,
	camp:     [sandbox.MAX_CAMP_NAME]u8,
	camp_len: int,
	dialogue: int,
	node:     int,
	offered:  game.Reply_Set,
}

// talk_received: a conversation put: shown (its screen opened when it begins), or gone (its
// screen closed, unless another of the game's screens took its place).
talk_received :: proc(s: ^engine.Session, v: ^sandbox.Talk) {
	t := &view(s).talk
	began := t.person == 0 && v.person != 0
	t^ = {
		person   = v.person,
		dialogue = int(v.dialogue),
		node     = int(v.node),
		offered  = v.offered,
	}
	t.name_len = copy(t.name[:], v.name)
	t.camp_len = copy(t.camp[:], v.camp)
	if began || (v.person != 0 && !engine.game_screen_shown(s)) {
		view(s).screen = .Talk
		engine.game_screen_open(s)
	} else if v.person == 0 && view(s).screen == .Talk {
		engine.game_screen_close(s)
	}
}

// talk_hud: a conversation whose screen the player closed (Escape) is left.
talk_hud :: proc(s: ^engine.Session) {
	t := &view(s).talk
	if t.person == 0 || (engine.game_screen_shown(s) && view(s).screen == .Talk) {return}
	talk_say(s, sandbox.TALK_LEAVE)
	t.person = 0
}

// talk_say: the reply of index i asked for (TALK_LEAVE: leave).
talk_say :: proc(s: ^engine.Session, i: u8) {
	say := sandbox.Say{i}
	engine.game_request(s, &say)
}

// talk_line: a line with the person's name and camp put in.
talk_line :: proc(t: ^Talk_Screen, line: string) -> string {
	a, _ := strings.replace_all(
		line,
		"{name}",
		string(t.name[:t.name_len]),
		context.temp_allocator,
	)
	b, _ := strings.replace_all(a, "{camp}", string(t.camp[:t.camp_len]), context.temp_allocator)
	return b
}

// talk_screen: the game's screen while it talks (engine.Game.screen).
talk_screen :: proc(s: ^engine.Session, ctx: ^ui.Context, top: bool) {
	t := &view(s).talk
	reg := s.reg
	if t.person == 0 || t.dialogue >= len(reg.dialogues) {return}
	dlg := &reg.dialogues[t.dialogue]
	if t.node >= len(dlg.nodes) {return}
	node := &dlg.nodes[t.node]
	th := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	text := th.font_size * 1.1
	lines := ui.wrap_words(ctx, talk_line(t, node.line), text, TALK_WIDTH - 4 * th.padding)
	shown := card(t.offered)
	line_height := text * 1.4
	height :=
		4 * th.padding +
		TALK_TITLE +
		f32(len(lines)) * line_height +
		th.spacing +
		f32(shown) * (th.row_height + th.spacing / 2) +
		th.spacing +
		th.row_height
	// Low on the screen, so the one who speaks stands over it.
	h := min(height, ctx.screen.h)
	box := ui.Rect {
		ctx.screen.x + (ctx.screen.w - TALK_WIDTH) / 2,
		ctx.screen.y + max(ctx.screen.h - h - TALK_BELOW, 0),
		TALK_WIDTH,
		h,
	}
	ui.panel(ctx, box)
	area := ui.rect_shrink(box, 2 * th.padding)
	name := sandbox.tr(
		.Talk_Title,
		string(t.name[:t.name_len]),
		dlg.title,
		string(t.camp[:t.camp_len]),
	)
	ui.draw_text(ctx, ui.cut_top(&area, TALK_TITLE), name, th.font_size * 1.4, th.text, .Center)
	for l in lines {ui.draw_text(ctx, ui.cut_top(&area, line_height), l, text, th.text)}
	ui.cut_top(&area, th.spacing)

	// The replies offered, numbered; a number typed answers too.
	typed := -1
	if top {
		for r in ctx.input.text {if r >= '1' && r <= '4' {typed = int(r - '1')}}
	}
	k := 0
	for &r, i in node.replies {
		if i not_in t.offered {continue}
		row := ui.cut_top(&area, th.row_height)
		ui.cut_top(&area, th.spacing / 2)
		if k == 0 {ui.default_focus(ctx)}
		ui.push_id_int(ctx, i)
		clicked := ui.button(ctx, fmt.tprintf("%d.  %s", k + 1, r.text), row)
		ui.pop_id(ctx)
		if clicked || typed == k {talk_say(s, u8(i))}
		k += 1
	}
	bottom := ui.cut_bottom(&area, th.row_height)
	leave := ui.cut_right(&bottom, 160)
	ui.label(ctx, sandbox.tr(.Talk_Hint, "Esc"), bottom, .Left, th.text_muted)
	if ui.button(ctx, sandbox.tr(.Talk_Leave), leave) {
		talk_say(s, sandbox.TALK_LEAVE)
		t.person = 0
		engine.game_screen_close(s)
	}
}

// card: how many replies a set holds.
@(private = "file")
card :: proc(set: game.Reply_Set) -> int {
	n := 0
	for i in 0 ..< game.MAX_REPLIES {if i in set {n += 1}}
	return n
}
