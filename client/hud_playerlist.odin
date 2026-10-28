package client

import "core:slice"
import "core:strings"

import "ui"

// The player list (design.md, *Hotkeys and input*): while the key is held,
// the connected players' names and pings. An overlay that takes no input.
// A ping is known for ourselves on a server we joined (the link's round
// trip); alone in our own world, and for the others, it reads "-".

Player_Row :: struct {
	name: string,
	ping: string, // as shown
}

// player_rows: who is here, ourselves first, the others by name.
player_rows :: proc(s: ^Session) -> []Player_Row {
	rows := make([dynamic]Player_Row, context.temp_allocator)
	me := s.config.name if s.config.name != "" else "You"
	ping := tr(.Player_List_No_Ping)
	if s.remote {ping = tr(.Player_List_Ping, int(s.net.rtt_ms))}
	append(&rows, Player_Row{me, ping})
	others := make([dynamic]string, context.temp_allocator)
	for _, o in s.others {append(&others, o.name)}
	slice.sort_by(others[:], proc(a, b: string) -> bool {return strings.compare(a, b) < 0})
	for name in others {append(&rows, Player_Row{name, tr(.Player_List_No_Ping)})}
	return rows[:]
}

player_list_draw :: proc(app: ^App, ctx: ^ui.Context) {
	if !action_down(&app.actions, .Player_List) || app.overlays.count != 0 {return}
	t := &ctx.theme
	rows := player_rows(app.session)
	height := f32(len(rows)) * t.row_height + 2 * t.padding
	box := ui.rect_center(ctx.screen, 360, height)
	box.y = 40
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, t.padding)
	for row in rows {
		line := ui.cut_top(&inner, t.row_height)
		ui.label(ctx, row.name, line, .Left)
		ui.label(ctx, row.ping, line, .Right, t.text_muted)
	}
}
