package client

import "core:fmt"
import "core:slice"
import "core:strings"

import "ui"

// The player list: while the key is held,
// the connected players' names and pings. An overlay that takes no input.
// A ping is known for ourselves on a server we joined (the link's round
// trip); alone in our own world, and for the others, it reads "-".

Player_Row :: struct {
	name:     string,
	ping:     string, // as shown
	kills:    string,
	deaths:   string,
	kills_n:  u32, // (the sort's)
	deaths_n: u32,
}

// player_rows: who is here with their kills and deaths, the most kills
// first, then the fewest deaths, then by name.
player_rows :: proc(s: ^Session) -> []Player_Row {
	rows := make([dynamic]Player_Row, context.temp_allocator)
	me := s.config.name if s.config.name != "" else "You"
	ping := tr(.Player_List_No_Ping)
	if s.remote {ping = tr(.Player_List_Ping, int(s.net.rtt_ms))}
	append(&rows, player_row(me, ping, s.tally.kills, s.tally.deaths))
	for _, o in s.others {
		append(&rows, player_row(o.name, tr(.Player_List_No_Ping), o.kills, o.deaths))
	}
	slice.sort_by(rows[:], proc(a, b: Player_Row) -> bool {
		if a.kills_n != b.kills_n {return a.kills_n > b.kills_n}
		if a.deaths_n != b.deaths_n {return a.deaths_n < b.deaths_n}
		return strings.compare(a.name, b.name) < 0
	})
	return rows[:]
}

@(private = "file")
player_row :: proc(name, ping: string, kills, deaths: u32) -> Player_Row {
	return {name, ping, fmt.tprint(kills), fmt.tprint(deaths), kills, deaths}
}

COLUMN_WIDTH :: 70

player_list_draw :: proc(app: ^App, ctx: ^ui.Context) {
	if !action_down(&app.actions, .Player_List) || app.overlays.count != 0 {return}
	t := &ctx.theme
	rows := player_rows(app.session)
	height := f32(len(rows) + 1) * t.row_height + 2 * t.padding
	box := ui.rect_center(ctx.screen, 460, height)
	box.y = 40
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, t.padding)
	columns :: proc(line: ui.Rect) -> (kills, deaths, ping: ui.Rect) {
		l := line
		ping = ui.cut_right(&l, COLUMN_WIDTH)
		deaths = ui.cut_right(&l, COLUMN_WIDTH)
		kills = ui.cut_right(&l, COLUMN_WIDTH)
		return
	}
	head := ui.cut_top(&inner, t.row_height)
	head_kills, head_deaths, _ := columns(head)
	ui.label(ctx, tr(.Players_Player), head, .Left, t.text_muted)
	ui.label(ctx, tr(.Players_Kills), head_kills, .Right, t.text_muted)
	ui.label(ctx, tr(.Players_Deaths), head_deaths, .Right, t.text_muted)
	for row in rows {
		line := ui.cut_top(&inner, t.row_height)
		kills, deaths, ping := columns(line)
		ui.label(ctx, row.name, line, .Left)
		ui.label(ctx, row.kills, kills, .Right)
		ui.label(ctx, row.deaths, deaths, .Right)
		ui.label(ctx, row.ping, ping, .Right, t.text_muted)
	}
}
